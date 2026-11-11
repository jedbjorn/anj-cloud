// Native tests of anj_rootfs.dll on the Windows seat (spec #32 W2, Acceptance
// rows 4, 5, 6 and the durability record for row 7). Built and run by
// tool/windows/native_test.ps1.
//
//   rootfs_win_test fixture <dir>        elevated: symlinks and an explicit
//                                        8.3 name under <dir>\links
//   rootfs_win_test run <dir> <dll>      unelevated (console session): every
//                                        test; work files under <dir>\run-<pid>
//   rootfs_win_test hold <path> <event>  helper: hold a full-sharing read handle
//   rootfs_win_test probe <path>         helper: exit with the open's error
//   rootfs_win_test clean <dir>          delete a tree, removing links as links
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <winioctl.h>
#include <winternl.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

struct Api {
  HMODULE dll = nullptr;
  int (*error)();
  void (*free_)(void*);
  int (*open_root)(const char*);
  int (*check_root)(int, const char*);
  int (*close)(int);
  char* (*scan)(int);
  char* (*watch_scan)(void*, int, const char*, int);
  int (*open_read)(int, const char*);
  int (*open_directory)(int, const char*);
  intptr_t (*read)(int, void*, intptr_t);
  int (*rewind)(int);
  char* (*stamp)(int);
  char* (*root_info)(int);
  long long (*fs_magic)(int, const char*);
  int (*mkdir)(int, const char*);
  int (*mkdir_exclusive)(int, const char*);
  int (*create_file)(int, const char*);
  int (*install_directory)(int, int, const char*, const char*, const char*, const char*);
  int (*rmdir_empty)(int, const char*, const char*);
  int (*install)(int, const char*, const char*);
  int (*quarantine)(int, const char*, const char*);
  int (*rename_noreplace)(int, const char*, const char*, const char*);
  int (*chmod_private)(const char*);
  char* (*info_at)(int, const char*);
  char* (*info_fd)(int);
  char* (*preview_editor)(int, const char*);
  int (*create_owned)(int, const char*);
  int (*install_owned)(int, const char*, int, const char*);
  int (*restore_owned)(int, const char*, int, const char*);
  int (*preserve_owned)(int, const char*, int, const char*);
  int (*guard_open)(int, const char*, const char*, int);
  int (*guard_valid)(int);
  int (*guard_close)(int);
  int (*guard_quarantine)(int, int, const char*, int, const char*);
  int (*guard_unlink)(int, int, const char*);
  long (*last_dir_flush)();
  long (*dir_flush_refused)();
  int (*open_count)();
  int (*debug_deadline)(int, int);
  const char* (*error_name)(int);
  const char* (*guard_kind)();
  char* (*stage_path)(int);
  int (*profile_lock)(const char*, int);
  void* (*watch_open)();
  void (*watch_release)(void*);
  void (*watch_stop)(void*);
  int (*watch_add)(void*, int, const char*, long long*, char*, int);
  int (*watch_remove)(void*, int);
  intptr_t (*watch_wait)(void*, uint8_t*, intptr_t, int);
  void (*watch_clock)(void*, long long);
  void (*watch_fail)(void*, const char*);
  int (*watch_buffer)(void*, unsigned int);
  int (*watch_cancel)(void*);
  int (*locate_identity)(int, int, const char*, char*, int, long long*);
  void (*debug_locate_race)(int);
};
Api api;
bool load(const char* path) {
  api.dll = LoadLibraryA(path);
  if (!api.dll) return false;
  bool ok = true;
  auto get = [&](auto& slot, const char* name) {
    slot = reinterpret_cast<std::remove_reference_t<decltype(slot)>>(
        reinterpret_cast<void*>(GetProcAddress(api.dll, name)));
    if (!slot) { printf("MISSING export %s\n", name); ok = false; }
  };
  get(api.error, "anj_error"); get(api.free_, "anj_free");
  get(api.open_root, "anj_open_root"); get(api.check_root, "anj_check_root");
  get(api.close, "anj_close"); get(api.scan, "anj_scan");
  get(api.watch_scan, "anj_watch_scan"); get(api.open_read, "anj_open_read");
  get(api.open_directory, "anj_open_directory"); get(api.read, "anj_read");
  get(api.rewind, "anj_rewind"); get(api.stamp, "anj_stamp");
  get(api.root_info, "anj_root_info"); get(api.fs_magic, "anj_fs_magic");
  get(api.mkdir, "anj_mkdir"); get(api.mkdir_exclusive, "anj_mkdir_exclusive");
  get(api.create_file, "anj_create_file");
  get(api.install_directory, "anj_install_directory");
  get(api.rmdir_empty, "anj_rmdir_empty"); get(api.install, "anj_install");
  get(api.quarantine, "anj_quarantine");
  get(api.rename_noreplace, "anj_rename_noreplace");
  get(api.chmod_private, "anj_chmod_private"); get(api.info_at, "anj_info_at");
  get(api.info_fd, "anj_info_fd"); get(api.preview_editor, "anj_preview_editor");
  get(api.create_owned, "anj_create_owned");
  get(api.install_owned, "anj_install_owned");
  get(api.restore_owned, "anj_restore_owned");
  get(api.preserve_owned, "anj_preserve_owned");
  get(api.guard_open, "anj_guard_open"); get(api.guard_valid, "anj_guard_valid");
  get(api.guard_close, "anj_guard_close");
  get(api.guard_quarantine, "anj_guard_quarantine");
  get(api.guard_unlink, "anj_guard_unlink");
  get(api.last_dir_flush, "anj_win_last_dir_flush");
  get(api.dir_flush_refused, "anj_win_dir_flush_refused");
  get(api.open_count, "anj_win_open_count");
  get(api.debug_deadline, "anj_win_debug_guard_deadline");
  get(api.error_name, "anj_error_name"); get(api.guard_kind, "anj_guard_kind");
  get(api.stage_path, "anj_stage_path"); get(api.profile_lock, "anj_profile_lock");
  get(api.watch_open, "anj_watch_open");
  get(api.watch_release, "anj_watch_release"); get(api.watch_stop, "anj_watch_stop");
  get(api.watch_add, "anj_watch_add"); get(api.watch_remove, "anj_watch_remove");
  get(api.watch_wait, "anj_watch_wait"); get(api.watch_clock, "anj_watch_debug_clock");
  get(api.watch_fail, "anj_watch_debug_fail_add");
  get(api.watch_buffer, "anj_win_watch_debug_buffer");
  get(api.watch_cancel, "anj_win_watch_debug_cancel");
  get(api.locate_identity, "anj_locate_identity");
  get(api.debug_locate_race, "anj_win_debug_locate_race");
  return ok;
}

int passed = 0, failed = 0, skipped = 0;
void check(const std::string& name, bool ok, const std::string& detail = "") {
  if (ok) passed++; else failed++;
  printf("%s %s%s%s\n", ok ? "PASS" : "FAIL", name.c_str(),
      detail.empty() ? "" : " -- ", detail.c_str());
  fflush(stdout);
}
void skip(const std::string& name, const std::string& why) {
  skipped++;
  printf("SKIP %s -- %s\n", name.c_str(), why.c_str());
  fflush(stdout);
}
// The call failed with Linux errno [want].
// The errno of the most recent refused() check, for the report line.
int last_errno = 0;
bool refused(int result, int want) {
  last_errno = result < 0 ? api.error() : 0;
  return result < 0 && last_errno == want;
}
std::string got(int) { return "errno " + std::to_string(last_errno) + " now " + std::to_string(api.error()); }
std::string take(char* value) {
  if (!value) return std::string();
  std::string s(value);
  api.free_(value);
  return s;
}
std::string field(const std::string& json, const std::string& key) {
  std::string tag = "\"" + key + "\":";
  size_t at = json.find(tag);
  if (at == std::string::npos) return std::string();
  at += tag.size();
  if (json[at] == '"') {
    size_t end = json.find('"', at + 1);
    return json.substr(at + 1, end - at - 1);
  }
  size_t end = json.find_first_of(",}", at);
  return json.substr(at, end - at);
}
std::string identity_of_fd(int fd) {
  std::string stamp = take(api.stamp(fd));
  size_t first = stamp.find(':');
  size_t second = stamp.find(':', first + 1);
  return stamp.substr(0, second);
}

