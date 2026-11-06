// Android primitives behind the shared POSIX boundary (spec #28 A2,
// decisions #123 and #130 (1)). Android runs a Linux kernel with bionic, so
// everything compat_linux.h provides applies, except the two calls its app
// sandbox refuses (A1 on the emulator):
//
// - openat2 is killed by the app seccomp filter (SIGSYS), so this build never
//   calls it. Confinement is a component-by-component walk: every component
//   is validated (no "", "." or ".."), opened relative to the descriptor of
//   its parent with O_NOFOLLOW, and checked to be a directory before the walk
//   goes on. A walk therefore never leaves the starting descriptor's subtree
//   and never follows a symlink, procfs magic links included (they are
//   symlinks to lookup). Refusals keep the openat2 errno: a symlink in the
//   middle is ELOOP, a non-directory in the middle ENOTDIR, a missing
//   component ENOENT.
// - linkat is refused (EACCES). link_file, the "staged name survives" install
//   used only where the staged copy must survive (restore of an eviction
//   backup, RootTree.installAbsent), copies the staged file into a private
//   temporary beside it and renames that into place with RENAME_NOREPLACE.
//   Ordinary installs rename the staged file itself (anj_restore_owned) and
//   keep no copy (decision #123 (2)).
//
// Included by rootfs.cc for __ANDROID__, or for -DANJ_ANDROID_BOUNDARY (the
// host parity build of test/android_boundary_test.dart).
#ifndef ANJ_COMPAT_ANDROID_H
#define ANJ_COMPAT_ANDROID_H

#define ANJ_COMPAT_ANDROID 1
#include "compat_linux.h"

#include <time.h>
#include <atomic>
#include <memory>
#include <string>
#include <vector>

