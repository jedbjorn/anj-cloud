// Darwin primitives behind the shared POSIX boundary (spec #31 S2, M1).
// Included by rootfs.cc only. Each function is the macOS form of the Linux
// call in compat_linux.h with the same refusals; the mapping and its
// verification on mac-test are in spec #31 "Native Boundary" and doc #14.
#ifndef ANJ_COMPAT_DARWIN_H
#define ANJ_COMPAT_DARWIN_H

#include <fcntl.h>
#include <stdio.h>
#include <sys/attr.h>
#include <sys/fsgetpath.h>
#include <sys/mount.h>
#include <sys/param.h>
#include <sys/stat.h>
#include <unistd.h>
#include <atomic>
#include <cerrno>
#include <mutex>
#include <utility>
#include <vector>
#include <cstdio>
#include <cstring>
#include <string>

namespace {
// O_PATH has no Darwin equivalent; O_EVTONLY opens for identity, statfs and
// event purposes without keeping the volume busy.
constexpr int kPathOpen = O_EVTONLY;

// openat2 RESOLVE_BENEATH|RESOLVE_NO_SYMLINKS: O_RESOLVE_BENEATH refuses an
// escape (ENOTCAPABLE) and O_NOFOLLOW_ANY refuses a symlink anywhere in the
// path, the last component included (ELOOP). O_NOFOLLOW must not be added:
// combined with O_NOFOLLOW_ANY it fails with EINVAL (doc #14 probe).
int open_beneath(int fd, const char* path, int flags, mode_t mode = 0) {
  return openat(fd, path, flags | O_CLOEXEC | O_RESOLVE_BENEATH | O_NOFOLLOW_ANY, mode);
}
// An absolute directory path without any symbolic link in it.
int open_root_directory(const char* path) {
  return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY);
}
// renameat2 RENAME_NOREPLACE: RENAME_EXCL (EEXIST on an existing name).
// Between two descriptor-relative names, resolution also stays beneath each
// directory and follows no symlink. A rename to an absolute AT_FDCWD path
// (anj_quarantine's private staging destination) resolves it as Linux does.
int rename_noreplace(int from, const char* source, int to, const char* destination) {
  unsigned int flags = RENAME_EXCL;
  if (from != AT_FDCWD && to != AT_FDCWD) flags |= RENAME_RESOLVE_BENEATH | RENAME_NOFOLLOW_ANY;
  return renameatx_np(from, source, to, destination, flags);
}
// Installs [name] as [leaf] without replacing it; the staged name survives
// (a hard link, as before).
int link_file(int srcdir, const char* name, int dstdir, const char* leaf) {
  return linkat(srcdir, name, dstdir, leaf, 0);
}
// Decision #129. fsync on Darwin leaves data in the drive's cache.
//   barrier_sync: F_BARRIERFSYNC orders the write: it reaches stable storage
//                 no later than any write issued after it (per-file data, a
//                 directory before a no-replace rename, staging bookkeeping).
//   full_sync:    F_FULLFSYNC flushes the drive's cache, so every earlier
//                 (barriered) write is durable too: the commit point of an
//                 install or a removal, and an explicit directory sync. The
//                 manifest's SQLite commits are full as well (fullfsync
//                 pragmas). About 5 ms against 0.3 ms on mac-test (PR #59).
// A filesystem that refuses the fcntl (ENOTSUP, EINVAL, ENOTTY) gets plain
// fsync instead, as SQLite does; any other failure is reported.
#ifdef ANJ_TEST_SEAMS
// Native boundary test only (tool/native_test.sh builds with
// -DANJ_TEST_SEAMS; the shipped dylib has none of this): counts and the
// order of syncs, as (kind, inode of the synced file).
std::atomic<long long> full_syncs{0};
std::atomic<long long> barrier_syncs{0};
std::mutex sync_trace_mutex;
std::vector<std::pair<char, ino_t>> sync_trace;
void trace_sync(char kind, int fd) {
  (kind == 'f' ? full_syncs : barrier_syncs)++;
  struct stat st = {};
  int saved = errno;
  fstat(fd, &st);
  errno = saved;
  std::lock_guard<std::mutex> lock(sync_trace_mutex);
  sync_trace.emplace_back(kind, st.st_ino);
}
#else
void trace_sync(char, int) {}
#endif
int sync_with(int fd, int command) {
  if (fcntl(fd, command) != -1) return 0;
  if (errno == ENOTSUP || errno == EINVAL || errno == ENOTTY) return fsync(fd);
  return -1;
}
int barrier_sync(int fd) { trace_sync('b', fd); return sync_with(fd, F_BARRIERFSYNC); }
int full_sync(int fd) { trace_sync('f', fd); return sync_with(fd, F_FULLFSYNC); }
// Before a staged file is linked into the root (anj_install,
// anj_install_owned): Dart wrote its bytes with a plain fsync, which on
// Darwin leaves them in the drive's cache, so a barrier puts them ahead of
// the new name.
int staged_data_barrier(int dirfd, const char* name) {
  int fd = openat(dirfd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) return -1;
  int n = barrier_sync(fd);
  int saved = errno; close(fd); errno = saved;
  return n;
}
const struct timespec& mtim(const struct stat& s) { return s.st_mtimespec; }
const struct timespec& ctim(const struct stat& s) { return s.st_ctimespec; }
// Darwin f_type is an index assigned per boot, never a Linux magic number,
// so it matches none of the shared magic sets (trusted, silent).
long long fs_type(const struct statfs& s) { return static_cast<long long>(s.f_type); }

