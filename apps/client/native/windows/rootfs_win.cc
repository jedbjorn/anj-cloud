// Windows handle-relative filesystem boundary (spec #32 W2): anj_rootfs.dll,
// the Windows implementation of the anj_* C ABI that native/posix/rootfs.cc
// implements on Linux. No credentials or networking.
//
// * Descriptors are small positive integers from a handle table, never
//   HANDLEs. Numbers are never reused, so a stale or unknown number fails
//   with EBADF and never reaches another handle.
// * Every path beneath a root is opened one component at a time with
//   NtCreateFile relative to the parent handle and FILE_OPEN_REPARSE_POINT.
//   A component that is a reparse point (symlink, junction, mount point,
//   cloud placeholder) is refused (ELOOP); one whose name on disk differs from
//   the requested name (a case alias such as a.txt for A.txt, or an 8.3 alias
//   such as REPORT~1.DOC) is refused as absent (ENOENT). `..`, `.`, `\`, `:`
//   (streams), wildcard and control characters, trailing dots and spaces and
//   reserved device names are refused lexically (EINVAL) before any open.
// * Renames, links and deletes go through open handles: FileRenameInformation
//   and FileLinkInformation with ReplaceIfExists = FALSE (an occupied
//   destination, compared case-insensitively by NTFS, is EEXIST) and POSIX
//   delete dispositions. Durability is NtFlushBuffersFile on the file and the
//   directory; a directory flush NTFS refuses is recorded (see dir_flush).
// * Errors are reported as the Linux errno numbers the shared engine already
//   interprets (spec #32 S2.1), never as MSVC errno values.
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
// ReadDirectoryChangesExW and FILE_NOTIFY_EXTENDED_INFORMATION: Windows 10
// 1709 (RS3) headers. The supported systems are Windows 10 22H2 and 11.
#if !defined(_WIN32_WINNT) && !defined(NTDDI_VERSION)
#define _WIN32_WINNT 0x0A00
#define NTDDI_VERSION 0x0A000004
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <winternl.h>
#include <aclapi.h>
#include <sddl.h>

#include "watch_translate.h"

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#define ANJ_API extern "C" __declspec(dllexport)

#ifndef PROTECTED_DACL_SECURITY_INFORMATION
#define PROTECTED_DACL_SECURITY_INFORMATION 0x80000000L
#endif
#ifndef UNPROTECTED_DACL_SECURITY_INFORMATION
#define UNPROTECTED_DACL_SECURITY_INFORMATION 0x20000000L
#endif

namespace {

// Linux errno numbers (asm-generic/errno-base.h, errno.h). MSVC's <errno.h>
// differs for several of them, so these are spelled out.
namespace lx {
constexpr int PERM = 1, NOENT = 2, IO = 5, BADF = 9, AGAIN = 11, NOMEM = 12,
              ACCES = 13, BUSY = 16, EXIST = 17, XDEV = 18, NOTDIR = 20,
              ISDIR = 21, INVAL = 22, MFILE = 24, NOSPC = 28, MLINK = 31,
              NAMETOOLONG = 36, NOTEMPTY = 39, LOOP = 40, NOTSUP = 95,
              NOBUFS = 105, NOTCONN = 107, STALE = 116;
}

thread_local int error_number = 0;

// ---- ntdll ----------------------------------------------------------------

constexpr ULONG kFileOpen = 1, kFileCreate = 2;
constexpr ULONG kDirectoryFile = 0x1, kSynchronousIo = 0x20,
                kNonDirectoryFile = 0x40, kOpenReparsePoint = 0x200000;
constexpr ULONG kShareAll = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
constexpr ACCESS_MASK kWalkAccess = FILE_READ_ATTRIBUTES;

// FILE_INFORMATION_CLASS / FS_INFORMATION_CLASS values used here.
constexpr ULONG kFileDirectoryInformation = 1, kFileBasicInformation = 4,
                kFileStandardInformation = 5, kFileRenameInformation = 10,
                kFileLinkInformation = 11, kFileAttributeTagInformation = 35,
                kFileNormalizedNameInformation = 48, kFileIdInformation = 59,
                kFileDispositionInformationEx = 64;
constexpr ULONG kFsDeviceInformation = 4, kFsAttributeInformation = 5;

constexpr LONG kStatusNoMoreFiles = static_cast<LONG>(0x80000006);
constexpr LONG kStatusBufferOverflow = static_cast<LONG>(0x80000005);

struct BasicInfo {
  LARGE_INTEGER creation, access, write, change;
  ULONG attributes;
};
struct StandardInfo {
  LARGE_INTEGER allocation, end;
  ULONG links;
  BOOLEAN delete_pending, directory;
};
struct TagInfo { ULONG attributes; ULONG tag; };
struct IdInfo { ULONGLONG volume; unsigned char id[16]; };
struct DispositionEx { ULONG flags; };
constexpr ULONG kDispositionDelete = 0x1, kDispositionPosix = 0x2,
                kDispositionIgnoreReadOnly = 0x10;
// FILE_RENAME_INFORMATION and FILE_LINK_INFORMATION share this layout.
struct LinkRename {
  BOOLEAN replace;
  HANDLE root;
  ULONG length;
  WCHAR name[1];
};
struct DirectoryInfo {
  ULONG next;
  ULONG index;
  LARGE_INTEGER creation, access, write, change, end, allocation;
  ULONG attributes;
  ULONG length;
  WCHAR name[1];
};
struct NameInfo { ULONG length; WCHAR name[1]; };
struct FsAttribute {
  ULONG attributes;
  LONG max_component;
  ULONG length;
  WCHAR name[1];
};
struct FsDevice { ULONG type; ULONG characteristics; };
constexpr ULONG kDeviceDisk = 7, kRemovableMedia = 0x1, kRemoteDevice = 0x10;

using NtCreateFileFn = LONG(NTAPI*)(PHANDLE, ACCESS_MASK, POBJECT_ATTRIBUTES,
    PIO_STATUS_BLOCK, PLARGE_INTEGER, ULONG, ULONG, ULONG, ULONG, PVOID, ULONG);
using NtInfoFn = LONG(NTAPI*)(HANDLE, PIO_STATUS_BLOCK, PVOID, ULONG, ULONG);
using NtFlushFn = LONG(NTAPI*)(HANDLE, PIO_STATUS_BLOCK);
using NtDirectoryFn = LONG(NTAPI*)(HANDLE, HANDLE, PVOID, PVOID,
    PIO_STATUS_BLOCK, PVOID, ULONG, ULONG, BOOLEAN, PUNICODE_STRING, BOOLEAN);

struct Nt {
  NtCreateFileFn create = nullptr;
  NtInfoFn query = nullptr, set = nullptr, volume = nullptr;
  NtFlushFn flush = nullptr;
  NtDirectoryFn directory = nullptr;
  bool ok = false;
};
const Nt& nt() {
  static const Nt loaded = [] {
    Nt n;
    HMODULE m = GetModuleHandleW(L"ntdll.dll");
    if (!m) return n;
    n.create = reinterpret_cast<NtCreateFileFn>(GetProcAddress(m, "NtCreateFile"));
    n.query = reinterpret_cast<NtInfoFn>(GetProcAddress(m, "NtQueryInformationFile"));
    n.set = reinterpret_cast<NtInfoFn>(GetProcAddress(m, "NtSetInformationFile"));
    n.volume = reinterpret_cast<NtInfoFn>(GetProcAddress(m, "NtQueryVolumeInformationFile"));
    n.flush = reinterpret_cast<NtFlushFn>(GetProcAddress(m, "NtFlushBuffersFile"));
    n.directory = reinterpret_cast<NtDirectoryFn>(GetProcAddress(m, "NtQueryDirectoryFile"));
    n.ok = n.create && n.query && n.set && n.volume && n.flush && n.directory;
    return n;
  }();
  return loaded;
}

int from_status(LONG status) {
  switch (static_cast<ULONG>(status)) {
    case 0xC0000034: case 0xC000003A: case 0xC000000F: case 0xC0000056:
    case 0xC0000123: return lx::NOENT;    // name/path not found, delete pending
    case 0xC0000035: return lx::EXIST;    // OBJECT_NAME_COLLISION
    case 0xC0000043: return lx::BUSY;     // SHARING_VIOLATION
    case 0xC0000121: return lx::BUSY;     // CANNOT_DELETE (mapped, read-only)
    case 0xC0000022: return lx::ACCES;    // ACCESS_DENIED
    case 0xC0000103: return lx::NOTDIR;   // NOT_A_DIRECTORY
    case 0xC00000BA: return lx::ISDIR;    // FILE_IS_A_DIRECTORY
    case 0xC0000101: return lx::NOTEMPTY; // DIRECTORY_NOT_EMPTY
    case 0xC00000D4: return lx::XDEV;     // NOT_SAME_DEVICE
    case 0xC000007F: return lx::NOSPC;    // DISK_FULL
    case 0xC00000BB: case 0xC0000010: return lx::NOTSUP;
    case 0xC0000033: case 0xC0000039: case 0xC000003B: case 0xC000000D:
      return lx::INVAL;
    case 0xC0000106: return lx::NAMETOOLONG;
    case 0x8000002D: case 0xC000050B: case 0xC0000279: return lx::LOOP;
    case 0xC0000054: case 0xC0000055: return lx::AGAIN; // lock conflict
    case 0xC000009A: return lx::NOMEM;
    case 0xC0000008: return lx::BADF;
    case 0xC0000265: return lx::MLINK;
    default: return lx::IO;
  }
}
int from_win32(DWORD error) {
  switch (error) {
    case ERROR_FILE_NOT_FOUND: case ERROR_PATH_NOT_FOUND: return lx::NOENT;
    case ERROR_ACCESS_DENIED: return lx::ACCES;
    case ERROR_SHARING_VIOLATION: return lx::BUSY;
    case ERROR_LOCK_VIOLATION: return lx::AGAIN;
    case ERROR_ALREADY_EXISTS: case ERROR_FILE_EXISTS: return lx::EXIST;
    case ERROR_DIR_NOT_EMPTY: return lx::NOTEMPTY;
    case ERROR_NOT_SAME_DEVICE: return lx::XDEV;
    case ERROR_DISK_FULL: case ERROR_HANDLE_DISK_FULL: return lx::NOSPC;
    case ERROR_NOT_SUPPORTED: case ERROR_INVALID_FUNCTION: return lx::NOTSUP;
    case ERROR_INVALID_PARAMETER: case ERROR_INVALID_NAME: return lx::INVAL;
    case ERROR_FILENAME_EXCED_RANGE: return lx::NAMETOOLONG;
    case ERROR_INVALID_HANDLE: return lx::BADF;
    case ERROR_NOT_ENOUGH_MEMORY: case ERROR_OUTOFMEMORY: return lx::NOMEM;
    default: return lx::IO;
  }
}

// RAII for a HANDLE this code owns.
struct Owned {
  HANDLE h = nullptr;
  Owned() = default;
  explicit Owned(HANDLE value) : h(value) {}
  Owned(const Owned&) = delete;
  Owned& operator=(const Owned&) = delete;
  Owned(Owned&& o) noexcept : h(o.h) { o.h = nullptr; }
  Owned& operator=(Owned&& o) noexcept {
    if (this != &o) { reset(); h = o.h; o.h = nullptr; }
    return *this;
  }
  ~Owned() { reset(); }
  void reset() { if (h) CloseHandle(h); h = nullptr; }
  HANDLE release() { HANDLE v = h; h = nullptr; return v; }
};

// Opens [name] relative to [dir] (an absolute NT path when dir is null),
// never following a reparse point. Returns an errno.
int nt_open(HANDLE dir, const std::wstring& name, ACCESS_MASK access,
    ULONG share, ULONG disposition, ULONG options, Owned& out) {
  const Nt& n = nt();
  if (!n.ok) return lx::NOTSUP;
  if (name.size() * sizeof(WCHAR) > 0xFFF0) return lx::NAMETOOLONG;
  UNICODE_STRING us;
  us.Buffer = const_cast<PWSTR>(name.c_str());
  us.Length = static_cast<USHORT>(name.size() * sizeof(WCHAR));
  us.MaximumLength = us.Length;
  OBJECT_ATTRIBUTES oa;
  // The object manager compares names case-insensitively on NTFS whatever is
  // asked; exactness is enforced afterwards by check_name.
  InitializeObjectAttributes(&oa, &us, OBJ_CASE_INSENSITIVE, dir, nullptr);
  IO_STATUS_BLOCK io = {};
  HANDLE h = nullptr;
  LONG status = n.create(&h, access | SYNCHRONIZE, &oa, &io, nullptr,
      FILE_ATTRIBUTE_NORMAL, share, disposition,
      options | kOpenReparsePoint | kSynchronousIo, nullptr, 0);
  if (status < 0) return from_status(status);
  out = Owned(h);
  return 0;
}

template <typename T>
int query(HANDLE h, ULONG cls, T& out) {
  IO_STATUS_BLOCK io = {};
  LONG status = nt().query(h, &io, &out, sizeof(T), cls);
  return status < 0 ? from_status(status) : 0;
}
int set_info(HANDLE h, ULONG cls, void* data, ULONG length) {
  IO_STATUS_BLOCK io = {};
  LONG status = nt().set(h, &io, data, length, cls);
  return status < 0 ? from_status(status) : 0;
}

// ---- names ----------------------------------------------------------------

bool to_wide(const char* text, size_t length, std::wstring& out) {
  out.clear();
  if (length == 0) return true;
  int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text,
      static_cast<int>(length), nullptr, 0);
  if (n <= 0) return false;
  out.resize(static_cast<size_t>(n));
  return MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text,
      static_cast<int>(length), &out[0], n) == n;
}
bool to_utf8(const WCHAR* text, size_t length, std::string& out) {
  out.clear();
  if (length == 0) return true;
  int n = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text,
      static_cast<int>(length), nullptr, 0, nullptr, nullptr);
  if (n <= 0) return false;
  out.resize(static_cast<size_t>(n));
  return WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text,
      static_cast<int>(length), &out[0], n, nullptr, nullptr) == n;
}