namespace {
int fail_with(int fd, int error) {
  if (fd >= 0) close(fd);
  errno = error;
  return -1;
}
// One intermediate step: the directory [name] beneath [at], never a symlink.
int step_directory(int at, const char* name) {
  int next = openat(at, name, O_PATH | O_NOFOLLOW | O_CLOEXEC);
  if (next < 0) return -1;
  struct stat st = {};
  if (fstat(next, &st) != 0) { int e = errno; return fail_with(next, e); }
  if (S_ISLNK(st.st_mode)) return fail_with(next, ELOOP);
  if (!S_ISDIR(st.st_mode)) return fail_with(next, ENOTDIR);
  return next;
}
// [path] is already validated (no '/', '.', '..' or empty components).
int open_beneath(int fd, const char* path, int flags, mode_t mode = 0) {
  const std::string s(path);
  int current = fd;
  size_t start = 0;
  while (true) {
    size_t end = s.find('/', start);
    std::string part = s.substr(start, end == std::string::npos ? std::string::npos : end - start);
    if (end == std::string::npos) {
      int out = openat(current, part.c_str(), flags | O_CLOEXEC | O_NOFOLLOW, mode);
      int saved = errno;
      if (current != fd) close(current);
      errno = saved;
      return out;
    }
    int next = step_directory(current, part.c_str());
    int saved = errno;
    if (current != fd) close(current);
    if (next < 0) { errno = saved; return -1; }
    current = next;
    start = end + 1;
  }
}
// An absolute directory path without any symbolic link in it (openat2
// RESOLVE_NO_SYMLINKS). Empty components are skipped; "." and ".." resolve as
// the kernel would, since neither is a symlink. The last component is opened
// as openat2 would, O_DIRECTORY with O_NOFOLLOW (a symlink there: ENOTDIR).
int open_root_directory(const char* path) {
  if (!path || !*path) { errno = ENOENT; return -1; }
  const std::string s(path);
  int current = s[0] == '/' ? open("/", O_PATH | O_DIRECTORY | O_CLOEXEC)
                            : openat(AT_FDCWD, ".", O_PATH | O_DIRECTORY | O_CLOEXEC);
  if (current < 0) return -1;
  std::vector<std::string> parts;
  size_t start = 0;
  while (start <= s.size()) {
    size_t end = s.find('/', start);
    if (end == std::string::npos) end = s.size();
    if (end > start) parts.push_back(s.substr(start, end - start));
    start = end + 1;
  }
  for (size_t i = 0; i + 1 < parts.size(); i++) {
    int next = step_directory(current, parts[i].c_str());
    int saved = errno;
    close(current);
    if (next < 0) { errno = saved; return -1; }
    current = next;
  }
  int fd = openat(current, parts.empty() ? "." : parts.back().c_str(),
                  O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  int saved = errno;
  close(current);
  errno = saved;
  return fd;
}

// Prefix of the private copy link_file makes; lib/core/sync/artifacts.dart
// removes leftovers of an interrupted install at start (decision #130 (4)).
constexpr char kInstallTemp[] = ".anj-install-";
std::atomic<unsigned long> install_counter{0};
bool copy_all(int from, int to) {
  constexpr size_t kChunk = 256 * 1024;
  std::unique_ptr<char[]> buffer(new (std::nothrow) char[kChunk]);
  if (!buffer) { errno = ENOMEM; return false; }
  while (true) {
    ssize_t n;
    do { n = read(from, buffer.get(), kChunk); } while (n < 0 && errno == EINTR);
    if (n < 0) return false;
    if (n == 0) return true;
    for (ssize_t done = 0; done < n;) {
      ssize_t w;
      do { w = write(to, buffer.get() + done, static_cast<size_t>(n - done)); } while (w < 0 && errno == EINTR);
      if (w < 0) return false;
      done += w;
    }
  }
}
// A fresh private file in [dir] named kInstallTemp + pid, counter and clock;
// a stale name (a leftover cleanup could not remove, a reused pid) is skipped,
// never reported as the destination's EEXIST.
int create_install_temp(int dir, std::string& name) {
  for (int attempt = 0; attempt < 32; attempt++) {
    struct timespec t = {};
    clock_gettime(CLOCK_MONOTONIC, &t);
    char buf[96];
    snprintf(buf, sizeof(buf), "%s%d-%lu-%lx", kInstallTemp, static_cast<int>(getpid()),
             install_counter.fetch_add(1), static_cast<unsigned long>(t.tv_nsec ^ (t.tv_sec << 20)));
    int fd = openat(dir, buf, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd >= 0) { name = buf; return fd; }
    if (errno != EEXIST) return -1;
  }
  errno = EAGAIN;
  return -1;
}
// Installs the complete regular file [name] beneath [srcdir] (or a path when
// srcdir is AT_FDCWD) as [leaf] in [dstdir], on the same filesystem, never
// replacing [leaf] (EEXIST). The staged name survives. The copy keeps the
// staged file's permission bits and modification time and is fsynced before
// the rename; a failed install leaves no copy behind.
int link_file(int srcdir, const char* name, int dstdir, const char* leaf) {
  const std::string staged(name ? name : "");
  int parent_dir = srcdir;
  bool own_parent = false;
  std::string base = staged;
  if (srcdir == AT_FDCWD) {
    size_t slash = staged.rfind('/');
    std::string dir = slash == std::string::npos ? "." : (slash == 0 ? "/" : staged.substr(0, slash));
    base = slash == std::string::npos ? staged : staged.substr(slash + 1);
    parent_dir = open(dir.c_str(), O_PATH | O_DIRECTORY | O_CLOEXEC);
    if (parent_dir < 0) return -1;
    own_parent = true;
  }
  auto done = [&](int result, int error) {
    if (own_parent) close(parent_dir);
    errno = error;
    return result;
  };
  if (base.empty() || base == "." || base == ".." || base.find('/') != std::string::npos) return done(-1, EINVAL);
  struct stat existing = {};
  if (fstatat(dstdir, leaf, &existing, AT_SYMLINK_NOFOLLOW) == 0) return done(-1, EEXIST);
  if (errno != ENOENT) return done(-1, errno);
  int source = openat(parent_dir, base.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (source < 0) return done(-1, errno);
  struct stat st = {};
  if (fstat(source, &st) != 0) { int e = errno; close(source); return done(-1, e); }
  if (!S_ISREG(st.st_mode)) { close(source); return done(-1, EPERM); }
  std::string temp;
  int copy = create_install_temp(parent_dir, temp);
  if (copy < 0) { int e = errno; close(source); return done(-1, e); }
  struct timespec times[2] = {st.st_atim, st.st_mtim};
  bool ok = copy_all(source, copy) && fchmod(copy, st.st_mode & 07777) == 0 &&
            futimens(copy, times) == 0 && fsync(copy) == 0;
  int e = errno;
  close(source); close(copy);
  if (ok && rename_noreplace(parent_dir, temp.c_str(), dstdir, leaf) == 0) return done(0, 0);
  if (ok) e = errno;
  unlinkat(parent_dir, temp.c_str(), 0);
  return done(-1, e);
}
}  // namespace

#endif
