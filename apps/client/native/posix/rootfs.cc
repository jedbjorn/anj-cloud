// Descriptor-relative filesystem boundary shared by the POSIX platforms
// (spec #31 S2). Per-OS primitives come from compat_<os>.h (Linux, Darwin),
// and the release guard and watcher from per-OS .inc files. No
// credentials or networking.
#include <dirent.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cerrno>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>

namespace {
// Test seam (anj_debug_volume): shift every reported st_dev, as a reboot
// renumbers anonymous devices, and/or report one fixed stable fsid for every
// filesystem, so a tmpfs fixture behaves like btrfs/ext4.
long long debug_dev_offset = 0;
unsigned long long debug_fsid = 0;
bool debug_force_fsid = false;
}  // namespace

#if defined(__ANDROID__) || defined(ANJ_ANDROID_BOUNDARY)
#include "compat_android.h"
#elif defined(__linux__)
#include "compat_linux.h"
#elif defined(__APPLE__)
#include "compat_darwin.h"
#else
#error "native/posix: no compat_<os>.h for this platform"
#endif

namespace {
thread_local int error_number = 0;
bool valid(const char* path, bool empty = false) {
  if (!path || (!empty && !*path) || *path == '/') return false;
  std::string s(path);
  if (s.find('\0') != std::string::npos) return false;
  size_t start = 0;
  while (start < s.size()) {
    size_t end = s.find('/', start);
    std::string part = s.substr(start, end == std::string::npos ? end : end-start);
    if (part.empty() || part == "." || part == "..") return false;
    if (end == std::string::npos) break;
    start = end+1;
    if (start == s.size()) return false;
  }
  return true;
}
int beneath(int fd, const char* path, int flags) {
  if (!valid(path)) { errno = EINVAL; return -1; }
  return open_beneath(fd, path, flags);
}
int parent(int root, const char* path, std::string& leaf) {
  if (!valid(path)) { errno = EINVAL; return -1; }
  std::string s(path); size_t slash = s.rfind('/');
  if (slash == std::string::npos) { leaf = s; return dup(root); }
  leaf = s.substr(slash+1);
  return beneath(root, s.substr(0, slash).c_str(), O_RDONLY | O_DIRECTORY);
}
unsigned long long reported_dev(const struct stat& st) {
  return static_cast<unsigned long long>(st.st_dev) +
    static_cast<unsigned long long>(debug_dev_offset);
}
// Key of the filesystem holding the open descriptor fd (whose stat is st).
// See stable_volume in compat_<os>.h for what counts as stable.
std::string volume_key(int fd, const struct stat& st, bool* stable = nullptr) {
  std::string key;
  int saved = errno;
  bool ok = stable_volume(fd, key);
  errno = saved;
  if (stable) *stable = ok;
  if (!ok) return std::to_string(reported_dev(st));
  return key;
}
// Key for name beneath dirfd (stat st, not followed). The same st_dev means the
// same superblock, and on btrfs the same subvolume, hence the same f_fsid as
// dirfd; otherwise (a mount on the entry) the entry itself is queried.
std::string volume_key_at(int dirfd, const char* name, const struct stat& st) {
  struct stat dir = {};
  int saved = errno;
  if (fstat(dirfd, &dir) == 0 && dir.st_dev == st.st_dev) {
    errno = saved; return volume_key(dirfd, st);
  }
  int fd = openat(dirfd, name, kPathOpen | O_NOFOLLOW | O_CLOEXEC);
  std::string key = fd >= 0 ? volume_key(fd, st) : std::to_string(reported_dev(st));
  if (fd >= 0) close(fd);
  errno = saved;
  return key;
}
std::string identity_of(const std::string& volume, const struct stat& st) {
  return volume + ":" + std::to_string(st.st_ino);
}
std::string quote(const std::string& s) {
  std::string out = "\"";
  for (unsigned char c : s) {
    if (c == '"' || c == '\\') { out += '\\'; out += c; }
    else if (c < 32) { char buf[7]; snprintf(buf, sizeof(buf), "\\u%04x", c); out += buf; }
    else out += c;
  }
  return out + "\"";
}
// ",\"birth\":<ns>" for a directory whose birth time is trusted (see
// birth_time_at in compat_<os>.h: ext4, f2fs, btrfs and xfs on Linux and
// Android; never on macOS), otherwise empty. Flag SC-074: a folder deleted
// and created again can get its inode number back on ext4 and f2fs; its
// birth time differs. Files carry none, so a scan stats nothing more per
// file.
std::string birth_field(int dirfd, const char* name, const struct stat& st) {
  if (!S_ISDIR(st.st_mode)) return std::string();
  int saved = errno;
  struct timespec birth = {};
  bool ok = birth_time_at(dirfd, name, st, birth);
  errno = saved;
  if (!ok) return std::string();
  return ",\"birth\":" +
    std::to_string(static_cast<long long>(birth.tv_sec)*1000000000LL + birth.tv_nsec);
}
// st_dev -> volume key, valid for one anj_scan call only (device numbers can
// be reused after an unmount, so nothing is cached across calls).
thread_local std::map<dev_t, std::string>* scan_volumes = nullptr;
bool scan(int root, const std::string& path, std::string& json, bool& first) {
  int fd = path.empty() ? openat(root, ".", O_RDONLY|O_DIRECTORY|O_CLOEXEC)
                        : beneath(root, path.c_str(), O_RDONLY|O_DIRECTORY);
  if (fd < 0) return false;
  DIR* dir = fdopendir(fd);
  if (!dir) { close(fd); return false; }
  bool success = true;
  while (true) {
    errno = 0; struct dirent* ent = readdir(dir);
    if (!ent) { if (errno) success = false; break; }
    std::string name(ent->d_name);
    if (name == "." || name == "..") continue;
    struct stat st = {};
    if (fstatat(fd, name.c_str(), &st, AT_SYMLINK_NOFOLLOW) != 0) { success = false; break; }
    std::string relative = path.empty() ? name : path + "/" + name;
    std::string kind = S_ISREG(st.st_mode) ? "file" : S_ISDIR(st.st_mode) ? "directory" : "unsupported";
    auto known = scan_volumes->find(st.st_dev);
    if (known == scan_volumes->end())
      known = scan_volumes->emplace(st.st_dev, volume_key_at(fd, name.c_str(), st)).first;
    const std::string& volume = known->second;
    if (!first) json += ',';
    first = false;
    json += "{\"path\":" + quote(relative) + ",\"kind\":" + quote(kind) +
      ",\"size\":" + std::to_string(st.st_size) + ",\"inode\":" + std::to_string(st.st_ino) +
      ",\"links\":" + std::to_string(static_cast<unsigned long long>(st.st_nlink)) +
      ",\"volume\":" + quote(volume) + ",\"mtime\":" +
      std::to_string(static_cast<long long>(mtim(st).tv_sec)*1000000000LL + mtim(st).tv_nsec) +
      ",\"ctime\":" +
      std::to_string(static_cast<long long>(ctim(st).tv_sec)*1000000000LL + ctim(st).tv_nsec) +
      birth_field(fd, name.c_str(), st) + "}";
    if (kind == "directory" && !scan(root, relative, json, first)) { success = false; break; }
  }
  int saved = errno; closedir(dir); errno = saved;
  return success;
}
}
extern "C" {
int anj_error() { return error_number; }
// Stable symbolic name of an errno value from this boundary (spec #31 S2),
// so shared code never compares platform numbers (EWOULDBLOCK is 11 on
// Linux, 35 on Darwin). Static storage; never freed.
const char* anj_error_name(int code) {
  if (code == 0) return "none";
  if (code == EWOULDBLOCK || code == EAGAIN) return "wouldBlock";
  if (code == EBUSY) return "busy";
  if (code == EEXIST) return "exists";
  if (code == ENOENT) return "notFound";
  if (code == ELOOP) return "loop";
#ifdef ENOTCAPABLE
  if (code == ENOTCAPABLE) return "escape";
#endif
  // A Linux RESOLVE_BENEATH escape reports EXDEV, so it is crossDevice there
  // (unreachable through this ABI: valid() refuses '..' and absolute paths).
  if (code == EXDEV) return "crossDevice";
  if (code == ENOTEMPTY) return "notEmpty";
  if (code == ENOTDIR) return "notDirectory";
  if (code == EISDIR) return "isDirectory";
  if (code == ESTALE) return "stale";
  if (code == EINVAL) return "invalid";
  if (code == EPERM || code == EACCES) return "permission";
  if (code == ENOTSUP || code == EOPNOTSUPP) return "notSupported";
  if (code == ENOSPC) return "noSpace";
  if (code == EMLINK) return "tooManyLinks";
  if (code == ENAMETOOLONG) return "nameTooLong";
  if (code == EIO) return "io";
  return "other";
}
// A directory path through which Dart file I/O reaches entries of the open
// staging directory [fd] (spec #31 S2): Linux names the descriptor through
// procfs; a platform without procfs returns the directory's current path
// after proving that path still opens this same directory. Caller frees with
// anj_free; null with an error.
char* anj_stage_path(int fd) {
  std::string path;
  if (!descriptor_path(fd, path)) { error_number = errno ? errno : ESTALE; return nullptr; }
  error_number = 0;
  return strdup(path.c_str());
}
#if defined(__APPLE__) && defined(ANJ_TEST_SEAMS)
// Test seam (native boundary test builds only, never the shipped dylib):
// F_FULLFSYNC and F_BARRIERFSYNC calls made so far (decision #129).
void anj_debug_syncs(long long* full, long long* barrier) {
  if (full) *full = full_syncs.load();
  if (barrier) *barrier = barrier_syncs.load();
}
#endif
void anj_free(void* value) { free(value); }
int anj_open_root(const char* path) {
  int fd = open_root_directory(path);
  error_number = fd < 0 ? errno : 0; return fd;
}
int anj_check_root(int fd, const char* path) {
  int current = anj_open_root(path); struct stat a = {}, b = {};
  bool ok = current >= 0 && fstat(fd, &a) == 0 && fstat(current, &b) == 0 &&
    a.st_dev == b.st_dev && a.st_ino == b.st_ino;
  if (current >= 0) close(current);
  error_number = ok ? 0 : ESTALE; return ok ? 0 : -1;
}
char* anj_scan(int fd) {
  std::string result = "["; bool first = true;
  std::map<dev_t, std::string> volumes; scan_volumes = &volumes;
  bool ok = scan(fd, "", result, first);
  scan_volumes = nullptr;
  if (!ok) { error_number = errno ? errno : EIO; return nullptr; }
  result += ']'; error_number = 0; return strdup(result.c_str());
}
int anj_open_read(int root, const char* path) {
  int fd = beneath(root, path, O_RDONLY | O_NONBLOCK);
  struct stat st = {};
  if (fd >= 0 && (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode))) { close(fd); fd = -1; errno = EINVAL; }
  error_number = fd < 0 ? errno : 0; return fd;
}
long anj_read(int fd, void* buffer, long length) {
  ssize_t n; do { n = read(fd, buffer, length); } while (n < 0 && errno == EINTR);
  error_number = n < 0 ? errno : 0; return n;
}
char* anj_stamp(int fd) {
  struct stat s = {};
  if (fstat(fd, &s) != 0) { error_number = errno; return nullptr; }
  std::string value = identity_of(volume_key(fd, s), s)+":"+
    std::to_string(s.st_size)+":"+std::to_string(mtim(s).tv_sec)+":"+
    std::to_string(mtim(s).tv_nsec)+":"+std::to_string(ctim(s).tv_sec)+":"+
    std::to_string(ctim(s).tv_nsec);
  return strdup(value.c_str());
}
// Identity of the synchronized root, persisted across restarts:
// {"identity": "<volume>:<ino>[:b<sec>.<nsec>]", "legacy": "<dev>:<ino>",
//  "stable": <volume is an on-disk key>}. On a stable volume the birth time
// is appended where the filesystem reports it (Linux statx: btrfs otime, ext4
// crtime), so a deleted and recreated directory that
// reuses the inode number differs. On other filesystems the identity is
// exactly the previous dev:ino.
char* anj_root_info(int fd) {
  struct stat s = {};
  if (fstat(fd, &s) != 0) { error_number = errno; return nullptr; }
  bool stable = false;
  std::string identity = identity_of(volume_key(fd, s, &stable), s);
  struct timespec birth = {};
  if (stable && birth_time(fd, s, birth)) {
    identity += ":b" + std::to_string(static_cast<long long>(birth.tv_sec)) +
      "." + std::to_string(birth.tv_nsec);
  }
  std::string legacy = std::to_string(reported_dev(s)) + ":" + std::to_string(s.st_ino);
  std::string json = "{\"identity\":" + quote(identity) + ",\"legacy\":" + quote(legacy) +
    ",\"stable\":" + (stable ? "true" : "false") + "}";
  error_number = 0;
  return strdup(json.c_str());
}
// Test seam only: see debug_dev_offset. Production never calls it.
void anj_debug_volume(long long dev_offset, int force_fsid, unsigned long long fsid) {
  debug_dev_offset = dev_offset; debug_force_fsid = force_fsid != 0; debug_fsid = fsid;
}
// Filesystem type (statfs f_type) of the root itself (empty path) or of an
// entry beneath it, resolved through the same descriptor-bound boundary.
long long anj_fs_magic(int root, const char* path) {
  int fd = (path && !*path) ? dup(root) : beneath(root, path, kPathOpen);
  if (fd < 0) { error_number = errno; return -1; }
  struct statfs s = {};
  int result = fstatfs(fd, &s);
  int saved = errno; close(fd);
  if (result != 0) { error_number = saved; return -1; }
  error_number = 0;
  return fs_type(s);
}
int anj_close(int fd) { return close(fd); }
int anj_mkdir(int root, const char* path) {
  std::string leaf; int fd = parent(root, path, leaf); int result = -1;
  if (fd >= 0) {
    result = mkdirat(fd, leaf.c_str(), 0700);
    if (result < 0 && errno == EEXIST) {
      int existing = beneath(root, path, O_RDONLY|O_DIRECTORY);
      if (existing >= 0) { close(existing); result = 0; }
    }
    // barrier: a parent for later installs, whose own sync is full.
    int saved = errno; if (result == 0) barrier_sync(fd); close(fd); errno = saved;
  }
  error_number = result < 0 ? errno : 0; return result;
}
int anj_open_directory(int root, const char* path) {
  int fd = beneath(root, path, O_RDONLY|O_DIRECTORY);
  error_number = fd < 0 ? errno : 0; return fd;
}
int anj_mkdir_exclusive(int root, const char* path) {
  std::string leaf; int fd = parent(root, path, leaf); int result = -1;
  if (fd >= 0) {
    result = mkdirat(fd, leaf.c_str(), 0700);
    int saved = errno;
    // barrier: staged before its no-replace publication (install_directory).
    if (result == 0 && barrier_sync(fd) != 0) { result = -1; saved = errno; }
    close(fd); errno = saved;
  }
  error_number = result < 0 ? errno : 0; return result;
}
// Create an empty private regular file at an absent root-relative path and
// return its descriptor (read-write); an existing name is never replaced
// (O_EXCL, EEXIST). Android's documents provider uses it (spec #28 A5).
int anj_create_file(int root, const char* path) {
  std::string leaf; int fd = parent(root, path, leaf); int result = -1;
  if (fd >= 0) {
    result = openat(fd, leaf.c_str(), O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    int saved = errno;
    if (result >= 0 && barrier_sync(fd) != 0) { saved = errno; close(result); unlinkat(fd, leaf.c_str(), 0); result = -1; }
    close(fd); errno = saved;
  }
  error_number = result < 0 ? errno : 0; return result;
}
// Publish a journaled, private empty directory without accepting an existing
// destination. An ambiguous previous publication remains pending for review.
int anj_install_directory(int root, int stage, const char* staged,
    const char* path, const char* parent_identity, const char* identity) {
  std::string leaf; int fd = parent(root, path, leaf); int result = -1;
  auto matches = [](const std::string& volume, const struct stat& st, const char* expected) {
    return S_ISDIR(st.st_mode) && identity_of(volume, st) == expected;
  };
  if (fd >= 0) {
    struct stat st = {}, source = {}, destination = {};
    if (!valid(staged) || std::string(staged).find('/') != std::string::npos ||
        fstat(fd, &st) != 0 || !matches(volume_key(fd, st), st, parent_identity)) {
      errno = ESTALE;
    } else if (fstatat(fd, leaf.c_str(), &destination, AT_SYMLINK_NOFOLLOW) == 0) {
      // Even a matching dev:inode can have been reused after interruption.
      // Only a rename completed by this invocation grants publication success.
      errno = EEXIST;
    } else if (errno == ENOENT) {
      if (fstatat(stage, staged, &source, AT_SYMLINK_NOFOLLOW) == 0 &&
          matches(volume_key_at(stage, staged, source), source, identity)) {
        result = rename_noreplace(stage, staged, fd, leaf.c_str());
      } else errno = ESTALE;
    }
    int saved = errno;
    if (result == 0) {
      if (fstatat(fd, leaf.c_str(), &destination, AT_SYMLINK_NOFOLLOW) != 0 ||
          !matches(volume_key_at(fd, leaf.c_str(), destination), destination, identity)) {
        result = -1; saved = ESTALE;
      }
      // full: the published parent (commit point); barrier: the staging side.
      else if (full_sync(fd) != 0 || barrier_sync(stage) != 0) { result = -1; saved = errno; }
    }
    close(fd); errno = saved;
  }
  error_number = result < 0 ? errno : 0; return result;
}
// Remove only an empty directory; newly added/unknown children refuse removal.
int anj_rmdir_empty(int root, const char* path, const char* identity) {
  std::string leaf; int fd = parent(root, path, leaf); int result = -1;
  if (fd >= 0) {
    struct stat st = {};
    if (fstatat(fd, leaf.c_str(), &st, AT_SYMLINK_NOFOLLOW) == 0 && S_ISDIR(st.st_mode) &&
        identity_of(volume_key_at(fd, leaf.c_str(), st), st) == identity) {
      result = unlinkat(fd, leaf.c_str(), AT_REMOVEDIR);
    } else errno = ESTALE;
    int saved = errno;
    // full: the removal is the commit point.
    if (result == 0 && full_sync(fd) != 0) { result = -1; saved = errno; }
    close(fd); errno = saved;
  }
  error_number = result < 0 ? errno : 0; return result;
}
// Install an already-complete file into an absent destination; never
// overwrite. The staged name survives (link_file: a hard link, or on
// Android a private copy renamed into place).
int anj_install(int root, const char* relative, const char* staged) {
  std::string leaf; int fd = parent(root, relative, leaf); int result = -1;
  if (fd >= 0) {
    // barrier: the staged bytes, before the new name (Darwin; no-op on Linux).
    result = staged_data_barrier(AT_FDCWD, staged);
    if (result == 0) result = link_file(AT_FDCWD, staged, fd, leaf.c_str());
    // full: the install is the commit point.
    int saved = errno; if (result == 0) full_sync(fd); close(fd); errno = saved;
  }
  error_number = result < 0 ? errno : 0; return result;
}
// Preserve bytes, including concurrent writes through an open descriptor.
// Unconditional deletion is absent; guarded reclamation is defined below.
int anj_quarantine(int root, const char* relative, const char* destination) {
  std::string leaf; int fd = parent(root, relative, leaf); int result = -1;
  if (fd >= 0) {
    struct stat st = {};
    if (fstatat(fd, leaf.c_str(), &st, AT_SYMLINK_NOFOLLOW) == 0 && S_ISREG(st.st_mode)) {
      result = rename_noreplace(fd, leaf.c_str(), AT_FDCWD, destination);
      // barrier: preservation inside a larger step; its record commits full.
      if (result == 0) barrier_sync(fd);
    } else errno = EINVAL;
    int saved = errno; close(fd); errno = saved;
  }
  error_number = result < 0 ? errno : 0; return result;
}
// Rename an item within the root to an absent name (decision #120's Rename
// action; spec #34 P7 moves a file or link holding a top folder's name
// aside). The source must still be the item the caller saw (identity); an
// existing destination is never replaced. A symbolic link is renamed itself.
int anj_rename_noreplace(int root, const char* from, const char* to, const char* identity) {
  std::string from_leaf, to_leaf;
  int source = parent(root, from, from_leaf); int result = -1; int saved = 0;
  if (source >= 0) {
    int target = parent(root, to, to_leaf);
    if (target >= 0) {
      struct stat st = {};
      if (fstatat(source, from_leaf.c_str(), &st, AT_SYMLINK_NOFOLLOW) == 0 &&
          (S_ISREG(st.st_mode) || S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) &&
          identity_of(volume_key_at(source, from_leaf.c_str(), st), st) == identity) {
        result = rename_noreplace(source, from_leaf.c_str(), target, to_leaf.c_str());
      } else errno = ESTALE;
      saved = errno;
      // full: the renamed item is the commit point; barrier: the source side.
      if (result == 0 && (full_sync(target) != 0 || barrier_sync(source) != 0)) { result = -1; saved = errno; }
      close(target);
    } else saved = errno;
    close(source); errno = saved;
  }
  error_number = result < 0 ? errno : 0; return result;
}
int anj_lock(int fd) { int n = flock(fd, LOCK_EX|LOCK_NB); error_number = n < 0 ? errno : 0; return n; }
int anj_chmod_private(const char* path) { int n = chmod(path, 0700); error_number = n < 0 ? errno : 0; return n; }
}

#include "eviction.inc"
#if defined(__linux__)
#include "guard_lease.inc"
#include "watch_inotify.inc"
#elif defined(__APPLE__)
#include "guard_busy.inc"
#include "watch_fsevents.inc"
#endif
#include "watch_walk.inc"
#include "locate.inc"
#include "lifecycle.inc"