// CON, PRN, AUX, NUL, COM0-9, LPT0-9 (and superscript 1-3), CONIN$, CONOUT$,
// in any case, alone or with any extension.
bool reserved(const std::wstring& component) {
  std::wstring base = component.substr(0, component.find(L'.'));
  while (!base.empty() && base.back() == L' ') base.pop_back();
  for (auto& c : base) if (c >= L'a' && c <= L'z') c = static_cast<WCHAR>(c - 32);
  if (base == L"CON" || base == L"PRN" || base == L"AUX" || base == L"NUL" ||
      base == L"CONIN$" || base == L"CONOUT$") return true;
  if (base.size() == 4 && (base.compare(0, 3, L"COM") == 0 || base.compare(0, 3, L"LPT") == 0)) {
    WCHAR d = base[3];
    return (d >= L'0' && d <= L'9') || d == 0x00B9 || d == 0x00B2 || d == 0x00B3;
  }
  return false;
}
// Why [c] cannot be a root-relative component, or 0. EINVAL: path syntax
// (empty, ., .., separators, ':' streams, NUL). ENAMETOOLONG: over 255 UTF-16
// units, as Linux. kNonPortable: a name NTFS can hold (WSL, \\?\ tools) but
// the Win32 namespace cannot (reserved device names, trailing dot or space,
// < > " | ? * and control characters); every operation refuses it with
// EINVAL, and scans list it as unsupported (PR #55 review F3).
constexpr int kNonPortable = -1;
int component_error(const std::wstring& c) {
  if (c.empty() || c == L"." || c == L"..") return lx::INVAL;
  for (WCHAR ch : c) if (ch == 0 || ch == L'/' || ch == L'\\' || ch == L':') return lx::INVAL;
  if (c.size() > 255) return lx::NAMETOOLONG;
  for (WCHAR ch : c) {
    if (ch < 0x20 || ch == L'<' || ch == L'>' || ch == L'"' || ch == L'|' || ch == L'?' ||
        ch == L'*')
      return kNonPortable;
  }
  if (c.back() == L'.' || c.back() == L' ') return kNonPortable;
  return reserved(c) ? kNonPortable : 0;
}
bool valid_component(const std::wstring& c) { return component_error(c) == 0; }
// A root-relative path: components separated by '/', each valid. With
// [loose], non-portable components are accepted and [non_portable] counts
// them (stat-only listing of names already on disk).
int split(const char* path, std::vector<std::wstring>& parts, bool loose = false,
    size_t* non_portable = nullptr) {
  parts.clear();
  if (non_portable) *non_portable = 0;
  if (!path || !*path) return lx::INVAL;
  std::wstring wide;
  if (!to_wide(path, strlen(path), wide)) return lx::INVAL;
  size_t start = 0;
  while (true) {
    size_t end = wide.find(L'/', start);
    std::wstring part = wide.substr(start, end == std::wstring::npos ? end : end - start);
    int e = component_error(part);
    if (e == kNonPortable && loose) {
      if (non_portable) ++*non_portable;
    } else if (e) {
      return e == kNonPortable ? lx::INVAL : e;
    }
    parts.push_back(part);
    if (end == std::wstring::npos) return 0;
    start = end + 1;
  }
}
int single(const char* name, std::wstring& out) {
  std::vector<std::wstring> parts;
  int e = split(name, parts);
  if (e) return e;
  if (parts.size() != 1) return lx::INVAL;
  out = parts[0];
  return 0;
}

// The full normalized name of an open file (from the volume root): the long
// name, in its stored case, of the link it was opened through.
int normalized_name(HANDLE h, std::wstring& out) {
  std::vector<unsigned char> buffer(sizeof(ULONG) + 65536);
  IO_STATUS_BLOCK io = {};
  LONG status = nt().query(h, &io, buffer.data(), static_cast<ULONG>(buffer.size()),
      kFileNormalizedNameInformation);
  if (status < 0) return from_status(status);
  auto* info = reinterpret_cast<NameInfo*>(buffer.data());
  out.assign(info->name, info->length / sizeof(WCHAR));
  return 0;
}
// The opened component's name as stored on disk must be exactly [expected]:
// NTFS resolves a.txt to A.txt and REPORT~1.DOC to its long name, and either
// would let one name reach another file.
int check_name(HANDLE h, const std::wstring& expected) {
  std::wstring full;
  int e = normalized_name(h, full);
  if (e) return e;
  size_t slash = full.rfind(L'\\');
  std::wstring last = slash == std::wstring::npos ? full : full.substr(slash + 1);
  return last == expected ? 0 : lx::NOENT;
}

// ---- stat -----------------------------------------------------------------