// Stable volume key on APFS: "u" + the volume UUID (ATTR_VOL_UUID, 32 hex
// digits). Darwin's f_fsid and st_dev are assigned at mount time, so every
// other filesystem keeps the decimal st_dev, as on Linux. Keys never
// contain ':'.
bool stable_volume(int fd, std::string& key) {
  struct statfs s = {};
  if (fstatfs(fd, &s) != 0) return false;
  if (debug_force_fsid) {
    if (debug_fsid == 0) return false;
    char buf[20]; snprintf(buf, sizeof(buf), "f%016llx", debug_fsid);
    key = buf;
    return true;
  }
  if (strcmp(s.f_fstypename, "apfs") != 0) return false;
  struct attrlist request = {};
  request.bitmapcount = ATTR_BIT_MAP_COUNT;
  request.volattr = ATTR_VOL_INFO | ATTR_VOL_UUID;
  struct __attribute__((packed)) { uint32_t length; uuid_t uuid; } reply = {};
  if (fgetattrlist(fd, &request, &reply, sizeof(reply), 0) != 0) return false;
  bool zero = true;
  char hex[33];
  for (int i = 0; i < 16; i++) {
    zero = zero && reply.uuid[i] == 0;
    snprintf(hex + 2 * i, 3, "%02x", reply.uuid[i]);
  }
  if (zero) return false;
  key = std::string("u") + hex;
  return true;
}
// APFS records a birth time for every inode.
bool birth_time(int, const struct stat& s, struct timespec& out) {
  out = s.st_birthtimespec;
  return out.tv_sec != 0 || out.tv_nsec != 0;
}
// No birth time for listed folders on macOS (PR #98 review L5): APFS never
// reuses inode numbers, so it adds nothing there, and utimes() with an
// earlier mtime, setattrlist, SetFile -d, rsync -N or a restore into the
// folder can change it, which would read as a folder replaced.
bool birth_time_at(int, const char*, const struct stat&, struct timespec&) {
  return false;
}
// No procfs: the staging directory's current path (F_GETPATH), accepted only
// if that path, opened again without following any symlink, is the same
// directory as fd. Weaker than Linux's /proc/self/fd/N, which stays bound to
// the descriptor: a same-user process could swap the private (0700)
// directory between this check and the caller's use of the path.
bool descriptor_path(int fd, std::string& out) {
  char buf[MAXPATHLEN];
  if (fcntl(fd, F_GETPATH, buf) == -1) return false;
  int check = open(buf, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY);
  if (check < 0) return false;
  struct stat a = {}, b = {};
  bool same = fstat(fd, &a) == 0 && fstat(check, &b) == 0 &&
    a.st_dev == b.st_dev && a.st_ino == b.st_ino;
  close(check);
  if (!same) { errno = ESTALE; return false; }
  out = buf;
  return true;
}
// Decision #137 (2): APFS (case- and normalization-insensitive by default)
// resolves "Foo" to a file stored as "foo", so a path that resolves may be
// spelled differently on disk. Returns the path with each component as the
// filesystem stores it (ATTR_CMN_NAME, the stored name, looked up beneath
// [root] without following symlinks); the path as given when a lookup fails
// (the caller's own lookup then reports the error).
std::string stored_path(int root, const std::string& relative) {
  std::string out;
  int dir = dup(root);
  size_t start = 0;
  while (dir >= 0 && start <= relative.size()) {
    size_t end = relative.find('/', start);
    std::string part = relative.substr(start, end == std::string::npos ? std::string::npos : end - start);
    struct attrlist request = {};
    request.bitmapcount = ATTR_BIT_MAP_COUNT;
    request.commonattr = ATTR_CMN_NAME;
    struct __attribute__((packed)) {
      uint32_t length;
      attrreference_t name;
      char buffer[MAXPATHLEN];
    } reply = {};
    if (getattrlistat(dir, part.c_str(), &request, &reply, sizeof(reply), FSOPT_NOFOLLOW) != 0) {
      close(dir);
      return relative;
    }
    const char* stored = reinterpret_cast<const char*>(&reply.name) + reply.name.attr_dataoffset;
    size_t room = sizeof(reply) - (static_cast<size_t>(stored - reinterpret_cast<const char*>(&reply)));
    out += std::string(stored, strnlen(stored, room));
    if (end == std::string::npos) break;
    out += '/';
    int next = open_beneath(dir, part.c_str(), O_RDONLY | O_DIRECTORY);
    close(dir);
    dir = next;
    start = end + 1;
  }
  if (dir < 0) return relative;
  close(dir);
  return out;
}
}  // namespace

#endif