std::wstring wide(const std::string& s) {
  int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
  std::wstring out(n ? n - 1 : 0, L'\0');
  if (n > 1) MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, &out[0], n);
  return out;
}
std::string narrow(const std::wstring& s) {
  int n = WideCharToMultiByte(CP_UTF8, 0, s.c_str(), -1, nullptr, 0, nullptr, nullptr);
  std::string out(n ? n - 1 : 0, '\0');
  if (n > 1) WideCharToMultiByte(CP_UTF8, 0, s.c_str(), -1, &out[0], n, nullptr, nullptr);
  return out;
}
std::wstring longpath(const std::string& s) { return L"\\\\?\\" + wide(s); }
bool write_file(const std::string& path, const std::string& content) {
  HANDLE h = CreateFileW(longpath(path).c_str(), GENERIC_WRITE, 0, nullptr,
      CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (h == INVALID_HANDLE_VALUE) return false;
  DWORD n = 0;
  bool ok = WriteFile(h, content.data(), static_cast<DWORD>(content.size()), &n, nullptr) &&
      FlushFileBuffers(h);
  CloseHandle(h);
  return ok;
}
// As Dart opens it: a plain Win32 path, '/' accepted (no \\?\ prefix).
bool write_plain(const std::string& path, const std::string& content) {
  HANDLE h = CreateFileW(wide(path).c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
      FILE_ATTRIBUTE_NORMAL, nullptr);
  if (h == INVALID_HANDLE_VALUE) return false;
  DWORD n = 0;
  bool ok = WriteFile(h, content.data(), static_cast<DWORD>(content.size()), &n, nullptr) != 0;
  CloseHandle(h);
  return ok;
}
std::string read_file(const std::string& path) {
  HANDLE h = CreateFileW(longpath(path).c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (h == INVALID_HANDLE_VALUE) return "<unreadable " + std::to_string(GetLastError()) + ">";
  char buffer[4096];
  DWORD n = 0;
  std::string out;
  while (ReadFile(h, buffer, sizeof(buffer), &n, nullptr) && n) out.append(buffer, n);
  CloseHandle(h);
  return out;
}
bool exists(const std::string& path) {
  return GetFileAttributesW(longpath(path).c_str()) != INVALID_FILE_ATTRIBUTES;
}
bool make_dir(const std::string& path) {
  return CreateDirectoryW(longpath(path).c_str(), nullptr) ||
      GetLastError() == ERROR_ALREADY_EXISTS;
}
std::string read_fd(int fd) {
  std::string out;
  char buffer[4096];
  while (true) {
    intptr_t n = api.read(fd, buffer, sizeof(buffer));
    if (n <= 0) break;
    out.append(buffer, static_cast<size_t>(n));
  }
  return out;
}
// Deletes a tree without following reparse points (a link is removed, never
// its target).
void delete_tree(const std::wstring& path) {
  DWORD attributes = GetFileAttributesW(path.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES) return;
  if ((attributes & FILE_ATTRIBUTE_DIRECTORY) && !(attributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
    WIN32_FIND_DATAW data;
    HANDLE find = FindFirstFileW((path + L"\\*").c_str(), &data);
    if (find != INVALID_HANDLE_VALUE) {
      do {
        std::wstring name = data.cFileName;
        if (name != L"." && name != L"..") delete_tree(path + L"\\" + name);
      } while (FindNextFileW(find, &data));
      FindClose(find);
    }
  }
  if (!(attributes & FILE_ATTRIBUTE_REPARSE_POINT))
    SetFileAttributesW(path.c_str(), FILE_ATTRIBUTE_NORMAL);
  if (attributes & FILE_ATTRIBUTE_DIRECTORY) RemoveDirectoryW(path.c_str());
  else DeleteFileW(path.c_str());
}

// A junction (mount point reparse point), which an unelevated user may set.
struct MountPointBuffer {
  DWORD tag;
  WORD length;
  WORD reserved;
  WORD substitute_offset, substitute_length, print_offset, print_length;
  WCHAR path[1];
};
bool make_junction(const std::string& link, const std::wstring& nt_target,
    const std::wstring& print) {
  if (!make_dir(link)) return false;
  HANDLE h = CreateFileW(longpath(link).c_str(), GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (h == INVALID_HANDLE_VALUE) return false;
  std::vector<unsigned char> buffer(16 * 1024, 0);
  auto* m = reinterpret_cast<MountPointBuffer*>(buffer.data());
  m->tag = IO_REPARSE_TAG_MOUNT_POINT;
  m->substitute_offset = 0;
  m->substitute_length = static_cast<WORD>(nt_target.size() * sizeof(WCHAR));
  m->print_offset = static_cast<WORD>(m->substitute_length + sizeof(WCHAR));
  m->print_length = static_cast<WORD>(print.size() * sizeof(WCHAR));
  memcpy(m->path, nt_target.c_str(), m->substitute_length);
  memcpy(reinterpret_cast<unsigned char*>(m->path) + m->print_offset, print.c_str(),
      m->print_length);
  // Header (tag, length, reserved) is 8 bytes; the four offsets 8 more.
  DWORD data = 16 + m->print_offset + m->print_length + sizeof(WCHAR);
  m->length = static_cast<WORD>(data - 8);
  DWORD n = 0;
  bool ok = DeviceIoControl(h, FSCTL_SET_REPARSE_POINT, m, data, nullptr, 0, &n, nullptr);
  CloseHandle(h);
  return ok;
}

std::string self_path() {
  wchar_t buffer[MAX_PATH * 4];
  DWORD n = GetModuleFileNameW(nullptr, buffer, MAX_PATH * 4);
  return narrow(std::wstring(buffer, n));
}
PROCESS_INFORMATION spawn(const std::wstring& command) {
  STARTUPINFOW si = {};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi = {};
  std::wstring line = command;
  if (!CreateProcessW(nullptr, &line[0], nullptr, nullptr, FALSE, 0, nullptr, nullptr, &si, &pi))
    pi.hProcess = nullptr;
  return pi;
}
void end(PROCESS_INFORMATION& pi) {
  if (!pi.hProcess) return;
  TerminateProcess(pi.hProcess, 0);
  WaitForSingleObject(pi.hProcess, 5000);
  CloseHandle(pi.hProcess);
  CloseHandle(pi.hThread);
  pi.hProcess = nullptr;
}
// Exit code of a helper that tries a full-sharing read open of [path].
DWORD probe(const std::string& path) {
  PROCESS_INFORMATION pi = spawn(L"\"" + wide(self_path()) + L"\" probe \"" + wide(path) + L"\"");
  if (!pi.hProcess) return 0xFFFFFFFF;
  WaitForSingleObject(pi.hProcess, 10000);
  DWORD code = 0xFFFFFFFF;
  GetExitCodeProcess(pi.hProcess, &code);
  CloseHandle(pi.hProcess);
  CloseHandle(pi.hThread);
  return code;
}

bool enable_privilege(const wchar_t* name) {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &token))
    return false;
  TOKEN_PRIVILEGES tp = {};
  tp.PrivilegeCount = 1;
  tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
  bool ok = LookupPrivilegeValueW(nullptr, name, &tp.Privileges[0].Luid) &&
      AdjustTokenPrivileges(token, FALSE, &tp, sizeof(tp), nullptr, nullptr) &&
      GetLastError() == ERROR_SUCCESS;
  CloseHandle(token);
  return ok;
}

// Elevated fixture: what an unelevated user cannot make.
int fixture(const std::string& dir) {
  std::string links = dir + "\\links", outside = dir + "\\outside";
  delete_tree(longpath(links));
  make_dir(dir); make_dir(links); make_dir(outside); make_dir(links + "\\real");
  write_file(outside + "\\secret.txt", "SECRET");
  write_file(links + "\\real\\inner.txt", "INNER");
  write_file(links + "\\LongFileName.txt", "LONG");
  int bad = 0;
  if (!CreateSymbolicLinkW(wide(links + "\\sdir").c_str(), wide(outside).c_str(),
          SYMBOLIC_LINK_FLAG_DIRECTORY)) { printf("dir symlink failed %lu\n", static_cast<unsigned long>(GetLastError())); bad++; }
  if (!CreateSymbolicLinkW(wide(links + "\\sfile").c_str(),
          wide(outside + "\\secret.txt").c_str(), 0)) { printf("file symlink failed %lu\n", static_cast<unsigned long>(GetLastError())); bad++; }
  bool restore = enable_privilege(L"SeRestorePrivilege");
  HANDLE h = CreateFileW(wide(links + "\\LongFileName.txt").c_str(), GENERIC_ALL, 0, nullptr,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
  if (h == INVALID_HANDLE_VALUE || !SetFileShortNameW(h, L"LFN~1.TXT")) {
    printf("short name failed %lu (restore privilege %d)\n", static_cast<unsigned long>(GetLastError()), restore ? 1 : 0);
    bad++;
  }
  if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
  printf("fixture %s: %d problems\n", links.c_str(), bad);
  return bad;
}

std::vector<std::string> names_in(const std::string& json) {
  std::vector<std::string> out;
  size_t at = 0;
  while ((at = json.find("\"path\":\"", at)) != std::string::npos) {
    at += 8;
    size_t end = json.find('"', at);
    out.push_back(json.substr(at, end - at));
  }
  return out;
}
bool listed(const std::string& json, const std::string& path, const std::string& kind) {
  std::string tag = "{\"path\":\"" + path + "\",\"kind\":\"" + kind + "\"";
  return json.find(tag) != std::string::npos;
}

long long take_id(int fd, const char* path) {
  std::string identity = field(take(api.info_at(fd, path)), "identity");
  size_t colon = identity.find(':');
  return colon == std::string::npos ? 0 : _atoi64(identity.c_str() + colon + 1);
}
// Whether the file with this NTFS id exists on the volume holding [dir].
bool by_id(const std::string& dir, long long id) {
  HANDLE volume = CreateFileW(longpath(dir).c_str(), FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS, nullptr);
  if (volume == INVALID_HANDLE_VALUE) return false;
  FILE_ID_DESCRIPTOR d = {};
  d.dwSize = sizeof(d);
  d.Type = FileIdType;
  d.FileId.QuadPart = id;
  HANDLE h = OpenFileById(volume, &d, FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, 0);
  CloseHandle(volume);
  if (h == INVALID_HANDLE_VALUE) return false;
  CloseHandle(h);
  return true;
}

// FILE_SUPERSEDE with DELETE access only, through NtCreateFile (Win32
// CreateFile never supersedes): the reviewer's F1 probe. Returns NTSTATUS.
LONG supersede(const std::string& path) {
  using Fn = LONG(NTAPI*)(PHANDLE, ACCESS_MASK, POBJECT_ATTRIBUTES, PIO_STATUS_BLOCK,
      PLARGE_INTEGER, ULONG, ULONG, ULONG, ULONG, PVOID, ULONG);
  auto create = reinterpret_cast<Fn>(reinterpret_cast<void*>(
      GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtCreateFile")));
  std::wstring name = L"\\??\\" + wide(path);
  UNICODE_STRING us;
  us.Buffer = &name[0];
  us.Length = static_cast<USHORT>(name.size() * sizeof(WCHAR));
  us.MaximumLength = us.Length;
  OBJECT_ATTRIBUTES oa;
  InitializeObjectAttributes(&oa, &us, OBJ_CASE_INSENSITIVE, nullptr, nullptr);
  IO_STATUS_BLOCK io = {};
  HANDLE h = nullptr;
  LONG status = create(&h, DELETE | SYNCHRONIZE, &oa, &io, nullptr, FILE_ATTRIBUTE_NORMAL,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, 0 /* FILE_SUPERSEDE */,
      0x20 | 0x40 /* synchronous, non-directory */, nullptr, 0);
  if (status >= 0) CloseHandle(h);
  return status;
}
std::string hex(LONG status) {
  char buffer[16];
  snprintf(buffer, sizeof(buffer), "0x%08lx", static_cast<unsigned long>(status));
  return buffer;
}

// ---- spec #32 File Watching (Acceptance row 9): the ReadDirectoryChangesW watcher ----
struct WatchRecord { int wd; uint32_t mask; uint32_t cookie; std::string name; };
constexpr uint32_t kCreate = 0x100, kDelete = 0x200, kModify = 0x2, kMovedFrom = 0x40,
    kMovedTo = 0x80, kMoveSelf = 0x800, kOverflow = 0x4000, kIsDir = 0x40000000;
// Reads records until [until] holds of everything read or [ms] passed.
// Returns the last wait's result (bytes, -1 or -2).
template <typename Until>
intptr_t watch_collect(void* w, std::vector<WatchRecord>& out, int ms, Until until) {
  std::vector<uint8_t> buffer(80 * 1024);
  ULONGLONG deadline = GetTickCount64() + static_cast<ULONGLONG>(ms);
  intptr_t n = 0;
  while (!until(out)) {
    ULONGLONG now = GetTickCount64();
    if (now >= deadline) break;
    n = api.watch_wait(w, buffer.data(), static_cast<intptr_t>(buffer.size()),
        static_cast<int>(deadline - now));
    if (n < 0) break;
    for (intptr_t at = 0; at + 16 <= n;) {
      WatchRecord r;
      uint32_t length;
      memcpy(&r.wd, buffer.data() + at, 4);
      memcpy(&r.mask, buffer.data() + at + 4, 4);
      memcpy(&r.cookie, buffer.data() + at + 8, 4);
      memcpy(&length, buffer.data() + at + 12, 4);
      r.name.assign(reinterpret_cast<char*>(buffer.data() + at + 16), length);
      out.push_back(r);
      at += 16 + static_cast<intptr_t>(length);
    }
  }
  return n;
}
bool has(const std::vector<WatchRecord>& rs, int wd, uint32_t mask, const std::string& name) {
  for (const auto& r : rs) if (r.wd == wd && (r.mask & mask) == mask && r.name == name) return true;
  return false;
}
bool any_mask(const std::vector<WatchRecord>& rs, uint32_t mask) {
  for (const auto& r : rs) if (r.mask & mask) return true;
  return false;
}
std::string describe(const std::vector<WatchRecord>& rs) {
  std::string out;
  for (size_t i = 0; i < rs.size() && i < 12; i++) {
    char head[48];
    snprintf(head, sizeof(head), "(%d,0x%x,%u,", rs[i].wd, rs[i].mask, rs[i].cookie);
    out += head + rs[i].name + ")";
  }
  return out + (rs.size() > 12 ? " +" + std::to_string(rs.size() - 12) : "");
}
int watch_add(void* w, int fd, const char* path) {
  long long identity[2] = {0, 0};
  char volume[64] = {};
  return api.watch_add(w, fd, path, identity, volume, sizeof(volume));
}

void watch_tests(const std::string& root, const std::string& stage, int rootfd) {
  {
    void* w = api.watch_open();
    check("watch_open", w != nullptr, got(-1));
    if (!w) return;
    make_dir(root + "\\wsub");
    check("watch_add beneath before the root is ENOTCONN", refused(watch_add(w, rootfd, "wsub"), 107),
        got(-1));
    api.watch_fail(w, "");
    check("a failing root add is ENOSPC (test seam)", refused(watch_add(w, rootfd, ""), 28), got(-1));
    api.watch_fail(w, nullptr);
    int wd = watch_add(w, rootfd, "");
    check("watch_add of the root starts the watch", wd >= 1, got(wd));
    check("re-adding the root returns its descriptor", watch_add(w, rootfd, "") == wd);
    int sub = watch_add(w, rootfd, "wsub");
    check("a directory beneath is bookkeeping", sub > wd, got(sub));
    check("watch_add of a missing directory is ENOENT", refused(watch_add(w, rootfd, "nope"), 2),
        got(-1));
    check("watch_remove", api.watch_remove(w, sub) == 0 && refused(api.watch_remove(w, sub), 22),
        got(-1));
    std::string blob = take(api.watch_scan(w, rootfd, "", 1));
    check("watch_scan with the watcher reports no watches",
        blob.find("\"watches\":[]") != std::string::npos, blob.substr(0, 200));

    std::vector<WatchRecord> rs;
    write_file(root + "\\w-a.txt", "A");
    watch_collect(w, rs, 5000, [&](auto& r) { return has(r, wd, kCreate, "w-a.txt"); });
    check("create is IN_CREATE on the root with the name", has(rs, wd, kCreate, "w-a.txt"), describe(rs));
    rs.clear();
    write_file(root + "\\wsub\\deep.txt", "D");
    watch_collect(w, rs, 5000, [&](auto& r) { return has(r, wd, kCreate, "wsub/deep.txt"); });
    check("a nested change names its root-relative path",
        has(rs, wd, kCreate, "wsub/deep.txt") && !has(rs, wd, kModify, "wsub"), describe(rs));
    rs.clear();
    {
      HANDLE h = CreateFileW(longpath(root + "\\w-a.txt").c_str(), FILE_APPEND_DATA, 0, nullptr,
          OPEN_EXISTING, 0, nullptr);
      DWORD n = 0;
      if (h != INVALID_HANDLE_VALUE) { WriteFile(h, "B", 1, &n, nullptr); CloseHandle(h); }
    }
    watch_collect(w, rs, 5000, [&](auto& r) { return has(r, wd, kModify, "w-a.txt"); });
    check("an edit is IN_MODIFY", has(rs, wd, kModify, "w-a.txt"), describe(rs));
    rs.clear();
    // A rename within one folder is a moved-from/moved-to pair; a move to
    // another folder is reported as a removal and an addition.
    MoveFileW(longpath(root + "\\w-a.txt").c_str(), longpath(root + "\\w-c.txt").c_str());
    watch_collect(w, rs, 5000, [&](auto& r) { return has(r, wd, kMovedTo, "w-c.txt"); });
    {
      uint32_t from = 0, to = 0;
      for (const auto& r : rs) {
        if (r.name == "w-a.txt" && (r.mask & kMovedFrom)) from = r.cookie;
        if (r.name == "w-c.txt" && (r.mask & kMovedTo)) to = r.cookie;
      }
      check("a rename is a moved-from/moved-to pair with one cookie", from && from == to,
          describe(rs));
    }
    rs.clear();
    MoveFileW(longpath(root + "\\w-c.txt").c_str(), longpath(root + "\\wsub\\w-b.txt").c_str());
    watch_collect(w, rs, 5000, [&](auto& r) { return has(r, wd, kCreate, "wsub/w-b.txt"); });
    check("a move to another folder is a delete and a create",
        has(rs, wd, kDelete, "w-c.txt") && has(rs, wd, kCreate, "wsub/w-b.txt"), describe(rs));
    rs.clear();
    make_dir(root + "\\wnew");
    watch_collect(w, rs, 5000, [&](auto& r) { return has(r, wd, kCreate | kIsDir, "wnew"); });
    check("a new folder is IN_CREATE|IN_ISDIR (a subtree audit)", has(rs, wd, kCreate | kIsDir, "wnew"),
        describe(rs));
    rs.clear();
    DeleteFileW(longpath(root + "\\wsub\\w-b.txt").c_str());
    watch_collect(w, rs, 5000, [&](auto& r) { return has(r, wd, kDelete, "wsub/w-b.txt"); });
    check("a delete is IN_DELETE", has(rs, wd, kDelete, "wsub/w-b.txt"), describe(rs));
    rs.clear();
    write_file(stage + "\\staged.tmp", "S");
    watch_collect(w, rs, 1500, [&](auto&) { return false; });
    check("staging is not watched", rs.empty(), describe(rs));
    DeleteFileW(longpath(stage + "\\staged.tmp").c_str());
    rs.clear();
    // A name with a lone surrogate (valid on NTFS, not UTF-16): watch_entry
    // converts component by component and audits the parent by stat
    // (anj_watch::unreadable), never the whole root. Converting the whole
    // name at once would make this an IN_Q_OVERFLOW (PR #84 delta review).
    {
      const std::wstring lone = std::wstring(L"bad") + static_cast<wchar_t>(0xD800) + L".txt";
      for (const std::string parent : {std::string("wsub"), std::string()}) {
        std::wstring at = longpath(parent.empty() ? root : root + "\\" + parent) + L"\\" + lone;
        HANDLE h = CreateFileW(at.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
            FILE_ATTRIBUTE_NORMAL, nullptr);
        bool made = h != INVALID_HANDLE_VALUE;
        if (made) CloseHandle(h);
        watch_collect(w, rs, 3000, [&](auto& r) {
          return has(r, wd, kCreate | kIsDir, parent) || any_mask(r, kOverflow);
        });
        std::string what = parent.empty() ? "the root" : "its parent";
        check(("a lone-surrogate name audits " + what + " by stat, not the whole root").c_str(),
            made && has(rs, wd, kCreate | kIsDir, parent) && !any_mask(rs, kOverflow),
            describe(rs));
        DeleteFileW(at.c_str());
        watch_collect(w, rs, 500, [&](auto&) { return false; });
        rs.clear();
      }
    }
    // 5,000 files in one burst: every name arrives, or an overflow (an audit).
    make_dir(root + "\\burst");
    watch_collect(w, rs, 3000, [&](auto& r) { return has(r, wd, kCreate | kIsDir, "burst"); });
    rs.clear();
    ULONGLONG began = GetTickCount64();
    for (int i = 0; i < 5000; i++) write_plain(root + "\\burst\\f" + std::to_string(i) + ".txt", "x");
    ULONGLONG written = GetTickCount64();
    std::vector<char> seen(5000, 0);
    int count = 0;
    bool overflow = false;
    watch_collect(w, rs, 20000, [&](auto& r) {
      for (; !r.empty(); r.pop_back()) {
        const auto& x = r.back();
        if (x.mask & kOverflow) overflow = true;
        if (x.name.rfind("burst/f", 0) == 0 && (x.mask & kCreate)) {
          int i = atoi(x.name.c_str() + 7);
          if (i >= 0 && i < 5000 && !seen[i]) { seen[i] = 1; count++; }
        }
      }
      return overflow || count == 5000;
    });
    ULONGLONG covered = GetTickCount64();
    check("a 5,000-file burst: every create, no overflow", count == 5000 && !overflow,
        std::to_string(count) + " creates, overflow " + (overflow ? "yes" : "no") + ", written in " +
        std::to_string(written - began) + " ms, covered " + std::to_string(covered - written) +
        " ms after the last write");
    // A suspend (the sleep clock jumped) is a record with wd -2.
    rs.clear();
    api.watch_clock(w, 5000000000LL);
    watch_collect(w, rs, 3000, [&](auto& r) { return has(r, -2, 0, ""); });
    check("a suspend is the wd -2 record", has(rs, -2, 0, ""), describe(rs));
    // A watch handle that fails: the root audit record, then the error.
    rs.clear();
    check("the watch handle can be failed (test seam)", api.watch_cancel(w) == 0);
    intptr_t last = watch_collect(w, rs, 5000, [&](auto&) { return false; });
    check("a failed watch handle reports the root, then an error",
        has(rs, wd, kMoveSelf, "") && last == -1, describe(rs) + " last " + std::to_string(last));
    api.watch_stop(w);
    std::vector<uint8_t> b(64);
    check("after stop, wait returns -2", api.watch_wait(w, b.data(), 64, 0) == -2);
    api.watch_release(w);
    api.watch_release(w);
  }
  {
    // Overflow: a read buffer far too small for the changes between reads.
    void* w = api.watch_open();
    check("tiny-buffer watch opens", w && api.watch_buffer(w, 64) == 0);
    int wd = w ? watch_add(w, rootfd, "") : -1;
    check("tiny-buffer watch starts", wd >= 1, got(wd));
    if (wd >= 1) {
      // A few files: fewer overflows than fail the watch.
      make_dir(root + "\\flood");
      for (int i = 0; i < 5; i++) write_plain(root + "\\flood\\g" + std::to_string(i) + ".txt", "y");
      std::vector<WatchRecord> rs;
      intptr_t last = watch_collect(w, rs, 10000, [&](auto& r) { return any_mask(r, kOverflow); });
      check("an overflowed buffer is IN_Q_OVERFLOW (a full audit)", any_mask(rs, kOverflow),
          describe(rs));
      rs.clear();
      if (last >= 0) last = watch_collect(w, rs, 1500, [&](auto&) { return false; });
      check("a few overflows keep the watch", last >= 0, "last " + std::to_string(last));
    }
    if (w) { api.watch_stop(w); api.watch_release(w); api.watch_release(w); }
  }
  {
    // Overflow after overflow, 32 within a second: no progress, so the watch
    // fails (the engine stat-scans and restarts it) rather than reissuing
    // without limit.
    void* w = api.watch_open();
    check("tiny-buffer watch for repeated overflows starts",
        w && api.watch_buffer(w, 64) == 0 && watch_add(w, rootfd, "") >= 1);
    make_dir(root + "\\spin");
    std::vector<WatchRecord> rs;
    intptr_t last = 0;
    int writes = 0;
    ULONGLONG began = GetTickCount64(), until = began + 10000;
    while (w && last >= 0 && GetTickCount64() < until) {
      write_plain(root + "\\spin\\s" + std::to_string(writes++) + ".txt", "z");
      last = watch_collect(w, rs, 1, [&](auto&) { return false; });
    }
    check("repeated overflows within a second fail the watch",
        any_mask(rs, kOverflow) && last == -1,
        std::to_string(writes) + " writes in " + std::to_string(GetTickCount64() - began) +
        " ms, last " + std::to_string(last));
    if (w) { api.watch_stop(w); api.watch_release(w); api.watch_release(w); }
  }
  {
    // The root cannot go while held, so its watch never sees it go.
    void* w = api.watch_open();
    int wd = w ? watch_add(w, rootfd, "") : -1;
    BOOL renamed = MoveFileW(longpath(root).c_str(), longpath(root + "-gone").c_str());
    if (renamed) MoveFileW(longpath(root + "-gone").c_str(), longpath(root).c_str());
    BOOL removed = RemoveDirectoryW(longpath(root).c_str());
    check("while watched, the root can be neither renamed nor removed", wd >= 1 && !renamed && !removed);
    if (w) { api.watch_stop(w); api.watch_release(w); api.watch_release(w); }
  }
}

int run(const std::string& dir, const std::string& dll) {
  if (!load(dll.c_str())) { printf("FAIL load %s (%lu)\n", dll.c_str(), static_cast<unsigned long>(GetLastError())); return 2; }
  const std::string work = dir + "\\run-" + std::to_string(GetCurrentProcessId());
  const std::string root = work + "\\root", stage = work + "\\.stage",
      outside = work + "\\outside";
  make_dir(dir); make_dir(work); make_dir(root); make_dir(stage); make_dir(outside);
  write_file(outside + "\\secret.txt", "SECRET");
  const int baseline = api.open_count();

  check("chmod_private staging", api.chmod_private(stage.c_str()) == 0, got(-1));
  int rootfd = api.open_root(root.c_str());
  int stagefd = api.open_root(stage.c_str());
  check("open_root", rootfd >= 0 && stagefd >= 0, got(rootfd));
  check("fs_magic is NTFS", api.fs_magic(rootfd, "") == 0x5346544E);
  {
    std::string info = take(api.root_info(rootfd));
    check("root_info identity matches stamp",
        field(info, "identity") == identity_of_fd(rootfd) && field(info, "stable") == "true",
        info);
    check("check_root", api.check_root(rootfd, root.c_str()) == 0, got(-1));
    std::wstring moved = longpath(root + "-moved");
    BOOL renamed = MoveFileW(longpath(root).c_str(), moved.c_str());
    DWORD why = GetLastError();
    if (renamed) MoveFileW(moved.c_str(), longpath(root).c_str());
    check("root cannot be renamed while held", !renamed,
        "MoveFileW error " + std::to_string(why));
  }

  // ---- S2 seams ----
  check("error names", std::string(api.error_name(11)) == "wouldBlock" &&
      std::string(api.error_name(16)) == "busy" && std::string(api.error_name(17)) == "exists" &&
      std::string(api.error_name(2)) == "notFound" && std::string(api.error_name(40)) == "loop" &&
      std::string(api.error_name(39)) == "notEmpty" && std::string(api.error_name(0)) == "none" &&
      std::string(api.error_name(100000)) == "other");
  check("guard kind", std::string(api.guard_kind()) == "exclusiveOpen", api.guard_kind());
  {
    std::string through = take(api.stage_path(stagefd));
    wchar_t full[MAX_PATH * 4] = {};
    GetFullPathNameW(wide(stage).c_str(), MAX_PATH * 4, full, nullptr);
    check("stage_path names the staging directory",
        !through.empty() && _wcsicmp(wide(through).c_str(), full) == 0, through);
    check("Dart-style '<stage_path>/name' reaches staging",
        write_plain(through + "/via-path", "VIA") && read_file(stage + "\\via-path") == "VIA");
    DeleteFileW(longpath(stage + "\\via-path").c_str());
    check("stage_path of a closed number is EBADF", take(api.stage_path(99999)).empty() &&
        api.error() == 9);
  }
  {
    // Spec #33 I3: anj_locate_identity (OpenFileById, every link enumerated).
    auto identity = [&](const std::string& rel) {
      int fd = api.open_read(rootfd, rel.c_str());
      if (fd < 0) fd = api.open_directory(rootfd, rel.c_str());
      std::string id = fd >= 0 ? identity_of_fd(fd) : std::string();
      if (fd >= 0) api.close(fd);
      return id;
    };
    auto locate = [&](const std::string& id) {
      char out[4096];
      long long links = -1;
      int place = api.locate_identity(rootfd, stagefd, id.c_str(), out, sizeof(out), &links);
      return std::to_string(place) + (place == 1 ? " " + std::string(out) : std::string()) +
          " links=" + std::to_string(links);
    };
    const int open_before = api.open_count();
    make_dir(root + "\\loc"); make_dir(root + "\\loc\\from");
    write_file(root + "\\loc\\from\\a.txt", "a");
    std::string file = identity("loc/from/a.txt"), folder = identity("loc/from");
    MoveFileW(longpath(root + "\\loc\\from\\a.txt").c_str(),
        longpath(root + "\\loc\\from\\b c.txt").c_str());
    check("locate: renamed file", locate(file) == "1 loc/from/b c.txt links=1", locate(file));
    MoveFileW(longpath(root + "\\loc\\from").c_str(), longpath(root + "\\loc\\to").c_str());
    check("locate: moved folder and the file beneath it",
        locate(folder) == "1 loc/to links=1" && locate(file) == "1 loc/to/b c.txt links=1",
        locate(folder) + "; " + locate(file));
    {
      // Held open by another app without delete sharing: still found.
      HANDLE busy = CreateFileW(longpath(root + "\\loc\\to\\b c.txt").c_str(), GENERIC_READ,
          FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
      check("locate: a file another app holds open", busy != INVALID_HANDLE_VALUE &&
          locate(file) == "1 loc/to/b c.txt links=1", locate(file));
      if (busy != INVALID_HANDLE_VALUE) CloseHandle(busy);
    }
    CreateHardLinkW(longpath(root + "\\loc\\to\\second.txt").c_str(),
        longpath(root + "\\loc\\to\\b c.txt").c_str(), nullptr);
    std::string both = locate(file);
    check("locate: a second link in the root reports two links",
        both == "1 loc/to/b c.txt links=2" || both == "1 loc/to/second.txt links=2", both);
    DeleteFileW(longpath(root + "\\loc\\to\\second.txt").c_str());
    MoveFileW(longpath(root + "\\loc\\to\\b c.txt").c_str(),
        longpath(outside + "\\b c.txt").c_str());
    check("locate: moved out of the root", locate(file) == "2 links=0", locate(file));
    DeleteFileW(longpath(outside + "\\b c.txt").c_str());
    check("locate: deleted", locate(file) == "4 links=0", locate(file));
    // A download: installed by hard link from its staging copy, then renamed.
    write_file(stage + "\\down.part", "d");
    int linked = api.install(rootfd, "loc/down.txt", (stage + "\\down.part").c_str());
    std::string down = identity("loc/down.txt");
    MoveFileW(longpath(root + "\\loc\\down.txt").c_str(),
        longpath(root + "\\loc\\to\\down.txt").c_str());
    check("locate: renamed download (its other link in staging)",
        linked == 0 && locate(down) == "1 loc/to/down.txt links=2", locate(down));
    DeleteFileW(longpath(root + "\\loc\\to\\down.txt").c_str());
    check("locate: download deleted (only the staging link left)",
        locate(down) == "2 links=0", locate(down));
    DeleteFileW(longpath(stage + "\\down.part").c_str());
    std::string volume = file.substr(0, file.rfind(':'));
    std::string bad;
    for (std::string id : {std::string(), std::string("x"), std::string(":5"),
             volume + ":", volume + ":abc", volume + "x:" + file.substr(file.rfind(':') + 1),
             volume + ":9223372036854775"})
      bad += locate(id) + ";";
    // Fail safe: a malformed identity and another volume key prove nothing
    // (uncertain); only an unknown id on the root's volume is not found.
    check("locate: malformed identities and another volume are uncertain, an unknown id is not found",
        bad == "5 links=0;5 links=0;5 links=0;5 links=0;5 links=0;5 links=0;4 links=0;", bad);
    char small[4];
    long long links = -1;
    write_file(root + "\\loc\\to\\long-name.txt", "l");
    // Decision #143: every error is uncertain (5, error_number set), never
    // folded into not found or outside.
    check("locate: a path longer than the buffer is uncertain",
        api.locate_identity(rootfd, stagefd, identity("loc/to/long-name.txt").c_str(), small,
            sizeof(small), &links) == 5 && small[0] == 0 && links == 0 && api.error() == 36,
        std::to_string(api.error()));
    check("locate: a closed number is uncertain",
        api.locate_identity(99999, -1, file.c_str(), small, sizeof(small), &links) == 5 &&
            api.error() == 9, std::to_string(api.error()));
    {
      // A name listed beneath the root that no longer opens as the file (it
      // moved after the listing): uncertain, where it used to be outside.
      std::string long_id = identity("loc/to/long-name.txt");
      api.debug_locate_race(1);
      std::string raced = locate(long_id);
      int cause = api.error();
      api.debug_locate_race(0);
      check("locate: the file changes between listing and re-open: uncertain",
          raced == "5 links=0" && cause == 116 && locate(long_id) == "1 loc/to/long-name.txt links=1",
          raced + " errno " + std::to_string(cause));
    }
    {
      // A sibling whose name extends the root's ("root2"): outside.
      const std::string sibling = work + "\\root2";
      make_dir(sibling);
      write_file(root + "\\loc\\to\\sib.txt", "s");
      std::string sib = identity("loc/to/sib.txt");
      MoveFileW(longpath(root + "\\loc\\to\\sib.txt").c_str(),
          longpath(sibling + "\\sib.txt").c_str());
      check("locate: moved to a sibling named root2 is outside", locate(sib) == "2 links=0",
          locate(sib));
      DeleteFileW(longpath(sibling + "\\sib.txt").c_str());
      RemoveDirectoryW(longpath(sibling).c_str());
    }
    {
      // Moved out of the root, with a junction inside the root to where it
      // went: outside, never reached through the link.
      make_dir(root + "\\loc\\jt");
      write_file(root + "\\loc\\jt\\j.txt", "j");
      std::string jfolder = identity("loc/jt"), jfile = identity("loc/jt/j.txt");
      MoveFileW(longpath(root + "\\loc\\jt").c_str(), longpath(outside + "\\jt").c_str());
      if (!make_junction(root + "\\loc\\jlink", L"\\??\\" + wide(outside + "\\jt"),
              wide(outside + "\\jt"))) {
        skip("locate: a junction inside the root", "junction creation failed " +
            std::to_string(GetLastError()));
      } else {
        check("locate: moved out, a junction inside the root to it: outside",
            locate(jfolder) == "2 links=0" && locate(jfile) == "2 links=0",
            locate(jfolder) + "; " + locate(jfile));
        RemoveDirectoryW(longpath(root + "\\loc\\jlink").c_str());
      }
      DeleteFileW(longpath(outside + "\\jt\\j.txt").c_str());
      RemoveDirectoryW(longpath(outside + "\\jt").c_str());
    }
    {
      // Case-only and normalization-only renames come back spelled as now.
      write_file(root + "\\loc\\to\\case.txt", "c");
      std::string cased = identity("loc/to/case.txt");
      MoveFileW(longpath(root + "\\loc\\to\\case.txt").c_str(),
          longpath(root + "\\loc\\to\\CASE.TXT").c_str());
      check("locate: a case-only rename", locate(cased) == "1 loc/to/CASE.TXT links=1",
          locate(cased));
      const std::string nfc = "caf\xc3\xa9.txt", nfd = "cafe\xcc\x81.txt";
      write_file(root + "\\loc\\to\\" + nfc, "n");
      std::string normal = identity("loc/to/" + nfc);
      MoveFileW(longpath(root + "\\loc\\to\\" + nfc).c_str(),
          longpath(root + "\\loc\\to\\" + nfd).c_str());
      check("locate: an NFC name renamed to its NFD spelling",
          locate(normal) == "1 loc/to/" + nfd + " links=1", locate(normal));
      DeleteFileW(longpath(root + "\\loc\\to\\CASE.TXT").c_str());
      DeleteFileW(longpath(root + "\\loc\\to\\" + nfd).c_str());
    }
    ULONGLONG start = GetTickCount64();
    std::string again = identity("loc/to/long-name.txt");
    bool same = true;
    DWORD handles_before = 0, handles_after = 0;
    GetProcessHandleCount(GetCurrentProcess(), &handles_before);
    for (int i = 0; i < 500; i++) same = same && locate(again) == "1 loc/to/long-name.txt links=1";
    GetProcessHandleCount(GetCurrentProcess(), &handles_after);
    ULONGLONG spent = GetTickCount64() - start;
    check("locate: 500 lookups, bounded, no handle left open",
        same && spent < 5000 && api.open_count() == open_before &&
            handles_after <= handles_before + 2,
        std::to_string(spent) + " ms, process handles " + std::to_string(handles_before) +
            " -> " + std::to_string(handles_after));
  }
  {
    // The profile lifetime lock (spec #32 W3): no sharing, held until close.
    std::string profile = work + "\\profile";
    make_dir(profile);
    check("profile lock refuses a non-private directory",
        refused(api.profile_lock(profile.c_str(), -1), 1), got(-1));
    api.chmod_private(profile.c_str());
    int lock = api.profile_lock(profile.c_str(), -1);
    check("profile lock taken", lock >= 0, got(lock));
    check("a second profile lock is wouldBlock (EAGAIN)",
        refused(api.profile_lock(profile.c_str(), -1), 11) &&
        std::string(api.error_name(11)) == "wouldBlock", got(-1));
    HANDLE other = CreateFileW(longpath(profile + "\\.instance.lock").c_str(), GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, 0, nullptr);
    check("the lock file cannot be opened while held", other == INVALID_HANDLE_VALUE &&
        GetLastError() == ERROR_SHARING_VIOLATION);
    if (other != INVALID_HANDLE_VALUE) CloseHandle(other);
    check("an inherited profile lock is ENOTSUP",
        refused(api.profile_lock(profile.c_str(), 5), 95), got(-1));
    check("a relative profile path is refused", refused(api.profile_lock("profile", -1), 22), got(-1));
    std::string sub = profile + "\\..\\profile-other";
    make_dir(work + "\\profile-other");
    check("a non-canonical profile path is refused",
        refused(api.profile_lock(sub.c_str(), -1), 22), got(-1));
    api.close(lock);
    lock = api.profile_lock(profile.c_str(), -1);
    check("the lock is taken again after release", lock >= 0, got(lock));
    if (lock >= 0) api.close(lock);
  }
  watch_tests(root, stage, rootfd);

  // ---- Acceptance row 4: confined resolution ----
  const char* lexical[] = {"..", ".", "", "a/../b", "./a", "a\\b", "a:b", "x.txt:stream",
      "x.txt::$DATA", "CON", "nul.txt", "Com1.log", "LPT9", "aux .txt", "CONIN$", "x.", "x ",
      "a*b", "a?b", "a<b", "a|b", "/abs", "a//b", "a/", "C:\\Windows\\win.ini", "\x01"};
  for (const char* bad : lexical) {
    check(std::string("lexical refusal open_read '") + bad + "'",
        refused(api.open_read(rootfd, bad), 22), got(-1));
    check(std::string("lexical refusal mkdir '") + bad + "'",
        refused(api.mkdir(rootfd, bad), 22), got(-1));
  }
  {
    std::string blob = take(api.watch_scan(nullptr, rootfd, "nul.txt", 0));
    check("watch_scan of an absent reserved name lists nothing",
        blob == "{\"items\":[],\"watches\":[]}", blob);
  }

  bool junction = make_junction(root + "\\jdir", L"\\??\\" + wide(outside), wide(outside));
  if (!junction) {
    skip("junction refusals", "junction creation failed " + std::to_string(GetLastError()));
  } else {
    check("junction intermediate refused", refused(api.open_read(rootfd, "jdir/secret.txt"), 40),
        got(-1));
    check("junction final refused (directory)", refused(api.open_directory(rootfd, "jdir"), 40),
        got(-1));
    check("junction info_at refused", take(api.info_at(rootfd, "jdir/secret.txt")).empty());
    check("junction mkdir beneath refused", refused(api.mkdir(rootfd, "jdir/new"), 40) &&
        !exists(outside + "\\new"), got(-1));
    std::string blob = take(api.watch_scan(nullptr, rootfd, "jdir/secret.txt", 0));
    check("junction watch_scan beneath is empty", blob == "{\"items\":[],\"watches\":[]}", blob);
    blob = take(api.watch_scan(nullptr, rootfd, "jdir", 1));
    check("junction watch_scan lists it unsupported", listed(blob, "jdir", "unsupported") &&
        blob.find("secret") == std::string::npos, blob);
    std::string all = take(api.scan(rootfd));
    check("scan lists the junction as unsupported and does not enter it",
        listed(all, "jdir", "unsupported") && all.find("secret") == std::string::npos, all);
    write_file(stage + "\\link-src", "L");
    check("install through a junction refused",
        refused(api.install(rootfd, "jdir/x", (stage + "\\link-src").c_str()), 40) &&
        !exists(outside + "\\x"), got(-1));
    DeleteFileW(longpath(stage + "\\link-src").c_str());
    // In staging too.
    bool sj = make_junction(stage + "\\sj", L"\\??\\" + wide(outside), wide(outside));
    check("staging junction: guard_open beneath refused",
        sj && refused(api.guard_open(stagefd, "sj/secret.txt", "x", 1), 40), got(-1));
    check("staging junction: preview refused", take(api.preview_editor(stagefd, "sj")).empty());
    RemoveDirectoryW(longpath(stage + "\\sj").c_str());
    check("outside unchanged", read_file(outside + "\\secret.txt") == "SECRET");
  }
  {
    wchar_t volume[MAX_PATH] = {};
    std::wstring drive = wide(root.substr(0, 3));
    bool have = GetVolumeNameForVolumeMountPointW(drive.c_str(), volume, MAX_PATH) != 0;
    std::wstring target = volume;  // \\?\Volume{...}\ -> \??\Volume{...}\ .
    if (have && target.size() > 4) target = L"\\??\\" + target.substr(4);
    if (!have || !make_junction(root + "\\mnt", target, volume)) {
      skip("mount point refusal", "mount point creation failed " + std::to_string(GetLastError()));
    } else {
      check("mount point refused", refused(api.open_directory(rootfd, "mnt"), 40) &&
          refused(api.open_read(rootfd, "mnt/Windows/win.ini"), 40), got(-1));
      RemoveDirectoryW(longpath(root + "\\mnt").c_str());
    }
  }
  {
    std::string links = dir + "\\links";
    int linkfd = exists(links + "\\sdir") ? api.open_root(links.c_str()) : -1;
    if (linkfd < 0) {
      skip("symlink and explicit 8.3 refusals", "no elevated fixture at " + links);
    } else {
      check("directory symlink intermediate refused",
          refused(api.open_read(linkfd, "sdir/secret.txt"), 40), got(-1));
      check("directory symlink final refused", refused(api.open_directory(linkfd, "sdir"), 40),
          got(-1));
      check("file symlink refused", refused(api.open_read(linkfd, "sfile"), 40), got(-1));
      int fd = api.open_read(linkfd, "LongFileName.txt");
      check("long name opens", fd >= 0, got(fd));
      if (fd >= 0) api.close(fd);
      check("explicit 8.3 alias refused", refused(api.open_read(linkfd, "LFN~1.TXT"), 2),
          got(-1));
      check("case alias of a directory refused", refused(api.open_read(linkfd, "REAL/inner.txt"), 2),
          got(-1));
      check("case alias of a file refused", refused(api.open_read(linkfd, "real/INNER.TXT"), 2),
          got(-1));
      fd = api.open_read(linkfd, "real/inner.txt");
      check("exact names open", fd >= 0 && read_fd(fd) == "INNER", got(fd));
      if (fd >= 0) api.close(fd);
      std::string all = take(api.scan(linkfd));
      check("scan lists symlinks unsupported and does not follow",
          listed(all, "sdir", "unsupported") && listed(all, "sfile", "unsupported") &&
          all.find("secret") == std::string::npos, all);
      api.close(linkfd);
    }
  }
  write_file(root + "\\Case.txt", "CASE");
  check("case alias refused", refused(api.open_read(rootfd, "case.txt"), 2), got(-1));
  {
    int fd = api.open_read(rootfd, "Case.txt");
    check("exact case opens", fd >= 0 && read_fd(fd) == "CASE", got(fd));
    if (fd >= 0) api.close(fd);
  }
  check("mkdir creates", api.mkdir(rootfd, "Docs") == 0, got(-1));
  check("mkdir of the same name succeeds", api.mkdir(rootfd, "Docs") == 0, got(-1));
  check("mkdir of a case alias is a collision", refused(api.mkdir(rootfd, "docs"), 17), got(-1));
  check("mkdir_exclusive refuses existing", refused(api.mkdir_exclusive(rootfd, "Docs"), 17), got(-1));
  {
    // The shared ABI's exclusive create (the documents provider's, on Android).
    int fd = api.create_file(rootfd, "Docs/created.txt");
    check("create_file creates an empty file and returns it open", fd >= 0 && read_fd(fd).empty(), got(fd));
    if (fd >= 0) api.close(fd);
    check("create_file never replaces an existing file", refused(api.create_file(rootfd, "Docs/created.txt"), 17), got(-1));
    check("create_file refuses a case alias of an existing file", refused(api.create_file(rootfd, "Docs/CREATED.TXT"), 17), got(-1));
    check("create_file refuses an existing directory's name", refused(api.create_file(rootfd, "Docs"), 17), got(-1));
    check("create_file needs its parent", refused(api.create_file(rootfd, "Absent/created.txt"), 2), got(-1));
    fd = api.open_read(rootfd, "Docs/created.txt");
    check("the created file opens by its exact name", fd >= 0, got(fd));
    if (fd >= 0) api.close(fd);
    DeleteFileW(longpath(root + "\\Docs\\created.txt").c_str());
  }
  {
    write_file(root + "\\AutoShortNameExample.txt", "AUTO");
    wchar_t shortname[MAX_PATH * 4] = {};
    std::wstring full = longpath(root + "\\AutoShortNameExample.txt");
    DWORD n = GetShortPathNameW(full.c_str(), shortname, MAX_PATH * 4);
    std::wstring s(shortname, n);
    std::wstring leaf = s.substr(s.rfind(L'\\') + 1);
    if (!n || leaf == L"AutoShortNameExample.txt") {
      skip("generated 8.3 alias", "the volume generates no short names");
    } else {
      check("generated 8.3 alias refused (" + narrow(leaf) + ")",
          refused(api.open_read(rootfd, narrow(leaf).c_str()), 2), got(-1));
    }
  }
  {
    std::string all = take(api.scan(rootfd));
    check("scan has exact names", listed(all, "Case.txt", "file") &&
        listed(all, "Docs", "directory"), all);
    std::string one = take(api.watch_scan(nullptr, rootfd, "case.txt", 0));
    check("watch_scan of a case alias is empty", one == "{\"items\":[],\"watches\":[]}", one);
  }

  // ---- Acceptance row 5: no-replace install, restore, quarantine ----
  write_file(root + "\\Occupied.txt", "OLD");
  write_file(stage + "\\s1", "NEW");
  const std::string s1 = stage + "\\s1";
  check("install refuses an occupied destination",
      refused(api.install(rootfd, "Occupied.txt", s1.c_str()), 17) &&
      read_file(root + "\\Occupied.txt") == "OLD", got(-1));
  check("install refuses a case-only occupied destination",
      refused(api.install(rootfd, "occupied.txt", s1.c_str()), 17) &&
      read_file(root + "\\Occupied.txt") == "OLD", got(-1));
  check("install links into an absent destination",
      api.install(rootfd, "fresh.txt", s1.c_str()) == 0 && read_file(root + "\\fresh.txt") == "NEW",
      got(-1));
  {
    std::string info = take(api.info_at(stagefd, "s1"));
    check("install made a hard link (links 2)", field(info, "links") == "2", info);
    check("files created unelevated are owned", field(info, "owned") == "true", info);
  }
  {
    int fd = api.create_owned(stagefd, "r1");
    check("create_owned in private staging", fd >= 0, got(fd));
    if (fd >= 0) api.close(fd);
    check("create_owned refuses an existing name", refused(api.create_owned(stagefd, "r1"), 17) ||
        api.error() == 17, got(-1));
    write_file(stage + "\\r1", "R1");
    check("restore refuses an occupied destination",
        refused(api.restore_owned(rootfd, "Occupied.txt", stagefd, "r1"), 17) &&
        exists(stage + "\\r1") && read_file(root + "\\Occupied.txt") == "OLD", got(-1));
    check("restore refuses a case-only occupied destination",
        refused(api.restore_owned(rootfd, "OCCUPIED.TXT", stagefd, "r1"), 17) &&
        exists(stage + "\\r1"), got(-1));
    check("restore moves into an absent destination",
        api.restore_owned(rootfd, "restored.txt", stagefd, "r1") == 0 &&
        !exists(stage + "\\r1") && read_file(root + "\\restored.txt") == "R1", got(-1));
    check("create_owned refuses a non-private directory",
        api.create_owned(rootfd, "nope") < 0 && !exists(root + "\\nope"), got(-1));
  }
  write_file(stage + "\\occ", "OCC");
  check("preserve refuses an occupied staging name",
      refused(api.preserve_owned(rootfd, "fresh.txt", stagefd, "occ"), 17) &&
      exists(root + "\\fresh.txt") && read_file(stage + "\\occ") == "OCC", got(-1));
  {
    // fresh.txt and s1 are two links of one file: a no-replace rename of one
    // onto the other must leave both names.
    int n = api.preserve_owned(rootfd, "fresh.txt", stagefd, "s1");
    int e = api.error();
    printf("NOTE rename onto another link of the same file: result %d errno %d, fresh %d s1 %d\n",
        n, e, exists(root + "\\fresh.txt") ? 1 : 0, exists(stage + "\\s1") ? 1 : 0);
    check("rename onto another link of the same file never removes a name",
        exists(root + "\\fresh.txt") && exists(stage + "\\s1"));
  }
  if (!exists(root + "\\fresh.txt")) write_file(root + "\\fresh.txt", "NEW");
  check("preserve moves into staging", api.preserve_owned(rootfd, "fresh.txt", stagefd, "p1") == 0 &&
      !exists(root + "\\fresh.txt") && read_file(stage + "\\p1") == "NEW", got(-1));
  check("quarantine refuses an occupied staging path",
      refused(api.quarantine(rootfd, "restored.txt", s1.c_str()), 17) &&
      exists(root + "\\restored.txt"), got(-1));
  check("quarantine moves into staging",
      api.quarantine(rootfd, "restored.txt", (stage + "\\q1").c_str()) == 0 &&
      !exists(root + "\\restored.txt") && read_file(stage + "\\q1") == "R1", got(-1));
  check("install_owned refuses an occupied destination",
      refused(api.install_owned(rootfd, "Occupied.txt", stagefd, "q1"), 17), got(-1));
  check("install_owned links", api.install_owned(rootfd, "owned.txt", stagefd, "q1") == 0 &&
      read_file(root + "\\owned.txt") == "R1", got(-1));
  {
    make_dir(stage + "\\d1");
    int d = api.open_directory(stagefd, "d1");
    std::string id = d >= 0 ? identity_of_fd(d) : "";
    if (d >= 0) api.close(d);
    std::string parent = identity_of_fd(rootfd);
    make_dir(root + "\\Dir1");
    check("install_directory refuses an occupied destination",
        refused(api.install_directory(rootfd, stagefd, "d1", "Dir1", parent.c_str(), id.c_str()), 17),
        got(-1));
    check("install_directory refuses a case-only occupied destination",
        refused(api.install_directory(rootfd, stagefd, "d1", "dir1", parent.c_str(), id.c_str()), 17) &&
        exists(stage + "\\d1"), got(-1));
    check("install_directory refuses a wrong identity",
        refused(api.install_directory(rootfd, stagefd, "d1", "NewDir", parent.c_str(), "w0:1"), 116),
        got(-1));
    check("install_directory publishes",
        api.install_directory(rootfd, stagefd, "d1", "NewDir", parent.c_str(), id.c_str()) == 0 &&
        exists(root + "\\NewDir") && !exists(stage + "\\d1"), got(-1));
    write_file(root + "\\NewDir\\child", "C");
    check("rmdir_empty refuses a non-empty directory",
        refused(api.rmdir_empty(rootfd, "NewDir", id.c_str()), 39) && exists(root + "\\NewDir"),
        got(-1));
    DeleteFileW(longpath(root + "\\NewDir\\child").c_str());
    check("rmdir_empty refuses a wrong identity",
        refused(api.rmdir_empty(rootfd, "NewDir", "w0:1"), 116), got(-1));
    check("rmdir_empty removes", api.rmdir_empty(rootfd, "NewDir", id.c_str()) == 0 &&
        !exists(root + "\\NewDir"), got(-1));
  }
  {
    int fd = api.open_read(rootfd, "owned.txt");
    std::string id = fd >= 0 ? identity_of_fd(fd) : "";
    if (fd >= 0) api.close(fd);
    check("rename_noreplace refuses an occupied name",
        refused(api.rename_noreplace(rootfd, "owned.txt", "Case.txt", id.c_str()), 17), got(-1));
    check("rename_noreplace refuses a case-only occupied name",
        refused(api.rename_noreplace(rootfd, "owned.txt", "CASE.TXT", id.c_str()), 17), got(-1));
    check("rename_noreplace renames across directories",
        api.rename_noreplace(rootfd, "owned.txt", "Docs/renamed.txt", id.c_str()) == 0 &&
        read_file(root + "\\Docs\\renamed.txt") == "R1", got(-1));
  }

  // ---- durability record (row 7 is inference beyond this) ----
  {
    long status = api.last_dir_flush();
    long refused_count = api.dir_flush_refused();
    char buffer[96];
    snprintf(buffer, sizeof(buffer), "last directory flush NTSTATUS 0x%08lx, refused %ld",
        static_cast<unsigned long>(status), refused_count);
    check("directory flush outcome recorded", true, buffer);
  }

  // ---- Acceptance row 6: release guard ----
  auto stamp_at = [&](int fd, const char* path) { return field(take(api.info_at(fd, path)), "stamp"); };
  {
    write_file(stage + "\\g1", "GUARD");
    int g = api.guard_open(stagefd, "g1", stamp_at(stagefd, "g1").c_str(), 1);
    check("guard opens with no other opener", g >= 0, got(g));
    if (g >= 0) {
      check("guard valid", api.guard_valid(g) == 0);
      check("guard reads", read_fd(g) == "GUARD" && api.rewind(g) == 0 && read_fd(g) == "GUARD");
      HANDLE other = CreateFileW(longpath(stage + "\\g1").c_str(), GENERIC_READ,
          FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, 0, nullptr);
      DWORD why = GetLastError();
      check("an open during the window fails (same process)",
          other == INVALID_HANDLE_VALUE && why == ERROR_SHARING_VIOLATION,
          "error " + std::to_string(why));
      if (other != INVALID_HANDLE_VALUE) CloseHandle(other);
      DWORD code = probe(stage + "\\g1");
      check("an open during the window fails (another process)", code == ERROR_SHARING_VIOLATION,
          "probe exit " + std::to_string(code));
      HANDLE attrs = CreateFileW(longpath(stage + "\\g1").c_str(), FILE_READ_ATTRIBUTES,
          FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, 0, nullptr);
      check("an attribute-only open still succeeds", attrs != INVALID_HANDLE_VALUE);
      if (attrs != INVALID_HANDLE_VALUE) CloseHandle(attrs);
      check("guard unlink removes the name", api.guard_unlink(g, stagefd, "g1") == 0 &&
          !exists(stage + "\\g1"), got(-1));
      check("guard close", api.guard_close(g) == 0);
      check("guard close twice is refused", refused(api.guard_close(g), 22));
    }
  }
  {
    write_file(stage + "\\g2", "BUSY");
    std::wstring event = L"Local\\anj-w2-hold-" + std::to_wstring(GetCurrentProcessId());
    HANDLE ready = CreateEventW(nullptr, TRUE, FALSE, event.c_str());
    PROCESS_INFORMATION holder = spawn(L"\"" + wide(self_path()) + L"\" hold \"" +
        wide(stage + "\\g2") + L"\" " + event);
    bool held = holder.hProcess && WaitForSingleObject(ready, 10000) == WAIT_OBJECT_0;
    check("helper holds a full-sharing read handle", held);
    std::string stamp = stamp_at(stagefd, "g2");
    check("guard refused while another process holds a handle",
        refused(api.guard_open(stagefd, "g2", stamp.c_str(), 1), 16), got(-1));
    end(holder);
    CloseHandle(ready);
    int g = api.guard_open(stagefd, "g2", stamp.c_str(), 1);
    check("guard allowed after that process closes", g >= 0, got(g));
    if (g >= 0) api.guard_close(g);
    check("wrong stamp refused", refused(api.guard_open(stagefd, "g2", "w0:1:2:3:4:5:6", 1), 116));
    check("wrong link count refused", refused(api.guard_open(stagefd, "g2", stamp.c_str(), 2), 116));
  }
  {
    // Notepad reads the file and closes it: not seen (Finish editing covers it).
    write_file(root + "\\notes.txt", "NOTES");
    PROCESS_INFORMATION pad = spawn(L"notepad.exe \"" + wide(root + "\\notes.txt") + L"\"");
    Sleep(3000);
    int g = api.guard_open(rootfd, "notes.txt", stamp_at(rootfd, "notes.txt").c_str(), 1);
    check("Notepad (reads and closes) does not hold the file", pad.hProcess && g >= 0, got(g));
    if (g >= 0) api.guard_close(g);
    end(pad);
  }
  {
    write_file(stage + "\\g3", "MAPPED");
    HANDLE file = CreateFileW(longpath(stage + "\\g3").c_str(), GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, 0, nullptr);
    HANDLE section = CreateFileMappingW(file, nullptr, PAGE_READWRITE, 0, 0, nullptr);
    void* view = section ? MapViewOfFile(section, FILE_MAP_WRITE, 0, 0, 0) : nullptr;
    if (section) CloseHandle(section);
    if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
    check("mapped view with handles closed", view != nullptr);
    int g = -1;
    // Observed on the seat (W2): the view keeps the file object and its share
    // access, so the exclusive open refuses a mapped file even after its
    // handles closed (stronger than the spec's table expected).
    std::string stamp = stamp_at(stagefd, "g3");
    check("a mapped view with its handles closed still refuses the guard (EBUSY)",
        refused(g = api.guard_open(stagefd, "g3", stamp.c_str(), 1), 16), got(g));
    if (g >= 0) api.guard_close(g);
    if (view) UnmapViewOfFile(view);
    view = nullptr;
    g = api.guard_open(stagefd, "g3", stamp.c_str(), 1);
    check("after unmapping the guard opens and the delete succeeds",
        g >= 0 && api.guard_unlink(g, stagefd, "g3") == 0 && !exists(stage + "\\g3"), got(g));
    if (g >= 0) api.guard_close(g);
  }
  {
    std::string content(64 * 1024 * 1024, 'x');
    write_file(root + "\\release.txt", content);
    ULARGE_INTEGER before = {}, after = {};
    int g = api.guard_open(rootfd, "release.txt", stamp_at(rootfd, "release.txt").c_str(), 1);
    check("guard on a root file", g >= 0, got(g));
    if (g >= 0) {
      check("guard quarantine moves the root file into staging",
          api.guard_quarantine(g, rootfd, "release.txt", stagefd, "rel-q") == 0 &&
          !exists(root + "\\release.txt") && exists(stage + "\\rel-q"), got(-1));
      check("guarded bytes still readable after the move", api.rewind(g) == 0 && read_fd(g) == content);
      check("guard quarantine refuses an occupied staging name", [&] {
        write_file(root + "\\release2.txt", "R2");
        int g2 = api.guard_open(rootfd, "release2.txt", stamp_at(rootfd, "release2.txt").c_str(), 1);
        bool ok = g2 >= 0 && refused(api.guard_quarantine(g2, rootfd, "release2.txt", stagefd, "rel-q"), 17) &&
            exists(root + "\\release2.txt");
        if (g2 >= 0) api.guard_close(g2);
        return ok;
      }());
      check("guard quarantine refuses a file that is not the guarded one",
          refused(api.guard_quarantine(g, rootfd, "release2.txt", stagefd, "other"), 116), got(-1));
      long long released_id = take_id(stagefd, "rel-q");
      GetDiskFreeSpaceExW(wide(root.substr(0, 3)).c_str(), &before, nullptr, nullptr);
      check("guard unlink of the quarantined file", api.guard_unlink(g, stagefd, "rel-q") == 0 &&
          !exists(stage + "\\rel-q"), got(-1));
      api.guard_close(g);
      // The file record is gone once the guard closes: opening it by id fails
      // (a live file opens by id as the control). NTFS returns the clusters
      // to free space at its next log checkpoint, so the free-space delta is
      // only reported.
      check("control: a live file opens by its id", by_id(root, take_id(rootfd, "Case.txt")));
      check("the released file no longer exists by id", !by_id(root, released_id));
      GetDiskFreeSpaceExW(wide(root.substr(0, 3)).c_str(), &after, nullptr, nullptr);
      printf("NOTE free space delta right after release: %lld bytes\n",
          static_cast<long long>(after.QuadPart - before.QuadPart));
    }
  }
  {
    write_file(stage + "\\h1", "LINKS");
    bool linked = CreateHardLinkW(longpath(stage + "\\h1b").c_str(), longpath(stage + "\\h1").c_str(), nullptr);
    std::string stamp = stamp_at(stagefd, "h1");
    check("guard refuses a mismatched link count", refused(api.guard_open(stagefd, "h1", stamp.c_str(), 1), 116));
    int g = api.guard_open(stagefd, "h1", stamp.c_str(), 2);
    check("guard on a two-link file", linked && g >= 0, got(g));
    if (g >= 0) {
      check("guard unlinks the alias name, then the opened name",
          api.guard_unlink(g, stagefd, "h1b") == 0 && api.guard_unlink(g, stagefd, "h1") == 0 &&
          !exists(stage + "\\h1") && !exists(stage + "\\h1b"), got(-1));
      api.guard_close(g);
    }
  }
  {
    write_file(stage + "\\g4", "LATE");
    int g = api.guard_open(stagefd, "g4", stamp_at(stagefd, "g4").c_str(), 1);
    api.debug_deadline(g, 0);
    Sleep(20);
    check("guard past its deadline is invalid", refused(api.guard_valid(g), 11));
    check("guard past its deadline refuses unlink", refused(api.guard_unlink(g, stagefd, "g4"), 11) &&
        exists(stage + "\\g4"));
    api.guard_close(g);
  }

  // ---- PR #55 review fixes (F1-F4, F6, F7, F9, F10; decision #128) ----
  {
    // F1: a single-link guard shares nothing: a supersede is refused.
    write_file(stage + "\\sup1", "SUPERSEDE-ME");
    int g = api.guard_open(stagefd, "sup1", stamp_at(stagefd, "sup1").c_str(), 1);
    LONG status = supersede(stage + "\\sup1");
    check("F1 supersede during a single-link guard is a sharing violation",
        g >= 0 && static_cast<ULONG>(status) == 0xC0000043, hex(status));
    check("F1 guard still valid after the refused supersede", api.guard_valid(g) == 0);
    // F1: a new hard link during the guard invalidates it.
    bool linked = CreateHardLinkW(longpath(stage + "\\sup1-link").c_str(),
        longpath(stage + "\\sup1").c_str(), nullptr) != 0;
    check("F1 a hard link added during the guard invalidates it",
        linked && refused(api.guard_valid(g), 116), got(-1));
    check("F1 an invalidated guard refuses unlink",
        refused(api.guard_unlink(g, stagefd, "sup1"), 116) && exists(stage + "\\sup1"), got(-1));
    api.guard_close(g);
    check("F1 the refused supersede left the bytes", read_file(stage + "\\sup1") == "SUPERSEDE-ME");
    // F1: a multi-link guard shares delete; a supersede gets through but
    // breaks the guard, so nothing acts on the emptied file.
    std::string stamp2 = stamp_at(stagefd, "sup1");
    int g2 = api.guard_open(stagefd, "sup1", stamp2.c_str(), 2);
    check("F1 two-link guard opens", g2 >= 0, got(g2));
    status = supersede(stage + "\\sup1-link");
    printf("NOTE supersede during a two-link guard: %s\n", hex(status).c_str());
    bool truncated = status >= 0;
    check("F1 a supersede during a two-link guard is refused or invalidates the guard",
        !truncated || (refused(api.guard_valid(g2), 116) &&
            refused(api.guard_quarantine(g2, stagefd, "sup1", stagefd, "sup1-q"), 116) &&
            refused(api.guard_unlink(g2, stagefd, "sup1-link"), 116) &&
            exists(stage + "\\sup1-link") && exists(stage + "\\sup1")), got(-1));
    if (g2 >= 0) api.guard_close(g2);
    // A write through another handle while a two-link guard shares delete is
    // impossible (no data sharing); a write before reopening is a stale stamp.
    write_file(stage + "\\sup1", "CHANGED");
    check("F1 a changed file refuses the guard (stale stamp)",
        refused(api.guard_open(stagefd, "sup1", stamp2.c_str(), 2), 116), got(-1));
  }
  {
    // F2: only fully qualified drive paths are absolute.
    write_file(root + "\\posix.txt", "P");
    const char* bad[] = {"/Users/Public/anj-w2-escape", "\\Users\\Public\\anj-w2-escape",
        "C:anj-w2-escape", "anj-w2-escape", "\\\\?\\UNC\\localhost\\C$\\Windows",
        "\\\\.\\C:\\Windows", "\\\\?\\GLOBALROOT\\Device\\HarddiskVolume1", "\\\\localhost\\C$"};
    for (const char* path : bad) {
      check(std::string("F2 not fully qualified refused: ") + path,
          refused(api.open_root(path), 22), got(-1));
      check(std::string("F2 quarantine destination refused: ") + path,
          refused(api.quarantine(rootfd, "posix.txt", (std::string(path) + "\\moved").c_str()), 22) &&
          exists(root + "\\posix.txt"), got(-1));
    }
    check("F2 /proc/self/fd staging paths refused",
        refused(api.install(rootfd, "x.txt", "/proc/self/fd/4/name"), 22), got(-1));
    int fd = api.open_root(("\\\\?\\" + root).c_str());
    check("F2 a \\\\?\\X:\\ path opens", fd >= 0, got(fd));
    if (fd >= 0) api.close(fd);
    fd = api.open_root(([&] { std::string r = root; for (auto& c : r) if (c == '\\') c = '/'; return r; })().c_str());
    check("F2 a X:/ path opens", fd >= 0, got(fd));
    if (fd >= 0) api.close(fd);
  }
  {
    // F3: names NTFS holds but the Win32 namespace cannot are listed as
    // unsupported and never entered.
    bool made = write_file(root + "\\nul.txt", "N") && write_file(root + "\\dot.", "D") &&
        make_dir(root + "\\bad.") && write_file(root + "\\bad.\\inside.txt", "I");
    std::string all = take(api.scan(rootfd));
    check("F3 scan lists non-portable names as unsupported and does not enter them",
        made && listed(all, "nul.txt", "unsupported") && listed(all, "dot.", "unsupported") &&
        listed(all, "bad.", "unsupported") && all.find("inside") == std::string::npos, all);
    std::string one = take(api.watch_scan(nullptr, rootfd, "nul.txt", 0));
    check("F3 watch_scan reports a non-portable leaf as unsupported",
        listed(one, "nul.txt", "unsupported"), one);
    one = take(api.watch_scan(nullptr, rootfd, "bad./inside.txt", 0));
    check("F3 watch_scan lists nothing beneath a non-portable directory",
        one == "{\"items\":[],\"watches\":[]}", one);
    check("F3 operations still refuse them", refused(api.open_read(rootfd, "nul.txt"), 22));
    delete_tree(longpath(root + "\\bad."));
    DeleteFileW(longpath(root + "\\nul.txt").c_str());
    DeleteFileW(longpath(root + "\\dot.").c_str());
  }
  {
    // F4: privateDir changes no child: stamps survive a restart's call.
    write_file(stage + "\\keep", "KEEP");
    api.install(rootfd, "kept-link.txt", (stage + "\\keep").c_str());
    std::string before = stamp_at(stagefd, "keep");
    HANDLE held = CreateFileW(longpath(stage + "\\keep").c_str(), GENERIC_READ, 0, nullptr,
        OPEN_EXISTING, 0, nullptr);
    check("F4 chmod_private again succeeds while a child is held exclusively",
        api.chmod_private(stage.c_str()) == 0, got(-1));
    if (held != INVALID_HANDLE_VALUE) CloseHandle(held);
    check("F4 chmod_private leaves child stamps unchanged",
        stamp_at(stagefd, "keep") == before, before + " vs " + stamp_at(stagefd, "keep"));
    std::string fresh = work + "\\private2";
    make_dir(fresh);
    write_file(fresh + "\\child", "C");
    int f = api.open_root(fresh.c_str());
    std::string child = f >= 0 ? field(take(api.info_at(f, "child")), "stamp") : "";
    check("F4 chmod_private of a new directory", api.chmod_private(fresh.c_str()) == 0, got(-1));
    check("F4 existing children of a newly private directory keep their stamps",
        f >= 0 && field(take(api.info_at(f, "child")), "stamp") == child);
    if (f >= 0) api.close(f);
  }
  {
    // F6: a read-only file is released like any other.
    write_file(stage + "\\ro", "RO");
    SetFileAttributesW(longpath(stage + "\\ro").c_str(), FILE_ATTRIBUTE_READONLY);
    int g = api.guard_open(stagefd, "ro", stamp_at(stagefd, "ro").c_str(), 1);
    check("F6 guard unlink of a read-only file", g >= 0 && api.guard_unlink(g, stagefd, "ro") == 0 &&
        !exists(stage + "\\ro"), got(g));
    if (g >= 0) api.guard_close(g);
    make_dir(root + "\\RoDir");
    SetFileAttributesW(longpath(root + "\\RoDir").c_str(), FILE_ATTRIBUTE_READONLY);
    int d = api.open_directory(rootfd, "RoDir");
    std::string id = d >= 0 ? identity_of_fd(d) : "";
    if (d >= 0) api.close(d);
    check("F6 rmdir_empty of a read-only directory", api.rmdir_empty(rootfd, "RoDir", id.c_str()) == 0 &&
        !exists(root + "\\RoDir"), got(-1));
  }
  {
    // F7: a case-only rename to its own name, as on Linux.
    write_file(root + "\\caseonly.txt", "C");
    int fd = api.open_read(rootfd, "caseonly.txt");
    std::string id = fd >= 0 ? identity_of_fd(fd) : "";
    if (fd >= 0) api.close(fd);
    check("F7 case-only rename", api.rename_noreplace(rootfd, "caseonly.txt", "CaseOnly.txt",
        id.c_str()) == 0 && listed(take(api.scan(rootfd)), "CaseOnly.txt", "file"), got(-1));
    write_file(root + "\\blocked.", "B");
    int b = -1;
    {
      // The identity of the non-portable file, from the scan.
      std::string all = take(api.scan(rootfd));
      size_t at = all.find("{\"path\":\"blocked.\"");
      std::string item = at == std::string::npos ? "" : all.substr(at, all.find('}', at) - at + 1);
      std::string ident = field(item, "volume") + ":" + field(item, "inode");
      b = api.rename_noreplace(rootfd, "blocked.", "unblocked.txt", ident.c_str());
      check("#120 Rename of a non-portable local name to a portable one",
          b == 0 && read_file(root + "\\unblocked.txt") == "B" && !exists(root + "\\blocked."),
          got(b) + " " + item);
      check("#120 Rename never creates a non-portable name",
          refused(api.rename_noreplace(rootfd, "unblocked.txt", "again.", ident.c_str()), 22), got(-1));
    }
    check("F7 rename to the exact same name stays EEXIST",
        refused(api.rename_noreplace(rootfd, "CaseOnly.txt", "CaseOnly.txt", id.c_str()), 17), got(-1));
  }
  {
    // F9: over-long components are ENAMETOOLONG.
    std::string longname(256, 'n');
    check("F9 a 256-unit component is ENAMETOOLONG", refused(api.open_read(rootfd, longname.c_str()), 36) &&
        refused(api.mkdir(rootfd, longname.c_str()), 36), got(-1));
    std::string ok(255, 'n');
    check("F9 a 255-unit component is accepted", api.mkdir(rootfd, ok.c_str()) == 0, got(-1));
  }
  {
    // F10: a read-only mapping does not block the guard and cannot change bytes.
    write_file(stage + "\\romap", "ROMAP");
    HANDLE file = CreateFileW(longpath(stage + "\\romap").c_str(), GENERIC_READ, FILE_SHARE_READ,
        nullptr, OPEN_EXISTING, 0, nullptr);
    HANDLE section = CreateFileMappingW(file, nullptr, PAGE_READONLY, 0, 0, nullptr);
    void* view = section ? MapViewOfFile(section, FILE_MAP_READ, 0, 0, 0) : nullptr;
    if (section) CloseHandle(section);
    if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
    int g = api.guard_open(stagefd, "romap", stamp_at(stagefd, "romap").c_str(), 1);
    check("F10 a read-only mapping does not block the guard", view && g >= 0, got(g));
    if (g >= 0) { api.guard_unlink(g, stagefd, "romap"); api.guard_close(g); }
    if (view) UnmapViewOfFile(view);
  }

  // ---- long paths ----
  {
    std::string relative;
    for (int i = 0; i < 6; i++) {
      relative += (i ? "/" : "") + std::string("deep-directory-component-number-") + std::to_string(i) +
          "-padding-padding";
      api.mkdir(rootfd, relative.c_str());
    }
    std::string file = relative + "/long-path-file.txt";
    write_file(stage + "\\deep", "DEEP");
    int n = api.install(rootfd, file.c_str(), (stage + "\\deep").c_str());
    int fd = api.open_read(rootfd, file.c_str());
    size_t total = root.size() + 1 + file.size();
    check("long path (" + std::to_string(total) + " characters) installs and reads",
        total > 260 && n == 0 && fd >= 0 && read_fd(fd) == "DEEP", got(fd));
    if (fd >= 0) api.close(fd);
    std::string all = take(api.scan(rootfd));
    check("scan includes the long path", listed(all, file, "file"));
  }

  // ---- handle table ----
  {
    int fd = api.open_read(rootfd, "Case.txt");
    check("close", api.close(fd) == 0);
    check("a closed number is EBADF", refused(api.close(fd), 9) && refused(api.open_read(fd, "x"), 9) &&
        take(api.stamp(fd)).empty() && api.error() == 9);
    check("an unknown number is EBADF", refused(api.open_read(99999, "Case.txt"), 9));
    int again = api.open_read(rootfd, "Case.txt");
    check("numbers are not reused", again > fd, std::to_string(again) + " after " + std::to_string(fd));
    api.close(again);
  }
  api.close(stagefd);
  api.close(rootfd);
  check("no handle leaked", api.open_count() == baseline,
      std::to_string(api.open_count()) + " open, baseline " + std::to_string(baseline));
  delete_tree(longpath(work));
  printf("RESULT passed=%d failed=%d skipped=%d\n", passed, failed, skipped);
  return failed ? 1 : 0;
}

}  // namespace

int main(int argc, char** argv) {
  std::string mode = argc > 1 ? argv[1] : "";
  if (mode == "fixture" && argc == 3) return fixture(argv[2]);
  if (mode == "run" && argc == 4) return run(argv[2], argv[3]);
  if (mode == "clean" && argc == 3) { delete_tree(longpath(argv[2])); return exists(argv[2]) ? 1 : 0; }
  if (mode == "hold" && argc == 4) {
    HANDLE h = CreateFileW(longpath(argv[2]).c_str(), GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, 0, nullptr);
    if (h == INVALID_HANDLE_VALUE) return static_cast<int>(GetLastError());
    HANDLE ready = OpenEventW(EVENT_MODIFY_STATE, FALSE, wide(argv[3]).c_str());
    if (ready) SetEvent(ready);
    Sleep(60000);
    return 0;
  }
  if (mode == "probe" && argc == 3) {
    HANDLE h = CreateFileW(longpath(argv[2]).c_str(), GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, 0, nullptr);
    if (h == INVALID_HANDLE_VALUE) return static_cast<int>(GetLastError());
    CloseHandle(h);
    return 0;
  }
  fprintf(stderr, "usage: rootfs_win_test fixture <dir> | run <dir> <dll>\n");
  return 2;
}