constexpr long long kUnixEpoch100ns = 116444736000000000LL;
struct Stat {
  ULONG attributes = 0;
  long long size = 0, allocated = 0;
  ULONG links = 0;
  long long write = 0, change = 0;  // 100 ns ticks since 1601
  ULONGLONG volume = 0;
  long long id = 0;
  bool directory() const { return (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0; }
  bool reparse() const { return (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0; }
  bool regular() const { return !directory() && !reparse(); }
};
int stat_of(HANDLE h, Stat& s) {
  TagInfo tag = {};
  BasicInfo basic = {};
  StandardInfo standard = {};
  IdInfo id = {};
  int e = query(h, kFileAttributeTagInformation, tag);
  if (!e) e = query(h, kFileBasicInformation, basic);
  if (!e) e = query(h, kFileStandardInformation, standard);
  if (!e) e = query(h, kFileIdInformation, id);
  if (e) return e;
  s.attributes = tag.attributes;
  s.size = standard.end.QuadPart;
  s.allocated = standard.allocation.QuadPart;
  s.links = standard.links;
  s.write = basic.write.QuadPart;
  s.change = basic.change.QuadPart;
  s.volume = id.volume;
  // NTFS file reference: 48-bit MFT index and 16-bit sequence number in the
  // low 8 bytes (the high 8 are zero). The sequence number changes when an
  // MFT record is reused, so a recreated directory never repeats an id.
  // Printed signed: the engine parses inode and stamp fields as Dart int
  // (signed 64-bit; jsonDecode turns a larger number into a double), so a
  // sequence number of 0x8000 or more must not exceed 2^63 - 1 (review F9:
  // unsigned printing would break that parse; identities stay unique).
  long long low = 0;
  memcpy(&low, id.id, sizeof(low));
  s.id = low;
  return 0;
}
long long unix_ns(long long ticks) { return (ticks - kUnixEpoch100ns) * 100; }
std::string volume_key(const Stat& s) {
  char buf[24];
  snprintf(buf, sizeof(buf), "w%016llx", static_cast<unsigned long long>(s.volume));
  return buf;
}
std::string identity_of(const Stat& s) { return volume_key(s) + ":" + std::to_string(s.id); }
void split_ns(long long ns, long long& sec, long long& nsec) {
  sec = ns / 1000000000LL; nsec = ns % 1000000000LL;
  if (nsec < 0) { nsec += 1000000000LL; sec -= 1; }
}
// volume:ino:size:mtime_sec:mtime_nsec:ctime_sec:ctime_nsec, as on Linux.
std::string stamp_of(const Stat& s) {
  long long ms, mn, cs, cn;
  split_ns(unix_ns(s.write), ms, mn);
  split_ns(unix_ns(s.change), cs, cn);
  return identity_of(s) + ":" + std::to_string(s.size) + ":" + std::to_string(ms) +
      ":" + std::to_string(mn) + ":" + std::to_string(cs) + ":" + std::to_string(cn);
}
std::string quote(const std::string& s) {
  std::string out = "\"";
  for (unsigned char c : s) {
    if (c == '"' || c == '\\') { out += '\\'; out += static_cast<char>(c); }
    else if (c < 32) { char buf[7]; snprintf(buf, sizeof(buf), "\\u%04x", c); out += buf; }
    else out += static_cast<char>(c);
  }
  return out + "\"";
}

// ---- process identity and ownership ---------------------------------------

struct Sids {
  std::vector<unsigned char> user, system;
  bool ok = false;
};
const Sids& sids() {
  static const Sids loaded = [] {
    Sids s;
    HANDLE token = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return s;
    DWORD length = 0;
    GetTokenInformation(token, TokenUser, nullptr, 0, &length);
    std::vector<unsigned char> buffer(length);
    if (length && GetTokenInformation(token, TokenUser, buffer.data(), length, &length)) {
      PSID sid = reinterpret_cast<TOKEN_USER*>(buffer.data())->User.Sid;
      s.user.assign(static_cast<unsigned char*>(sid),
          static_cast<unsigned char*>(sid) + GetLengthSid(sid));
      DWORD size = SECURITY_MAX_SID_SIZE;
      s.system.resize(size);
      s.ok = CreateWellKnownSid(WinLocalSystemSid, nullptr, s.system.data(), &size) != 0;
      s.system.resize(size);
    }
    CloseHandle(token);
    return s;
  }();
  return loaded;
}
PSID user_sid() { return const_cast<unsigned char*>(sids().user.data()); }
PSID system_sid() { return const_cast<unsigned char*>(sids().system.data()); }

// The file's owner is this process's user (Linux: st_uid == geteuid()).
// Needs READ_CONTROL on the handle.
bool owned_by_user(HANDLE h) {
  if (!sids().ok) return false;
  PSID owner = nullptr;
  PSECURITY_DESCRIPTOR sd = nullptr;
  if (GetSecurityInfo(h, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION, &owner,
          nullptr, nullptr, nullptr, &sd) != ERROR_SUCCESS) return false;
  bool same = owner && EqualSid(owner, user_sid());
  LocalFree(sd);
  return same;
}
// A private directory (Linux: owner is the user and mode & 077 == 0): owned
// by the user, and every allow entry of its DACL names the user or SYSTEM.
bool private_directory(HANDLE h) {
  Stat s;
  if (stat_of(h, s) || !s.directory() || s.reparse() || !owned_by_user(h)) return false;
  PACL dacl = nullptr;
  PSECURITY_DESCRIPTOR sd = nullptr;
  if (GetSecurityInfo(h, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION, nullptr,
          nullptr, &dacl, nullptr, &sd) != ERROR_SUCCESS) return false;
  bool ok = dacl != nullptr;
  for (DWORD i = 0; ok && i < dacl->AceCount; i++) {
    void* ace = nullptr;
    if (!GetAce(dacl, i, &ace)) { ok = false; break; }
    auto* header = static_cast<ACE_HEADER*>(ace);
    if (header->AceType == ACCESS_DENIED_ACE_TYPE) continue;
    if (header->AceType != ACCESS_ALLOWED_ACE_TYPE) { ok = false; break; }
    // Inherit-only entries count too: they would reach every new child.
    PSID sid = &static_cast<ACCESS_ALLOWED_ACE*>(ace)->SidStart;
    if (!EqualSid(sid, user_sid()) && !EqualSid(sid, system_sid())) ok = false;
  }
  LocalFree(sd);
  return ok;
}

// ---- handle table ---------------------------------------------------------

struct Entry {
  HANDLE h = nullptr;
  bool guard = false;
  ULONGLONG deadline = 0;  // GetTickCount64 ms
  ULONGLONG volume = 0;
  long long id = 0;
  // Guards only (decision #128): what the guard saw at open, re-checked
  // before every act. Size, LastWriteTime, ChangeTime and file id (the
  // stamp) and the link count; any change invalidates the guard for good.
  long long size = 0, write = 0, change = 0;
  ULONG links = 0;
  bool shares_delete = false;  // opened with more than one link
  bool broken = false;
  bool unlinked = false;  // single-link: deleted and its handle closed
};
std::mutex table_mutex;
std::unordered_map<int, Entry> table;
int next_number = 3;

int put(Owned& handle, Entry entry = Entry()) {
  std::lock_guard<std::mutex> lock(table_mutex);
  if (next_number == INT32_MAX) return -lx::MFILE;
  entry.h = handle.release();
  int number = next_number++;
  table[number] = entry;
  return number;
}
bool lookup(int fd, Entry& out) {
  std::lock_guard<std::mutex> lock(table_mutex);
  auto found = table.find(fd);
  if (found == table.end()) return false;
  out = found->second;
  return true;
}
HANDLE handle_of(int fd) {
  Entry e;
  return lookup(fd, e) ? e.h : nullptr;
}

// ---- opens ----------------------------------------------------------------

constexpr ACCESS_MASK kWalk = FILE_READ_ATTRIBUTES;
constexpr ACCESS_MASK kAttributes = FILE_READ_ATTRIBUTES | READ_CONTROL;
constexpr ACCESS_MASK kList = FILE_LIST_DIRECTORY | FILE_TRAVERSE |
    FILE_READ_ATTRIBUTES | READ_CONTROL;
constexpr ACCESS_MASK kRead = FILE_READ_DATA | FILE_READ_ATTRIBUTES | READ_CONTROL;
constexpr ACCESS_MASK kMove = DELETE | FILE_READ_ATTRIBUTES | READ_CONTROL;

enum class Want { Any, Directory, File };

// Opens the existing [name] beneath [dir]: no reparse point, exact name.
int open_leaf(HANDLE dir, const std::wstring& name, ACCESS_MASK access,
    ULONG share, Want want, Owned& out, Stat* stat = nullptr) {
  Owned h;
  int e = nt_open(dir, name, access, share, kFileOpen,
      want == Want::Directory ? kDirectoryFile : 0, h);
  if (e) return e;
  Stat s;
  if ((e = stat_of(h.h, s))) return e;
  if (s.reparse()) return lx::LOOP;
  if ((e = check_name(h.h, name))) return e;
  if (want == Want::File && !s.regular()) return lx::INVAL;
  if (stat) *stat = s;
  out = std::move(h);
  return 0;
}
int duplicate(HANDLE h, Owned& out) {
  HANDLE copy = nullptr;
  if (!DuplicateHandle(GetCurrentProcess(), h, GetCurrentProcess(), &copy, 0,
          FALSE, DUPLICATE_SAME_ACCESS)) return from_win32(GetLastError());
  out = Owned(copy);
  return 0;
}
// Walks every component but the last; [dir] receives the parent directory.
int open_parent(HANDLE root, const std::vector<std::wstring>& parts, Owned& dir) {
  if (!root) return lx::BADF;
  Owned current;
  int e = duplicate(root, current);
  for (size_t i = 0; !e && i + 1 < parts.size(); i++) {
    Owned next;
    e = open_leaf(current.h, parts[i], kWalk, kShareAll, Want::Directory, next);
    if (!e) current = std::move(next);
  }
  if (!e) dir = std::move(current);
  return e;
}
int open_parent(HANDLE root, const char* path, Owned& dir, std::wstring& leaf) {
  std::vector<std::wstring> parts;
  int e = split(path, parts);
  if (e) return e;
  leaf = parts.back();
  return open_parent(root, parts, dir);
}
int open_beneath(HANDLE root, const char* path, ACCESS_MASK access, ULONG share,
    Want want, Owned& out, Stat* stat = nullptr) {
  Owned dir;
  std::wstring leaf;
  int e = open_parent(root, path, dir, leaf);
  return e ? e : open_leaf(dir.h, leaf, access, share, want, out, stat);
}

// An absolute path (as Dart gives it: drive-letter form, either separator),
// opened from the drive root one component at a time, refusing any reparse
// point on the way (Linux: RESOLVE_NO_SYMLINKS). Ancestors are matched
// case-insensitively, as Windows paths are; names beneath a root are exact.
int open_absolute(const char* path, ACCESS_MASK access, ULONG share, Want want,
    Owned& out, Stat* stat = nullptr, std::wstring* leaf_out = nullptr,
    Owned* parent_out = nullptr) {
  std::wstring wide;
  if (!path || !*path || !to_wide(path, strlen(path), wide)) return lx::INVAL;
  // Fully qualified drive paths only (PR #55 review F2): X:\ or X:/, or
  // \\?\X:\. Anything else would resolve against the current drive or
  // directory, or leave the local volume, and is refused before resolution:
  // rooted paths without a drive (/proc/self/fd/4), drive-relative C:foo,
  // relative foo, UNC, \\.\ devices, \\?\UNC and \\?\GLOBALROOT.
  auto drive_rooted = [](const std::wstring& w, size_t at) {
    return w.size() >= at + 3 &&
        ((w[at] >= L'A' && w[at] <= L'Z') || (w[at] >= L'a' && w[at] <= L'z')) &&
        w[at + 1] == L':' && (w[at + 2] == L'\\' || w[at + 2] == L'/');
  };
  if (wide.compare(0, 4, L"\\\\?\\") == 0) {
    if (!drive_rooted(wide, 4)) return lx::INVAL;
    wide = wide.substr(4);
  } else if (!drive_rooted(wide, 0)) {
    return lx::INVAL;
  }
  for (auto& c : wide) if (c == L'/') c = L'\\';
  DWORD n = GetFullPathNameW(wide.c_str(), 0, nullptr, nullptr);
  if (!n) return from_win32(GetLastError());
  std::wstring full(n, L'\0');
  n = GetFullPathNameW(wide.c_str(), n, &full[0], nullptr);
  if (!n) return from_win32(GetLastError());
  full.resize(n);
  // Local drive paths only: no UNC share, device or volume GUID path.
  if (full.size() < 3 || full[1] != L':' || full[2] != L'\\' ||
      !((full[0] >= L'A' && full[0] <= L'Z') || (full[0] >= L'a' && full[0] <= L'z')))
    return lx::INVAL;
  std::vector<std::wstring> parts;
  size_t start = 3;
  while (start < full.size()) {
    size_t end = full.find(L'\\', start);
    std::wstring part = full.substr(start, end == std::wstring::npos ? end : end - start);
    if (!part.empty()) parts.push_back(part);
    if (end == std::wstring::npos) break;
    start = end + 1;
  }
  Owned current;
  std::wstring drive = L"\\??\\" + full.substr(0, 3);
  int e = nt_open(nullptr, drive, parts.empty() ? access : kWalk,
      parts.empty() ? share : kShareAll, kFileOpen, kDirectoryFile, current);
  if (e) return e;
  if (parts.empty()) {
    if (want == Want::File) return lx::INVAL;
    if (stat && (e = stat_of(current.h, *stat))) return e;
    out = std::move(current);
    return 0;
  }
  for (size_t i = 0; i + 1 < parts.size(); i++) {
    Owned next;
    e = nt_open(current.h, parts[i], kWalk, kShareAll, kFileOpen, kDirectoryFile, next);
    if (e) return e;
    TagInfo tag = {};
    if ((e = query(next.h, kFileAttributeTagInformation, tag))) return e;
    if (tag.attributes & FILE_ATTRIBUTE_REPARSE_POINT) return lx::LOOP;
    current = std::move(next);
  }
  Owned last;
  e = nt_open(current.h, parts.back(), access, share, kFileOpen,
      want == Want::Directory ? kDirectoryFile : 0, last);
  if (e) return e;
  Stat s;
  if ((e = stat_of(last.h, s))) return e;
  if (s.reparse()) return lx::LOOP;
  if (want == Want::File && !s.regular()) return lx::INVAL;
  if (stat) *stat = s;
  if (leaf_out) *leaf_out = parts.back();
  if (parent_out) *parent_out = std::move(current);
  out = std::move(last);
  return 0;
}

// ---- namespace changes through handles ------------------------------------

std::atomic<LONG> last_dir_flush{0};
std::atomic<long> dir_flush_refused{0};

int flush_file(HANDLE h) {
  IO_STATUS_BLOCK io = {};
  LONG status = nt().flush(h, &io);
  return status < 0 ? from_status(status) : 0;
}
// Directory durability: NtFlushBuffersFile on a write-access reopen of the
// directory. Where NTFS refuses a directory flush (access or request not
// supported), the rename or link already committed through the NTFS log and
// durability rests on journaling (spec #32 Acceptance row 7, inference); the
// refusal is counted for the W2 evidence. Other failures are errors.
int flush_dir(HANDLE dir) {
  Owned w;
  int e = nt_open(dir, std::wstring(), FILE_ADD_FILE, kShareAll, kFileOpen,
      kDirectoryFile, w);
  LONG status = 0;
  if (!e) {
    IO_STATUS_BLOCK io = {};
    status = nt().flush(w.h, &io);
    if (status < 0) e = from_status(status);
  } else {
    status = static_cast<LONG>(0xC0000022);
  }
  last_dir_flush = status;
  if (e == lx::ACCES || e == lx::NOTSUP || e == lx::INVAL) { dir_flush_refused++; return 0; }
  return e;
}
std::atomic<long> committed_flush_failures{0};
// After a rename, link, create or delete has committed, a failing directory
// flush must not report the change as failed (the next attempt would then
// meet EEXIST): it is counted (anj_win_flush_failures), as Linux ignores
// fsync failures after linkat (PR #55 review F9).
void flush_committed(HANDLE dir) {
  if (flush_dir(dir) != 0) committed_flush_failures++;
}
std::vector<unsigned char> link_rename(HANDLE target, const std::wstring& name) {
  size_t offset = offsetof(LinkRename, name);
  std::vector<unsigned char> buffer(offset + (name.size() + 1) * sizeof(WCHAR));
  auto* info = reinterpret_cast<LinkRename*>(buffer.data());
  info->replace = FALSE;
  info->root = target;
  info->length = static_cast<ULONG>(name.size() * sizeof(WCHAR));
  memcpy(info->name, name.c_str(), name.size() * sizeof(WCHAR));
  return buffer;
}
// Never replaces: an occupied destination (case-insensitively) is EEXIST.
// NTFS treats a rename onto another link of the same file as success and
// removes the source name (observed on the seat, W2); that destination is
// occupied too, so it is refused first.
// A case-only rename of a link to its own name (report.txt to Report.txt)
// finds that same link, and is allowed, as on Linux (review F7); the exact
// same name stays EEXIST, as RENAME_NOREPLACE.
int rename_into(HANDLE source, HANDLE target_dir, const std::wstring& name) {
  Owned existing;
  if (nt_open(target_dir, name, kWalkAccess, kShareAll, kFileOpen, 0, existing) == 0) {
    Stat a, b;
    if (stat_of(source, a) == 0 && stat_of(existing.h, b) == 0 &&
        a.volume == b.volume && a.id == b.id) {
      std::wstring from, at;
      if (normalized_name(source, from) || normalized_name(existing.h, at) || from != at)
        return lx::EXIST;  // another link of the same file
      size_t slash = from.rfind(L'\\');
      if (from.substr(slash == std::wstring::npos ? 0 : slash + 1) == name) return lx::EXIST;
    }
  }
  existing.reset();
  auto buffer = link_rename(target_dir, name);
  return set_info(source, kFileRenameInformation, buffer.data(),
      static_cast<ULONG>(buffer.size()));
}
int link_into(HANDLE source, HANDLE target_dir, const std::wstring& name) {
  auto buffer = link_rename(target_dir, name);
  return set_info(source, kFileLinkInformation, buffer.data(),
      static_cast<ULONG>(buffer.size()));
}
// POSIX semantics: the name is gone when this handle closes, even while
// other handles (sharing delete) stay open. The read-only attribute is
// ignored, as Linux unlink ignores the mode (review F6). NTFS refuses a file
// with a writable mapping (EBUSY). Where NTFS does not take a flag (older
// builds), the next weaker disposition is tried; the plain delete removes
// the name once the last handle closes.
int posix_delete(HANDLE h) {
  const ULONG tries[] = {kDispositionDelete | kDispositionPosix | kDispositionIgnoreReadOnly,
      kDispositionDelete | kDispositionPosix, kDispositionDelete};
  int e = lx::INVAL;
  for (ULONG flags : tries) {
    DispositionEx d = {flags};
    e = set_info(h, kFileDispositionInformationEx, &d, sizeof(d));
    if (e != lx::INVAL && e != lx::NOTSUP) break;
  }
  return e;
}
int create_child(HANDLE dir, const std::wstring& name, ACCESS_MASK access,
    ULONG share, bool directory, Owned& out) {
  return nt_open(dir, name, access, share, kFileCreate,
      directory ? kDirectoryFile : kNonDirectoryFile, out);
}

// ---- enumeration ----------------------------------------------------------

// No "birth" field (flag SC-074): the NTFS file id carries the MFT sequence
// number, so a folder deleted and created again never repeats its id, and
// CreationTime is no proof (applications set it, and NTFS tunnelling gives a
// name recreated within 15 s its old creation time). The engine falls back
// to the id alone, which suffices here.
std::string item_json(const std::string& relative, const char* kind, const Stat& s) {
  return "{\"path\":" + quote(relative) + ",\"kind\":" + quote(kind) +
      ",\"size\":" + std::to_string(s.size) + ",\"inode\":" + std::to_string(s.id) +
      ",\"links\":" + std::to_string(s.links) +
      ",\"volume\":" + quote(volume_key(s)) + ",\"mtime\":" +
      std::to_string(unix_ns(s.write)) + ",\"ctime\":" +
      std::to_string(unix_ns(s.change)) + "}";
}
const char* kind_of(const Stat& s) {
  return s.reparse() ? "unsupported" : s.directory() ? "directory" : "file";
}
bool vanished(int e) { return e == lx::NOENT || e == lx::NOTDIR || e == lx::LOOP; }
struct Listing { std::string items; bool first = true; };
void add_item(Listing& out, const std::string& item) {
  if (!out.first) out.items += ',';
  out.first = false;
  out.items += item;
}
// Lists [dir] (open with FILE_LIST_DIRECTORY) and everything beneath it.
// Each entry is stat'ed through its own attribute-only handle (FILE_READ_
// ATTRIBUTES takes no part in sharing checks): a directory entry's cached
// size and times can lag an open writer. Reparse points are listed as
// unsupported and never entered. A name that is not valid UTF-16 is listed as
// unsupported. Entries that vanish mid-walk are skipped.
int list(HANDLE dir, const std::string& prefix, Listing& out) {
  std::vector<unsigned char> buffer(64 * 1024);
  std::vector<std::pair<std::wstring, std::string>> children;
  bool restart = TRUE;
  while (true) {
    IO_STATUS_BLOCK io = {};
    LONG status = nt().directory(dir, nullptr, nullptr, nullptr, &io, buffer.data(),
        static_cast<ULONG>(buffer.size()), kFileDirectoryInformation, FALSE,
        nullptr, restart ? TRUE : FALSE);
    restart = false;
    if (status == kStatusNoMoreFiles) break;
    if (status < 0) return from_status(status);
    size_t offset = 0;
    while (true) {
      auto* info = reinterpret_cast<DirectoryInfo*>(buffer.data() + offset);
      std::wstring name(info->name, info->length / sizeof(WCHAR));
      if (name != L"." && name != L"..") {
        std::string utf8;
        bool readable = to_utf8(name.c_str(), name.size(), utf8);
        if (!readable) {
          // Unpaired surrogate: not representable as a root-relative path.
          utf8.clear();
          for (WCHAR c : name) utf8 += (c < 0x80 && c >= 0x20) ? static_cast<char>(c) : '?';
        }
        std::string relative = prefix.empty() ? utf8 : prefix + "/" + utf8;
        Owned child;
        int e = nt_open(dir, name, kWalk, kShareAll, kFileOpen, 0, child);
        Stat s;
        if (!e) e = stat_of(child.h, s);
        if (e && !vanished(e)) return e;
        if (!e) {
          // A name every other call refuses (review F3) is listed as
          // unsupported and never entered, as an unreadable one is.
          bool usable = readable && component_error(name) == 0;
          add_item(out, item_json(relative, usable ? kind_of(s) : "unsupported", s));
          if (usable && s.directory() && !s.reparse()) children.emplace_back(name, relative);
        }
      }
      if (!info->next) break;
      offset += info->next;
    }
  }
  for (const auto& child : children) {
    Owned sub;
    int e = open_leaf(dir, child.first, kList, kShareAll, Want::Directory, sub);
    if (e) { if (vanished(e)) continue; return e; }
    if ((e = list(sub.h, child.second, out))) return e;
  }
  return 0;
}

char* duplicate_string(const std::string& value) {
  char* out = static_cast<char*>(malloc(value.size() + 1));
  if (out) memcpy(out, value.c_str(), value.size() + 1);
  return out;
}
int fail(int e) { error_number = e; return -1; }
char* fail_null(int e) { error_number = e; return nullptr; }
int done(int e) { error_number = e; return e ? -1 : 0; }

std::string info_json(HANDLE h, const Stat& s) {
  long long ms = unix_ns(s.write) / 1000000LL;
  return "{\"identity\":" + quote(identity_of(s)) + ",\"stamp\":" + quote(stamp_of(s)) +
      ",\"links\":" + std::to_string(s.links) + ",\"allocated\":" +
      std::to_string(s.allocated) + ",\"size\":" + std::to_string(s.size) +
      ",\"owned\":" + (owned_by_user(h) ? "true" : "false") + ",\"modifiedMs\":" +
      std::to_string(ms) + "}";
}

// The local fixed NTFS volume rule (spec #32 Native Boundary, root refusal).
int check_volume(HANDLE h) {
  std::vector<unsigned char> buffer(512);
  IO_STATUS_BLOCK io = {};
  LONG status = nt().volume(h, &io, buffer.data(), static_cast<ULONG>(buffer.size()),
      kFsAttributeInformation);
  if (status < 0 && status != kStatusBufferOverflow) return from_status(status);
  auto* attr = reinterpret_cast<FsAttribute*>(buffer.data());
  std::wstring fs(attr->name, attr->length / sizeof(WCHAR));
  FsDevice device = {};
  io = {};
  status = nt().volume(h, &io, &device, sizeof(device), kFsDeviceInformation);
  if (status < 0) return from_status(status);
  if (fs != L"NTFS" || device.type != kDeviceDisk ||
      (device.characteristics & (kRemovableMedia | kRemoteDevice))) return lx::NOTSUP;
  return 0;
}

int open_root_handle(const char* path, Owned& out, Stat* stat = nullptr) {
  // Shares read and write but not delete: the root (and staging) cannot be
  // renamed or deleted while the client holds it (spec #32 handle hold times).
  int e = open_absolute(path, kList, FILE_SHARE_READ | FILE_SHARE_WRITE,
      Want::Directory, out, stat);
  if (!e) e = check_volume(out.h);
  if (e) out.reset();
  return e;
}

// The guard still holds what it saw at open: within its deadline, not
// broken, and the held handle's stamp and link count unchanged. Any change
// (a supersede that truncates, a write through a delete-sharing handle, a
// new hard link) breaks the guard permanently (ESTALE); a passed deadline is
// EAGAIN, as on Linux. Reads the entry fresh from the table.
int guard_check(int fd, Entry& out) {
  if (!lookup(fd, out) || !out.guard || out.unlinked || GetTickCount64() > out.deadline)
    return lx::AGAIN;
  if (out.broken) return lx::STALE;
  Stat s;
  int e = stat_of(out.h, s);
  if (e || s.size != out.size || s.write != out.write || s.change != out.change ||
      s.links != out.links || s.volume != out.volume || s.id != out.id) {
    std::lock_guard<std::mutex> lock(table_mutex);
    auto found = table.find(fd);
    if (found != table.end()) found->second.broken = true;
    return lx::STALE;
  }
  return 0;
}
// After the guard's own namespace change: the rename or unlink moved the
// file's change time (and an alias unlink its link count, to
// [expected_links]); size, write time and id must be what the guard saw.
// Anything else broke the guard during the act.
int guard_refresh(int fd, ULONG expected_links) {
  std::lock_guard<std::mutex> lock(table_mutex);
  auto found = table.find(fd);
  if (found == table.end() || !found->second.guard) return lx::AGAIN;
  Entry& g = found->second;
  Stat s;
  if (stat_of(g.h, s) || s.size != g.size || s.write != g.write || s.id != g.id ||
      s.volume != g.volume || s.links != expected_links) {
    g.broken = true;
    return lx::STALE;
  }
  g.change = s.change;
  g.links = s.links;
  return 0;
}
// Opens [name] in [dir] and proves on that same handle that it is the
// guarded file, so no lookup separates the check from the act. A single-link
// guard shares nothing, so only an attribute handle can be opened beside it
// (the act then goes through the guard's own handle); a multi-link guard
// shares delete, and the per-name handle carries DELETE.
int open_guarded(const Entry& guard, HANDLE dir, const std::wstring& name, Owned& out) {
  Stat s;
  int e = open_leaf(dir, name, guard.shares_delete ? kMove : kWalk, kShareAll, Want::File,
      out, &s);
  if (e) return e;
  if (s.volume != guard.volume || s.id != guard.id) { out.reset(); return lx::STALE; }
  return 0;
}

// The ACL privateDir writes: full control for the user and SYSTEM only.
bool private_acl(std::vector<unsigned char>& buffer, BYTE flags) {
  if (!sids().ok) return false;
  DWORD size = sizeof(ACL) + 2 * (sizeof(ACCESS_ALLOWED_ACE) - sizeof(DWORD)) +
      GetLengthSid(user_sid()) + GetLengthSid(system_sid());
  buffer.assign(size, 0);
  auto* acl = reinterpret_cast<PACL>(buffer.data());
  return InitializeAcl(acl, size, ACL_REVISION) &&
      AddAccessAllowedAceEx(acl, ACL_REVISION, flags, FILE_ALL_ACCESS, user_sid()) &&
      AddAccessAllowedAceEx(acl, ACL_REVISION, flags, FILE_ALL_ACCESS, system_sid());
}
int apply_acl(HANDLE h, BYTE flags, bool protect) {
  std::vector<unsigned char> acl;
  if (!private_acl(acl, flags)) return lx::NOMEM;
  SECURITY_DESCRIPTOR sd;
  if (!InitializeSecurityDescriptor(&sd, SECURITY_DESCRIPTOR_REVISION) ||
      !SetSecurityDescriptorDacl(&sd, TRUE, reinterpret_cast<PACL>(acl.data()), FALSE) ||
      !SetSecurityDescriptorControl(&sd, SE_DACL_PROTECTED | SE_DACL_AUTO_INHERITED,
          (protect ? SE_DACL_PROTECTED : 0) | SE_DACL_AUTO_INHERITED))
    return from_win32(GetLastError());
  SECURITY_INFORMATION what = DACL_SECURITY_INFORMATION |
      (protect ? PROTECTED_DACL_SECURITY_INFORMATION : UNPROTECTED_DACL_SECURITY_INFORMATION);
  return SetKernelObjectSecurity(h, what, &sd) ? 0 : from_win32(GetLastError());
}

// ---- change watching (spec #32 File Watching) -----------------------------
//
// One recursive ReadDirectoryChangesExW on an overlapped handle reopened from
// the root's (bWatchSubtree, file name, directory name, size, last write and
// creation; not last access or security), serviced by one thread of this
// DLL. Notifications become the shared compact records (watch_translate.h)
// in a bounded queue the watcher isolate drains through anj_watch_wait.
// Only the root is watched: anj_watch_add of a directory beneath it is
// bookkeeping (a descriptor for the shared watcher's map), and
// anj_watch_scan reports no watches. Overflow (ERROR_NOTIFY_ENUM_DIR or a
// completion of zero bytes) is the full-audit record. A watch handle that
// fails or is closed under the thread ends it with a root record and the
// error, which the shared watcher reports as a failure: the engine then
// stat-scans every pass and restarts the watcher with the same settings.
// The staging sibling is outside the root and never watched.
constexpr DWORD kWatchFilter = FILE_NOTIFY_CHANGE_FILE_NAME |
    FILE_NOTIFY_CHANGE_DIR_NAME | FILE_NOTIFY_CHANGE_SIZE |
    FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_CREATION;
// Kernel-side buffer for one watch (allocated by the first read, the same
// size as this one): about 10,000 extended notifications before overflow.
constexpr DWORD kWatchBuffer = 1u << 20;
// Overflows (zero-byte completions or ERROR_NOTIFY_ENUM_DIR) this many times
// within this window: the reads make no progress (a 1 MiB buffer needs about
// 10,000 notifications between two reads to overflow once), so the watch is
// failed rather than reissued without limit. The engine then stat-scans and
// restarts the watcher with the same settings.
constexpr size_t kOverflowLimit = 32;
constexpr ULONGLONG kOverflowWindowMs = 1000;

struct Watch {
  HANDLE wake = nullptr;        // manual reset: records pending, a stop, a failure
  HANDLE stop_event = nullptr;  // manual reset: the thread ends
  HANDLE thread = nullptr;
  HANDLE dir = nullptr;         // overlapped watch handle on the root
  std::atomic<long long> acked{0};
  std::atomic<int> refs{2};
  std::atomic<bool> stopping{false};
  long long offset = 0;  // sleep offset at the previous wait
  DWORD buffer_bytes = kWatchBuffer;
  std::mutex lock;  // everything below
  anj_watch::Queue queue;
  std::map<std::string, int> path_wd;
  std::map<int, std::string> wd_path;
  std::map<int, long long> wd_id;
  int next_wd = 1;
  int root_wd = -1;
  bool ended = false;   // the thread ended without a stop: the watch failed
  int end_errno = 0;
  bool extended = true;  // ReadDirectoryChangesExW extended information
  long long skew = 0;    // test seam: added to the sleep-inclusive clock
  bool fail_set = false;
  std::string fail_prefix;
};

// Nanoseconds the sleep-inclusive clock (interrupt time) is ahead of the
// sleep-exclusive one (unbiased interrupt time); a jump is a suspend.
long long sleep_offset(Watch* w) {
  ULONGLONG unbiased = 0;
  QueryUnbiasedInterruptTime(&unbiased);
  long long skew;
  { std::lock_guard<std::mutex> hold(w->lock); skew = w->skew; }
  return static_cast<long long>(GetTickCount64()) * 1000000LL + skew -
      static_cast<long long>(unbiased) * 100LL;
}

// Under w->lock. One notification entry, extended or plain.
// Converted component by component: a component that is not valid UTF-16
// (a lone surrogate) audits its parent by stat, not the whole root.
void watch_entry(Watch* w, DWORD action, const WCHAR* name, size_t chars, bool directory) {
  std::string relative, component;
  size_t begin = 0;
  for (size_t i = 0; i <= chars; i++) {
    if (i < chars && name[i] != L'\\' && name[i] != L'/') continue;
    if (!to_utf8(name + begin, i - begin, component)) {
      anj_watch::unreadable(w->queue, w->root_wd, relative);
      return;
    }
    if (begin) relative += '/';
    relative += component;
    begin = i + 1;
  }
  anj_watch::translate(w->queue, w->root_wd, action, directory, relative);
}
void watch_batch(Watch* w, const unsigned char* data, DWORD bytes) {
  std::lock_guard<std::mutex> hold(w->lock);
  DWORD offset = 0;
  while (offset < bytes) {
    DWORD next;
    if (w->extended) {
      auto* info = reinterpret_cast<const FILE_NOTIFY_EXTENDED_INFORMATION*>(data + offset);
      watch_entry(w, info->Action, info->FileName, info->FileNameLength / sizeof(WCHAR),
          (info->FileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0);
      next = info->NextEntryOffset;
    } else {
      auto* info = reinterpret_cast<const FILE_NOTIFY_INFORMATION*>(data + offset);
      watch_entry(w, info->Action, info->FileName, info->FileNameLength / sizeof(WCHAR), false);
      next = info->NextEntryOffset;
    }
    if (!next) break;
    offset += next;
  }
}

DWORD watch_issue(Watch* w, std::vector<DWORD>& buffer, OVERLAPPED& ov) {
  ResetEvent(ov.hEvent);
  DWORD bytes = static_cast<DWORD>(buffer.size() * sizeof(DWORD));
  if (w->extended) {
    if (ReadDirectoryChangesExW(w->dir, buffer.data(), bytes, TRUE, kWatchFilter, nullptr,
            &ov, nullptr, ReadDirectoryNotifyExtendedInformation)) return 0;
    DWORD e = GetLastError();
    if (e != ERROR_INVALID_FUNCTION && e != ERROR_NOT_SUPPORTED && e != ERROR_INVALID_PARAMETER)
      return e;
    std::lock_guard<std::mutex> hold(w->lock);
    w->extended = false;  // an older system: plain notifications
  }
  return ReadDirectoryChangesW(w->dir, buffer.data(), bytes, TRUE, kWatchFilter, nullptr,
             &ov, nullptr) ? 0 : GetLastError();
}

struct WatchStart { Watch* w; HANDLE started; DWORD error; };

DWORD WINAPI watch_thread(void* argument) {
  auto* start = static_cast<WatchStart*>(argument);
  Watch* w = start->w;
  // Two buffers: one is read again at once while the other is translated.
  std::vector<DWORD> current((w->buffer_bytes + 3) / 4), previous(current.size());
  OVERLAPPED ov = {};
  ov.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  DWORD e = ov.hEvent ? watch_issue(w, current, ov) : GetLastError();
  start->error = e;
  SetEvent(start->started);  // [start] is gone after this
  bool pending = e == 0;
  std::deque<ULONGLONG> overflows;  // tick counts of recent overflows
  auto overflowed = [&]() {
    { std::lock_guard<std::mutex> hold(w->lock); w->queue.overflow(); }
    ULONGLONG now = GetTickCount64();
    overflows.push_back(now);
    while (now - overflows.front() > kOverflowWindowMs) overflows.pop_front();
    return overflows.size() >= kOverflowLimit;  // true: no progress, fail
  };
  while (!e) {
    HANDLE handles[2] = {ov.hEvent, w->stop_event};
    DWORD r = WaitForMultipleObjects(2, handles, FALSE, INFINITE);
    if (r != WAIT_OBJECT_0) {
      if (r != WAIT_OBJECT_0 + 1) e = GetLastError();
      break;
    }
    DWORD n = 0;
    pending = false;
    if (!GetOverlappedResult(w->dir, &ov, &n, FALSE)) {
      e = GetLastError();
      if (e != ERROR_NOTIFY_ENUM_DIR) break;
      if (overflowed()) break;
      SetEvent(w->wake);
      e = watch_issue(w, current, ov);
      pending = e == 0;
      continue;
    }
    if (n == 0) {
      // The kernel buffer overflowed: changes were lost.
      if (overflowed()) { e = ERROR_NOTIFY_ENUM_DIR; break; }
      e = watch_issue(w, current, ov);
      pending = e == 0;
    } else {
      current.swap(previous);
      e = watch_issue(w, current, ov);
      pending = e == 0;
      watch_batch(w, reinterpret_cast<const unsigned char*>(previous.data()), n);
    }
    SetEvent(w->wake);
  }
  if (pending) {
    CancelIoEx(w->dir, &ov);
    DWORD ignored = 0;
    GetOverlappedResult(w->dir, &ov, &ignored, TRUE);
  }
  if (ov.hEvent) CloseHandle(ov.hEvent);
  if (!w->stopping.load()) {
    // The watch handle failed or was closed: audit the root, then report.
    std::lock_guard<std::mutex> hold(w->lock);
    w->queue.root_self(w->root_wd);
    w->ended = true;
    w->end_errno = e ? from_win32(e) : lx::IO;
  }
  SetEvent(w->wake);
  return 0;
}

// Reopens the root (an empty name relative to its handle) for overlapped
// reads: same directory, every sharing mode, so the watch blocks nothing the
// root handle does not.
int open_watch_handle(HANDLE root, Owned& out) {
  const Nt& n = nt();
  if (!n.ok) return lx::NOTSUP;
  UNICODE_STRING us = {};
  OBJECT_ATTRIBUTES oa;
  InitializeObjectAttributes(&oa, &us, 0, root, nullptr);
  IO_STATUS_BLOCK io = {};
  HANDLE h = nullptr;
  LONG status = n.create(&h, FILE_LIST_DIRECTORY | SYNCHRONIZE, &oa, &io, nullptr,
      FILE_ATTRIBUTE_NORMAL, kShareAll, kFileOpen, kDirectoryFile | kOpenReparsePoint,
      nullptr, 0);
  if (status < 0) return from_status(status);
  out = Owned(h);
  return 0;
}

// Starts the thread on the root's handle. Called only through anj_watch_add
// of the root, by the worker, never concurrently with itself.
int watch_start(Watch* w, HANDLE root) {
  Owned dir;
  int e = open_watch_handle(root, dir);
  if (e) return e;
  w->dir = dir.release();
  WatchStart start = {w, CreateEventW(nullptr, TRUE, FALSE, nullptr), 0};
  if (!start.started) { e = from_win32(GetLastError()); CloseHandle(w->dir); w->dir = nullptr; return e; }
  w->thread = CreateThread(nullptr, 0, watch_thread, &start, 0, nullptr);
  if (!w->thread) {
    e = from_win32(GetLastError());
  } else {
    WaitForSingleObject(start.started, INFINITE);
    if (start.error) {
      e = from_win32(start.error);
      WaitForSingleObject(w->thread, INFINITE);
      CloseHandle(w->thread);
      w->thread = nullptr;
      std::lock_guard<std::mutex> hold(w->lock);
      // A start that failed is not a watch that failed later.
      w->ended = false;
      w->queue = anj_watch::Queue();
    }
  }
  CloseHandle(start.started);
  if (e) { CloseHandle(w->dir); w->dir = nullptr; }
  return e;
}

bool watch_fails(Watch* w, const std::string& path) {
  std::lock_guard<std::mutex> hold(w->lock);
  if (!w->fail_set) return false;
  const std::string& f = w->fail_prefix;
  return f.empty() || path == f ||
      (path.size() > f.size() && path.compare(0, f.size(), f) == 0 && path[f.size()] == '/');
}
}  // namespace

// ---- the anj_* ABI ----------------------------------------------------------

ANJ_API int anj_error() { return error_number; }
// Stable symbolic name of an errno value from this boundary (spec #31 S2);
// the numbers are Linux's on every platform this DLL serves. Static storage.
ANJ_API const char* anj_error_name(int code) {
  switch (code) {
    case 0: return "none";
    case lx::AGAIN: return "wouldBlock";
    case lx::BUSY: return "busy";
    case lx::EXIST: return "exists";
    case lx::NOENT: return "notFound";
    case lx::LOOP: return "loop";
    case lx::XDEV: return "crossDevice";
    case lx::NOTEMPTY: return "notEmpty";
    case lx::NOTDIR: return "notDirectory";
    case lx::ISDIR: return "isDirectory";
    case lx::STALE: return "stale";
    case lx::INVAL: return "invalid";
    case lx::PERM: case lx::ACCES: return "permission";
    case lx::NOTSUP: return "notSupported";
    case lx::NOSPC: return "noSpace";
    case lx::MLINK: return "tooManyLinks";
    case lx::NAMETOOLONG: return "nameTooLong";
    case lx::IO: return "io";
    default: return "other";
  }
}
// The guard this library implements (ReleaseGuardStrength in Dart): an
// exclusive open, which refuses while any other data handle is open and
// makes every data open during the window fail (spec #32 Cloud Release
// Guard). Proposed as its own value; see the W2 PR.
ANJ_API const char* anj_guard_kind() { return "exclusiveOpen"; }
// A directory path through which Dart file I/O reaches the entries of the
// open staging directory [fd] (spec #31 S2.3): its current final path
// (GetFinalPathNameByHandleW), returned only after that path, opened again
// without following a reparse point, proves to be this same directory.
// Drive form without the \\?\ prefix, so callers may append "/name".
// Caller frees with anj_free; null with an error.
ANJ_API char* anj_stage_path(int fd) {
  HANDLE h = handle_of(fd);
  if (!h) return fail_null(lx::BADF);
  DWORD n = GetFinalPathNameByHandleW(h, nullptr, 0, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (!n) return fail_null(from_win32(GetLastError()));
  std::wstring path(n, L'\0');
  n = GetFinalPathNameByHandleW(h, &path[0], n, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (!n || n >= path.size()) return fail_null(n ? lx::STALE : from_win32(GetLastError()));
  path.resize(n);
  if (path.compare(0, 4, L"\\\\?\\") == 0) path = path.substr(4);
  if (path.size() < 3 || path[1] != L':' || path[2] != L'\\') return fail_null(lx::NOTSUP);
  std::string utf8;
  if (!to_utf8(path.c_str(), path.size(), utf8)) return fail_null(lx::INVAL);
  Owned again;
  Stat now, held;
  if (open_absolute(utf8.c_str(), kWalk, kShareAll, Want::Directory, again, &now) ||
      stat_of(h, held) || now.volume != held.volume || now.id != held.id)
    return fail_null(lx::STALE);
  error_number = 0;
  return duplicate_string(utf8);
}
// The profile lifetime lock (spec #32 Desktop Session; Linux: flock in
// native/posix/lifecycle.inc): <profile>\.instance.lock opened with share
// mode 0 and held until the process ends, so a second process (or a second
// open in this one) fails with a sharing violation, reported as EAGAIN
// ("wouldBlock", as Linux's EWOULDBLOCK) and shown as "already running". The
// kernel closes the handle at exit, logoff or a crash, so the lock never
// outlives the process. [path] must be the profile's exact final path
// (Linux: realpath) and a private directory owned by the user; the lock
// file must be a regular single-link file owned by the user. An inherited
// lock (the Linux manager's handoff) is not a Windows mechanism (ENOTSUP;
// spec #32 W5).
ANJ_API int anj_profile_lock(const char* path, int inherited) {
  if (inherited != -1) return fail(lx::NOTSUP);
  Owned dir;
  Stat ds;
  int e = open_absolute(path, kList, kShareAll, Want::Directory, dir, &ds);
  if (e) return fail(e);
  // The exact final path, compared as Windows compares paths.
  {
    DWORD n = GetFinalPathNameByHandleW(dir.h, nullptr, 0, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    std::wstring final_path(n, L'\0');
    if (!n || !(n = GetFinalPathNameByHandleW(dir.h, &final_path[0], n,
            FILE_NAME_NORMALIZED | VOLUME_NAME_DOS)) || n >= final_path.size())
      return fail(lx::INVAL);
    final_path.resize(n);
    if (final_path.compare(0, 4, L"\\\\?\\") == 0) final_path = final_path.substr(4);
    std::wstring given;
    if (!to_wide(path, strlen(path), given)) return fail(lx::INVAL);
    for (auto& c : given) if (c == L'/') c = L'\\';
    if (given.compare(0, 4, L"\\\\?\\") == 0) given = given.substr(4);
    if (CompareStringOrdinal(final_path.c_str(), static_cast<int>(final_path.size()),
            given.c_str(), static_cast<int>(given.size()), TRUE) != CSTR_EQUAL)
      return fail(lx::INVAL);
  }
  if (!private_directory(dir.h)) return fail(lx::PERM);
  Owned lock;
  e = nt_open(dir.h, L".instance.lock", GENERIC_READ | GENERIC_WRITE | READ_CONTROL, 0,
      3 /* FILE_OPEN_IF */, kNonDirectoryFile, lock);
  if (e == lx::BUSY) return fail(lx::AGAIN);
  if (e) return fail(e);
  Stat ls;
  if ((e = stat_of(lock.h, ls))) return fail(e);
  if (!ls.regular() || ls.links != 1 || !owned_by_user(lock.h)) return fail(lx::STALE);
  int fd = put(lock);
  return fd < 0 ? fail(-fd) : (error_number = 0, fd);
}
ANJ_API void anj_free(void* value) { free(value); }

ANJ_API int anj_open_root(const char* path) {
  Owned h;
  int e = open_root_handle(path, h);
  if (e) return fail(e);
  int fd = put(h);
  return fd < 0 ? fail(-fd) : (error_number = 0, fd);
}
ANJ_API int anj_check_root(int fd, const char* path) {
  HANDLE held = handle_of(fd);
  if (!held) return fail(lx::BADF);
  Owned current;
  Stat now, before;
  bool ok = open_root_handle(path, current, &now) == 0 && stat_of(held, before) == 0 &&
      now.volume == before.volume && now.id == before.id;
  return done(ok ? 0 : lx::STALE);
}
ANJ_API int anj_close(int fd) {
  HANDLE h = nullptr;
  {
    std::lock_guard<std::mutex> lock(table_mutex);
    auto found = table.find(fd);
    if (found == table.end()) return fail(lx::BADF);
    h = found->second.h;
    table.erase(found);
  }
  CloseHandle(h);
  error_number = 0;
  return 0;
}
ANJ_API char* anj_scan(int fd) {
  HANDLE root = handle_of(fd);
  if (!root) return fail_null(lx::BADF);
  Listing out;
  int e = list(root, "", out);
  if (e) return fail_null(e);
  error_number = 0;
  return duplicate_string("[" + out.items + "]");
}
// Stat-only listing of [path] ('' = the root's whole tree) and, when it is a
// directory and [recursive] is set, of everything beneath it. A path that is
// missing or no longer reachable without a reparse point yields no items.
// The one recursive watch on the root covers every directory, including new
// ones, so [handle] (the watcher's, or null) adds nothing and no watches are
// reported (spec #32 File Watching).
ANJ_API char* anj_watch_scan(void*, int fd, const char* path, int recursive) {
  HANDLE root = handle_of(fd);
  if (!root) return fail_null(lx::BADF);
  if (!path) return fail_null(lx::INVAL);
  Listing out;
  int e = 0;
  if (!*path) {
    e = list(root, "", out);
  } else {
    // A non-portable leaf the scan listed as unsupported is stat'ed and
    // reported the same way; beneath a non-portable directory nothing is
    // listed (the scan never entered it).
    std::vector<std::wstring> parts;
    size_t non_portable = 0;
    e = split(path, parts, true, &non_portable);
    if (e) return fail_null(e);
    bool odd_leaf = component_error(parts.back()) == kNonPortable;
    if (non_portable > (odd_leaf ? 1u : 0u)) {
      error_number = 0;
      return duplicate_string("{\"items\":[],\"watches\":[]}");
    }
    Owned dir;
    std::wstring leaf = parts.back();
    e = open_parent(root, parts, dir);
    if (!e) {
      Owned item;
      Stat s;
      e = nt_open(dir.h, leaf, kWalk, kShareAll, kFileOpen, 0, item);
      if (!e) e = stat_of(item.h, s);
      if (!e) e = check_name(item.h, leaf);
      if (!e) {
        add_item(out, item_json(path, odd_leaf ? "unsupported" : kind_of(s), s));
        if (!odd_leaf && recursive && s.directory() && !s.reparse()) {
          Owned sub;
          e = open_leaf(dir.h, leaf, kList, kShareAll, Want::Directory, sub);
          if (!e) e = list(sub.h, path, out);
        }
      }
    }
    if (e && vanished(e)) e = 0;
  }
  if (e) return fail_null(e);
  error_number = 0;
  return duplicate_string("{\"items\":[" + out.items + "],\"watches\":[]}");
}
// The watcher (spec #32 File Watching; see "change watching" above): the
// same anj_watch_* ABI and compact records as native/posix, so the shared
// Dart watcher runs unchanged on top of it.
ANJ_API void* anj_watch_open() {
  auto* w = new Watch();
  w->wake = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  w->stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!w->wake || !w->stop_event) {
    int e = from_win32(GetLastError());
    if (w->wake) CloseHandle(w->wake);
    if (w->stop_event) CloseHandle(w->stop_event);
    delete w;
    error_number = e;
    return nullptr;
  }
  w->offset = sleep_offset(w);
  error_number = 0;
  return w;
}
// Each of the two owners (worker and watcher isolate) releases once; the
// last one ends the thread and frees everything.
ANJ_API void anj_watch_release(void* handle) {
  auto* w = static_cast<Watch*>(handle);
  if (w->refs.fetch_sub(1) != 1) return;
  w->stopping = true;
  SetEvent(w->stop_event);
  if (w->thread) {
    WaitForSingleObject(w->thread, INFINITE);
    CloseHandle(w->thread);
  }
  if (w->dir) CloseHandle(w->dir);
  CloseHandle(w->wake);
  CloseHandle(w->stop_event);
  delete w;
}
ANJ_API void anj_watch_stop(void* handle) {
  auto* w = static_cast<Watch*>(handle);
  w->stopping = true;
  SetEvent(w->stop_event);
  SetEvent(w->wake);
}
// ReadDirectoryChangesW holds nothing back: nothing to tune (FSEvents
// latency on Darwin).
ANJ_API void anj_watch_latency(void*, long long) {}
// The root (empty path) starts the one recursive watch; a directory beneath
// it gets a bookkeeping descriptor (re-adding the same directory returns
// it; another directory at that path gets a new one). identity receives
// {0, file id} and volume the volume key, as the scans report them.
ANJ_API int anj_watch_add(void* handle, int root, const char* path, long long* identity,
    char* volume, int capacity) {
  auto* w = static_cast<Watch*>(handle);
  HANDLE held = handle_of(root);
  if (!held) return fail(lx::BADF);
  if (!path) return fail(lx::INVAL);
  std::string relative(path);
  if (watch_fails(w, relative)) return fail(lx::NOSPC);
  Stat s;
  int e;
  if (relative.empty()) {
    e = stat_of(held, s);
  } else {
    Owned dir;
    e = open_beneath(held, path, kWalk, kShareAll, Want::Directory, dir, &s);
  }
  if (e) return fail(e);
  if (relative.empty() && !w->thread) {
    if ((e = watch_start(w, held))) return fail(e);
  } else if (!w->thread) {
    return fail(lx::NOTCONN);  // the root is always watched first
  }
  int wd;
  {
    std::lock_guard<std::mutex> hold(w->lock);
    auto known = w->path_wd.find(relative);
    if (known != w->path_wd.end() && w->wd_id[known->second] == s.id) {
      wd = known->second;
    } else {
      wd = w->next_wd++;
      w->path_wd[relative] = wd;
      w->wd_path[wd] = relative;
      w->wd_id[wd] = s.id;
      if (relative.empty()) w->root_wd = wd;
    }
  }
  if (volume && capacity > 0) snprintf(volume, static_cast<size_t>(capacity), "%s", volume_key(s).c_str());
  if (identity) { identity[0] = 0; identity[1] = s.id; }
  error_number = 0;
  return wd;
}
ANJ_API int anj_watch_remove(void* handle, int wd) {
  auto* w = static_cast<Watch*>(handle);
  std::lock_guard<std::mutex> hold(w->lock);
  auto known = w->wd_path.find(wd);
  if (known == w->wd_path.end()) return fail(lx::INVAL);
  auto at = w->path_wd.find(known->second);
  if (at != w->path_wd.end() && at->second == wd) w->path_wd.erase(at);
  w->wd_path.erase(known);
  w->wd_id.erase(wd);
  error_number = 0;
  return 0;
}
// Blocks until records are pending, a stop, a failure or the timeout.
// Returns the bytes of whole compact records written to [buffer] (the rest
// waits for the next call), -2 once stopped, or -1 with the error once a
// failed watch's last records were read. A sleep since the previous wait
// adds a record with wd -2.
// intptr_t, not long: the shared binding reads IntPtr, and Windows' long is
// 32 bits, so a -2 returned as long would reach Dart as 4294967294.
ANJ_API intptr_t anj_watch_wait(void* handle, uint8_t* buffer, intptr_t capacity, int timeout_ms) {
  auto* w = static_cast<Watch*>(handle);
  if (w->stopping) return -2;
  bool ready;
  { std::lock_guard<std::mutex> hold(w->lock); ready = !w->queue.pending.empty() || w->ended; }
  if (!ready) {
    DWORD r = WaitForSingleObject(w->wake, timeout_ms < 0 ? INFINITE : static_cast<DWORD>(timeout_ms));
    if (r == WAIT_FAILED) { error_number = from_win32(GetLastError()); return -1; }
  }
  if (w->stopping) return -2;
  std::vector<uint8_t> out;
  long long offset = sleep_offset(w);
  if (offset - w->offset > anj_watch::kSuspendNs) anj_watch::record(out, anj_watch::kSuspendRecord, 0, 0, "");
  w->offset = offset;
  std::lock_guard<std::mutex> hold(w->lock);
  ResetEvent(w->wake);
  auto& pending = w->queue.pending;
  size_t take = 0;
  while (take + 16 <= pending.size()) {
    uint32_t length;
    memcpy(&length, pending.data() + take + 12, 4);
    size_t size = 16 + length;
    if (static_cast<intptr_t>(out.size() + take + size) > capacity) break;
    take += size;
  }
  if (take == 0 && !pending.empty() && out.empty()) { error_number = lx::NOBUFS; return -1; }
  out.insert(out.end(), pending.begin(), pending.begin() + static_cast<std::ptrdiff_t>(take));
  pending.erase(pending.begin(), pending.begin() + static_cast<std::ptrdiff_t>(take));
  if (pending.empty()) w->queue.overflowed = false;
  else SetEvent(w->wake);
  if (out.empty() && w->ended) { error_number = w->end_errno; return -1; }
  if (w->ended) SetEvent(w->wake);  // the error follows the last records
  if (static_cast<intptr_t>(out.size()) > capacity) { error_number = lx::NOBUFS; return -1; }
  if (!out.empty()) memcpy(buffer, out.data(), out.size());
  error_number = 0;
  return static_cast<intptr_t>(out.size());
}
// Flow control: the worker counts processed batches; the watcher isolate
// compares with what it sent and coalesces while the worker is behind.
ANJ_API void anj_watch_ack(void* handle) { static_cast<Watch*>(handle)->acked++; }
ANJ_API long long anj_watch_acked(void* handle) { return static_cast<Watch*>(handle)->acked.load(); }
// Test seams (shared ABI). Inject the compact record (wd, mask) with no name
// (wd -1 with IN_Q_OVERFLOW, a root IN_MOVE_SELF, the synthetic records);
// shift the sleep clock; fail adds at or under a relative path with ENOSPC
// (null clears; empty fails every add, the root's watch included).
ANJ_API void anj_watch_debug_inject(void* handle, int wd, unsigned int mask) {
  auto* w = static_cast<Watch*>(handle);
  { std::lock_guard<std::mutex> hold(w->lock); anj_watch::record(w->queue.pending, wd, mask, 0, ""); }
  SetEvent(w->wake);
}
ANJ_API void anj_watch_debug_clock(void* handle, long long ns) {
  auto* w = static_cast<Watch*>(handle);
  { std::lock_guard<std::mutex> hold(w->lock); w->skew += ns; }
  SetEvent(w->wake);
}
ANJ_API void anj_watch_debug_fail_add(void* handle, const char* prefix) {
  auto* w = static_cast<Watch*>(handle);
  std::lock_guard<std::mutex> hold(w->lock);
  w->fail_set = prefix != nullptr;
  w->fail_prefix = prefix ? prefix : "";
}

ANJ_API int anj_open_read(int fd, const char* path) {
  Owned h;
  int e = open_beneath(handle_of(fd), path, kRead, kShareAll, Want::File, h);
  if (e) return fail(e);
  int out = put(h);
  return out < 0 ? fail(-out) : (error_number = 0, out);
}
ANJ_API int anj_open_directory(int fd, const char* path) {
  Owned h;
  int e = open_beneath(handle_of(fd), path, kList, kShareAll, Want::Directory, h);
  if (e) return fail(e);
  int out = put(h);
  return out < 0 ? fail(-out) : (error_number = 0, out);
}
ANJ_API intptr_t anj_read(int fd, void* buffer, intptr_t length) {
  HANDLE h = handle_of(fd);
  if (!h) { error_number = lx::BADF; return -1; }
  DWORD want = static_cast<DWORD>(length > (1 << 30) ? (1 << 30) : (length < 0 ? 0 : length));
  DWORD got = 0;
  if (!ReadFile(h, buffer, want, &got, nullptr)) {
    DWORD error = GetLastError();
    if (error == ERROR_HANDLE_EOF) { error_number = 0; return 0; }
    error_number = from_win32(error);
    return -1;
  }
  error_number = 0;
  return static_cast<intptr_t>(got);
}
ANJ_API int anj_rewind(int fd) {
  HANDLE h = handle_of(fd);
  if (!h) return fail(lx::BADF);
  LARGE_INTEGER zero = {};
  return done(SetFilePointerEx(h, zero, nullptr, FILE_BEGIN) ? 0 : from_win32(GetLastError()));
}
ANJ_API char* anj_stamp(int fd) {
  HANDLE h = handle_of(fd);
  if (!h) return fail_null(lx::BADF);
  Stat s;
  int e = stat_of(h, s);
  if (e) return fail_null(e);
  error_number = 0;
  return duplicate_string(stamp_of(s));
}
// {"identity": "<volume>:<file id>", "legacy": same, "stable": true}. The
// NTFS file id already carries the MFT sequence number, so a recreated root
// never repeats an identity and no birth time is appended (CreationTime is
// settable by applications). There is no earlier Windows form to migrate.
ANJ_API char* anj_root_info(int fd) {
  HANDLE h = handle_of(fd);
  if (!h) return fail_null(lx::BADF);
  Stat s;
  int e = stat_of(h, s);
  if (!e) e = check_volume(h);
  if (e) return fail_null(e);
  std::string identity = identity_of(s);
  error_number = 0;
  return duplicate_string("{\"identity\":" + quote(identity) + ",\"legacy\":" +
      quote(identity) + ",\"stable\":true}");
}
// Linux test seam (st_dev renumbering); Windows volume keys are serials.
ANJ_API void anj_debug_volume(long long, int, unsigned long long) {}
// The filesystem type as a statfs-style magic: "NTFS" (0x5346544E) or 0 for
// anything else. Neither is in RootTree.trustedFsMagic, so the stamp fast
// path stays off (decision #39's rule for unknown writeback).
ANJ_API long long anj_fs_magic(int fd, const char* path) {
  HANDLE root = handle_of(fd);
  if (!root) { error_number = lx::BADF; return -1; }
  Owned h;
  int e = (path && !*path) ? duplicate(root, h)
                           : open_beneath(root, path, kWalk, kShareAll, Want::Any, h);
  if (e) { error_number = e; return -1; }
  std::vector<unsigned char> buffer(512);
  IO_STATUS_BLOCK io = {};
  LONG status = nt().volume(h.h, &io, buffer.data(), static_cast<ULONG>(buffer.size()),
      kFsAttributeInformation);
  if (status < 0 && status != kStatusBufferOverflow) { error_number = from_status(status); return -1; }
  auto* attr = reinterpret_cast<FsAttribute*>(buffer.data());
  error_number = 0;
  return std::wstring(attr->name, attr->length / sizeof(WCHAR)) == L"NTFS" ? 0x5346544ELL : 0;
}

ANJ_API int anj_mkdir(int fd, const char* path) {
  Owned dir;
  std::wstring leaf;
  int e = open_parent(handle_of(fd), path, dir, leaf);
  if (e) return fail(e);
  Owned made;
  e = create_child(dir.h, leaf, FILE_LIST_DIRECTORY, kShareAll, true, made);
  if (e == lx::EXIST) {
    Owned existing;
    // An existing directory of exactly this name is success; a case or 8.3
    // alias of another name stays a collision.
    return done(open_leaf(dir.h, leaf, kWalk, kShareAll, Want::Directory, existing) ? lx::EXIST : 0);
  }
  if (!e) flush_committed(dir.h);
  return done(e);
}
ANJ_API int anj_mkdir_exclusive(int fd, const char* path) {
  Owned dir;
  std::wstring leaf;
  int e = open_parent(handle_of(fd), path, dir, leaf);
  if (e) return fail(e);
  Owned made;
  e = create_child(dir.h, leaf, FILE_LIST_DIRECTORY, kShareAll, true, made);
  if (!e) flush_committed(dir.h);
  return done(e);
}
// Publish a journaled, private empty directory without accepting an existing
// destination. An ambiguous previous publication remains pending for review.
ANJ_API int anj_install_directory(int fd, int stage, const char* staged,
    const char* path, const char* parent_identity, const char* identity) {
  HANDLE stage_h = handle_of(stage);
  if (!stage_h || !parent_identity || !identity) return fail(lx::BADF);
  std::wstring staged_name;
  if (single(staged, staged_name)) return fail(lx::STALE);
  Owned dir;
  std::wstring leaf;
  int e = open_parent(handle_of(fd), path, dir, leaf);
  if (e) return fail(e);
  Stat parent;
  if (stat_of(dir.h, parent) || identity_of(parent) != parent_identity) return fail(lx::STALE);
  Owned existing;
  e = open_leaf(dir.h, leaf, kWalk, kShareAll, Want::Any, existing);
  if (!e) return fail(lx::EXIST);
  if (e != lx::NOENT) return fail(e);
  Owned source;
  Stat s;
  e = open_leaf(stage_h, staged_name, kMove, kShareAll, Want::Directory, source, &s);
  if (e || identity_of(s) != identity) return fail(lx::STALE);
  if ((e = rename_into(source.h, dir.h, leaf))) return fail(e);
  source.reset();
  Owned published;
  Stat after;
  if (open_leaf(dir.h, leaf, kWalk, kShareAll, Want::Directory, published, &after) ||
      identity_of(after) != identity) return fail(lx::STALE);
  flush_committed(dir.h);
  flush_committed(stage_h);
  return done(e);
}
// Remove only an empty directory; newly added/unknown children refuse removal.
ANJ_API int anj_rmdir_empty(int fd, const char* path, const char* identity) {
  Owned dir;
  std::wstring leaf;
  int e = open_parent(handle_of(fd), path, dir, leaf);
  if (e) return fail(e);
  Owned target;
  Stat s;
  e = open_leaf(dir.h, leaf, kMove, kShareAll, Want::Directory, target, &s);
  if (e || !identity || identity_of(s) != identity) return fail(lx::STALE);
  if ((e = posix_delete(target.h))) return fail(e);
  target.reset();
  flush_committed(dir.h);
  return done(0);
}
// Link an already-complete staged file (absolute path) into an absent
// destination; never overwrite.
ANJ_API int anj_install(int fd, const char* relative, const char* staged) {
  Owned dir;
  std::wstring leaf;
  int e = open_parent(handle_of(fd), relative, dir, leaf);
  if (e) return fail(e);
  Owned source;
  if ((e = open_absolute(staged, FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES,
           kShareAll, Want::File, source))) return fail(e);
  if ((e = link_into(source.h, dir.h, leaf))) return fail(e);
  flush_committed(dir.h);
  return done(0);
}
// Move a root file to an absent staging path (absolute), preserving bytes.
ANJ_API int anj_quarantine(int fd, const char* relative, const char* destination) {
  Owned dir;
  std::wstring leaf;
  int e = open_parent(handle_of(fd), relative, dir, leaf);
  if (e) return fail(e);
  Owned source;
  if ((e = open_leaf(dir.h, leaf, kMove, kShareAll, Want::File, source))) return fail(e);
  if (!destination) return fail(lx::INVAL);
  std::string dest(destination);
  size_t slash = dest.find_last_of("\\/");
  if (slash == std::string::npos) return fail(lx::INVAL);
  std::wstring name;
  if ((e = single(dest.substr(slash + 1).c_str(), name))) return fail(e);
  Owned target;
  if ((e = open_absolute(dest.substr(0, slash).c_str(), kWalk, kShareAll,
           Want::Directory, target))) return fail(e);
  if ((e = rename_into(source.h, target.h, name))) return fail(e);
  flush_committed(dir.h);
  return done(0);
}
// Rename an item within the root to an absent name (decision #120's Rename
// action, #53's anj_rename_noreplace): through a handle on the source, with
// FileRenameInformation and no replace. The source must still be the item
// the caller saw (identity); an existing destination is never replaced. The
// source leaf may be a name the Win32 namespace cannot hold (one created by
// WSL or a \\?\ tool, scanned as unsupported), so it can be renamed to a
// portable one; the destination must be portable.
ANJ_API int anj_rename_noreplace(int fd, const char* from, const char* to,
    const char* identity) {
  HANDLE root = handle_of(fd);
  Owned from_dir, to_dir;
  std::wstring to_leaf;
  std::vector<std::wstring> from_parts;
  size_t non_portable = 0;
  int e = split(from, from_parts, true, &non_portable);
  if (!e && non_portable > (component_error(from_parts.back()) == kNonPortable ? 1u : 0u))
    e = lx::INVAL;
  if (!e) e = open_parent(root, from_parts, from_dir);
  if (!e) e = open_parent(root, to, to_dir, to_leaf);
  if (e) return fail(e);
  const std::wstring& from_leaf = from_parts.back();
  Owned source;
  Stat s;
  e = open_leaf(from_dir.h, from_leaf, kMove, kShareAll, Want::Any, source, &s);
  if (e || !identity || s.reparse() || identity_of(s) != identity) return fail(lx::STALE);
  if ((e = rename_into(source.h, to_dir.h, to_leaf))) return fail(e);
  source.reset();
  flush_committed(to_dir.h);
  flush_committed(from_dir.h);
  return done(e);
}
// Byte-range lock of the whole file, never waiting.
ANJ_API int anj_lock(int fd) {
  HANDLE h = handle_of(fd);
  if (!h) return fail(lx::BADF);
  OVERLAPPED o = {};
  return done(LockFileEx(h, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0,
      MAXDWORD, MAXDWORD, &o) ? 0 : from_win32(GetLastError()));
}
// Linux chmod 0700: a protected DACL granting full control to the user and
// SYSTEM only (inheritable to new children), set on the directory itself
// through a handle. Like chmod, it never touches existing children: their
// ACLs (and so their change times and stamps) stay as they are (review F4),
// and no child is opened. Already private: nothing is written.
ANJ_API int anj_chmod_private(const char* path) {
  Owned h;
  Stat s;
  int e = open_absolute(path, READ_CONTROL | WRITE_DAC | FILE_READ_ATTRIBUTES, kShareAll,
      Want::Any, h, &s);
  if (e) return fail(e);
  if (s.directory() && private_directory(h.h)) return done(0);
  BYTE flags = s.directory() ? OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE : 0;
  return done(apply_acl(h.h, flags, true));
}

// ---- release guard (spec #32 Cloud Release Guard) -------------------------

ANJ_API char* anj_info_at(int fd, const char* path) {
  Owned h;
  Stat s;
  int e = open_beneath(handle_of(fd), path, kAttributes, kShareAll, Want::File, h, &s);
  if (e) return fail_null(e == lx::LOOP ? lx::INVAL : e);
  error_number = 0;
  return duplicate_string(info_json(h.h, s));
}
ANJ_API char* anj_info_fd(int fd) {
  HANDLE h = handle_of(fd);
  if (!h) return fail_null(lx::BADF);
  Stat s;
  int e = stat_of(h, s);
  if (e) return fail_null(e);
  error_number = 0;
  return duplicate_string(info_json(h, s));
}
ANJ_API char* anj_preview_editor(int directory, const char* name) {
  HANDLE dir = handle_of(directory);
  std::wstring leaf;
  if (!dir || !private_directory(dir) || single(name, leaf)) return fail_null(lx::INVAL);
  Owned h;
  Stat s;
  int e = open_leaf(dir, leaf, kAttributes, kShareAll, Want::File, h, &s);
  if (e) return fail_null(e);
  if (!owned_by_user(h.h) || s.links != 1) return fail_null(lx::PERM);
  error_number = 0;
  return duplicate_string(info_json(h.h, s));
}
ANJ_API int anj_create_owned(int directory, const char* name) {
  HANDLE dir = handle_of(directory);
  std::wstring leaf;
  if (!dir || !private_directory(dir) || single(name, leaf)) return fail(lx::INVAL);
  Owned h;
  int e = create_child(dir, leaf, GENERIC_READ | GENERIC_WRITE | READ_CONTROL,
      kShareAll, false, h);
  if (!e) e = flush_file(h.h);
  if (!e) e = flush_dir(dir);
  if (e) return fail(e);
  int out = put(h);
  return out < 0 ? fail(-out) : (error_number = 0, out);
}
ANJ_API int anj_sync_dir(int fd) {
  HANDLE h = handle_of(fd);
  return h ? done(flush_dir(h)) : fail(lx::BADF);
}
ANJ_API int anj_install_owned(int fd, const char* path, int directory, const char* name) {
  HANDLE dir = handle_of(directory);
  std::wstring staged;
  if (!dir || !private_directory(dir) || single(name, staged)) return fail(lx::INVAL);
  Owned source;
  int e = open_leaf(dir, staged, FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES,
      kShareAll, Want::File, source);
  if (e) return fail(lx::INVAL);
  Owned target;
  std::wstring leaf;
  if ((e = open_parent(handle_of(fd), path, target, leaf))) return fail(e);
  if ((e = link_into(source.h, target.h, leaf))) return fail(e);
  flush_committed(target.h);
  return done(0);
}
// Recover (spec #25): moves a complete, flushed staging file into the root
// under its final name, never replacing (EEXIST); both directories flushed.
ANJ_API int anj_restore_owned(int fd, const char* path, int directory, const char* name) {
  HANDLE dir = handle_of(directory);
  std::wstring staged;
  if (!dir || !private_directory(dir) || single(name, staged)) return fail(lx::INVAL);
  Owned source;
  int e = open_leaf(dir, staged, kMove, kShareAll, Want::File, source);
  if (e) return fail(lx::INVAL);
  Owned target;
  std::wstring leaf;
  if ((e = open_parent(handle_of(fd), path, target, leaf))) return fail(e);
  if ((e = rename_into(source.h, target.h, leaf))) return fail(e);
  source.reset();
  flush_committed(target.h);
  flush_committed(dir);
  return done(e);
}
ANJ_API int anj_preserve_owned(int fd, const char* path, int directory, const char* name) {
  HANDLE dir = handle_of(directory);
  std::wstring staged;
  if (!dir || !private_directory(dir) || single(name, staged)) return fail(lx::INVAL);
  Owned parent;
  std::wstring leaf;
  int e = open_parent(handle_of(fd), path, parent, leaf);
  if (e) return fail(e);
  Owned source;
  if ((e = open_leaf(parent.h, leaf, kMove, kShareAll, Want::File, source)))
    return fail(e == lx::LOOP ? lx::INVAL : e);
  if ((e = rename_into(source.h, dir, staged))) return fail(e);
  source.reset();
  flush_committed(parent.h);
  flush_committed(dir);
  return done(e);
}
// The exclusive-open guard (spec #32 Cloud Release Guard, decisions #125,
// #126, #128). The file is opened for reading and delete. A single-link file
// is opened with share mode 0: while any other handle with data or delete
// access is open (any process), the open fails with a sharing violation
// (EBUSY), and while it is held every such open fails, a FILE_SUPERSEDE
// included. A file with more than one link shares delete only, so the
// release can unlink each name through its own handle; a delete-only opener
// could then supersede or rename it, which the stamp re-check catches.
// Either way the guard records the stamp and link count and re-checks them
// on the held handle before every act (guard_check). Attribute-only handles
// cannot read bytes and are not seen. A writable mapping keeps the file busy
// after its handles close; a read-only mapping does not, and cannot change
// the bytes (review F10).
ANJ_API int anj_guard_open(int directory, const char* path, const char* expected, int links) {
  if (links < 1) return fail(lx::INVAL);
  Owned h;
  Stat s;
  int e = open_beneath(handle_of(directory), path, kRead | DELETE,
      links > 1 ? FILE_SHARE_DELETE : 0, Want::File, h, &s);
  if (e) return fail(e);
  if (!expected || stamp_of(s) != expected || s.links != static_cast<ULONG>(links))
    return fail(lx::STALE);
  Entry entry;
  entry.guard = true;
  entry.deadline = GetTickCount64() + 30000;  // kept for parity with Linux
  entry.volume = s.volume;
  entry.id = s.id;
  entry.size = s.size;
  entry.write = s.write;
  entry.change = s.change;
  entry.links = s.links;
  entry.shares_delete = links > 1;
  int fd = put(h, entry);
  return fd < 0 ? fail(-fd) : (error_number = 0, fd);
}
ANJ_API int anj_guard_valid(int fd) {
  Entry e;
  return done(guard_check(fd, e));
}
ANJ_API int anj_guard_close(int fd) {
  HANDLE h = nullptr;
  {
    std::lock_guard<std::mutex> lock(table_mutex);
    auto found = table.find(fd);
    if (found == table.end() || !found->second.guard) return fail(lx::INVAL);
    h = found->second.h;
    table.erase(found);
  }
  if (h) CloseHandle(h);
  return done(0);
}
ANJ_API int anj_guard_quarantine(int guard, int fd, const char* path, int directory,
    const char* name) {
  Entry g;
  int e = guard_check(guard, g);
  if (e) return fail(e);
  HANDLE dir = handle_of(directory);
  std::wstring staged;
  if (!dir || !private_directory(dir) || single(name, staged)) return fail(lx::INVAL);
  Owned parent;
  std::wstring leaf;
  if ((e = open_parent(handle_of(fd), path, parent, leaf))) return fail(e);
  Owned named;
  if ((e = open_guarded(g, parent.h, leaf, named))) return fail(e);
  // Re-checked just before the act, on the held handle.
  if ((e = guard_check(guard, g))) return fail(e);
  if ((e = rename_into(g.shares_delete ? named.h : g.h, dir, staged))) return fail(e);
  named.reset();
  if ((e = guard_refresh(guard, g.links))) return fail(e);
  flush_committed(parent.h);
  flush_committed(dir);
  Owned moved;
  if ((e = guard_check(guard, g))) return fail(e);
  return done(open_guarded(g, dir, staged, moved));
}
// Unlinks [name] (the guarded file) from staging. With one link the delete
// goes through the guard's own handle, which is then closed so the name is
// gone at return, as Linux unlinkat; the guard number stays valid only for
// anj_guard_close. With more links, each name is deleted through its own
// handle and the guard's recorded link count drops by one (also for the
// last name: the guard's own handle may be on a name already unlinked).
ANJ_API int anj_guard_unlink(int guard, int directory, const char* name) {
  Entry g;
  int e = guard_check(guard, g);
  if (e) return fail(e);
  HANDLE dir = handle_of(directory);
  std::wstring staged;
  if (!dir || !private_directory(dir) || single(name, staged)) return fail(lx::INVAL);
  Owned target;
  if ((e = open_guarded(g, dir, staged, target))) return fail(e);
  if ((e = guard_check(guard, g))) return fail(e);
  if (g.shares_delete) {
    if ((e = posix_delete(target.h))) return fail(e);
    target.reset();
    if (g.links > 1) {
      if ((e = guard_refresh(guard, g.links - 1))) return fail(e);
    } else {
      // The last name is gone; the bytes go when anj_guard_close closes.
      std::lock_guard<std::mutex> lock(table_mutex);
      auto found = table.find(guard);
      if (found != table.end()) found->second.unlinked = true;
    }
  } else {
    target.reset();
    if ((e = posix_delete(g.h))) return fail(e);
    HANDLE h = nullptr;
    {
      std::lock_guard<std::mutex> lock(table_mutex);
      auto found = table.find(guard);
      if (found != table.end()) {
        h = found->second.h;
        found->second.h = nullptr;
        found->second.unlinked = true;
      }
    }
    if (h) CloseHandle(h);
  }
  flush_committed(dir);
  return done(0);
}

// ---- Windows test seams (W2 evidence) -------------------------------------
// Built only with -DANJ_TEST_SEAMS (tool/windows/native_test.ps1), as the
// posix test seams: the shipped DLL exports exactly native/posix/exports.txt.
#ifdef ANJ_TEST_SEAMS

// NTSTATUS of the most recent directory flush, and how many directory
// flushes NTFS refused since load.
ANJ_API long anj_win_last_dir_flush() { return last_dir_flush.load(); }
ANJ_API long anj_win_dir_flush_refused() { return dir_flush_refused.load(); }
// Directory flushes that failed after a committed change (counted, not
// reported as the change failing).
ANJ_API long anj_win_flush_failures() { return committed_flush_failures.load(); }
// Open table entries (leak checks).
ANJ_API int anj_win_open_count() {
  std::lock_guard<std::mutex> lock(table_mutex);
  return static_cast<int>(table.size());
}
// Test seam: shortens a guard's deadline to [ms] from now.
ANJ_API int anj_win_debug_guard_deadline(int fd, int ms) {
  std::lock_guard<std::mutex> lock(table_mutex);
  auto found = table.find(fd);
  if (found == table.end() || !found->second.guard) return -1;
  found->second.deadline = GetTickCount64() + static_cast<ULONGLONG>(ms < 0 ? 0 : ms);
  return 0;
}
// Watch test seams: the read buffer of a watch not started yet (a tiny one
// overflows at once), and closing the watch handle under the thread (a
// watch handle that fails).
ANJ_API int anj_win_watch_debug_buffer(void* handle, unsigned int bytes) {
  auto* w = static_cast<Watch*>(handle);
  if (w->thread || bytes < 16) return -1;
  w->buffer_bytes = bytes;
  return 0;
}
ANJ_API int anj_win_watch_debug_cancel(void* handle) {
  auto* w = static_cast<Watch*>(handle);
  return w->dir && CancelIoEx(w->dir, nullptr) ? 0 : -1;
}
#endif  // ANJ_TEST_SEAMS
