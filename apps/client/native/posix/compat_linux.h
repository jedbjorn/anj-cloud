// Linux primitives behind the shared POSIX boundary (spec #31 S2). Included
// by rootfs.cc only; every function keeps the exact system calls and flags
// the Linux library used before the platform split.
#ifndef ANJ_COMPAT_LINUX_H
#define ANJ_COMPAT_LINUX_H

#include <fcntl.h>
#if !defined(ANJ_COMPAT_ANDROID)
#include <linux/openat2.h>
#endif
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/vfs.h>
#include <unistd.h>
#include <cerrno>
#include <cstdio>
#include <string>

namespace {
// Opens a descriptor for identity, statfs and watch purposes only.
constexpr int kPathOpen = O_PATH;

#if !defined(ANJ_COMPAT_ANDROID)
// Android replaces these two (openat2 is killed by its app seccomp filter)
// and link_file (linkat is refused); see compat_android.h.
// [path] is already validated (no '/', '.', '..' or empty components).
int open_beneath(int fd, const char* path, int flags, mode_t mode = 0) {
  struct open_how how = {};
  how.flags = static_cast<unsigned long long>(flags | O_CLOEXEC | O_NOFOLLOW);
  how.mode = mode;
  how.resolve = RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS;
  return static_cast<int>(syscall(SYS_openat2, fd, path, &how, sizeof(how)));
}
// An absolute directory path without any symbolic link in it.
int open_root_directory(const char* path) {
  struct open_how how = {};
  how.flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW;
  how.resolve = RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS;
  return static_cast<int>(syscall(SYS_openat2, AT_FDCWD, path, &how, sizeof(how)));
}
// Installs the complete file [name] beneath [srcdir] (or a path with
// AT_FDCWD) as [leaf] in [dstdir], never replacing it (EEXIST). The staged
// name survives: a hard link.
int link_file(int srcdir, const char* name, int dstdir, const char* leaf) {
  return linkat(srcdir, name, dstdir, leaf, 0);
}
#endif
// Never replaces an existing destination (EEXIST).
int rename_noreplace(int from, const char* source, int to, const char* destination) {
  return static_cast<int>(syscall(SYS_renameat2, from, source, to, destination,
      RENAME_NOREPLACE));
}
// The two durability strengths of decision #129. Linux fsync is both: it
// returns once the data is on stable storage.
//   barrier_sync: ordering inside an operation (per-file data, a directory
//                 before a no-replace rename, staging bookkeeping);
//   full_sync:    the commit point of an operation (an install or a
//                 removal made visible, an explicit directory sync).
int barrier_sync(int fd) { return fsync(fd); }
int full_sync(int fd) { return fsync(fd); }
// Before a staged file is linked into the root. Nothing on Linux: the bytes
// were already fsynced to stable storage when they were written, and the
// Linux calls stay exactly as before.
int staged_data_barrier(int, const char*) { return 0; }
const struct timespec& mtim(const struct stat& s) { return s.st_mtim; }
const struct timespec& ctim(const struct stat& s) { return s.st_ctim; }
long long fs_type(const struct statfs& s) {
  return static_cast<long long>(static_cast<unsigned long>(s.f_type));
}

// Stable volume key: the token that stands for "which filesystem" wherever an
// identity or stamp is serialized. st_dev is not usable for that on btrfs: each
// subvolume gets an anonymous device number when its root is loaded
// (get_anon_bdev; btrfs_getattr reports root->anon_dev), so it changes across
// reboot and remount. statfs f_fsid is used where the kernel derives it from
// on-disk identity: ext2/3/4 fold the superblock UUID (ext4_statfs:
// uuid_to_fsid(es->s_uuid)); btrfs folds fs_devices->fsid and XORs in the
// subvolume root id (btrfs_statfs). Every other filesystem (tmpfs draws a
// random s_uuid per mount; xfs/f2fs fold the block device number; FUSE, NFS
// and overlay vary) keeps the decimal st_dev exactly as before, so it is never
// worse than the previous identity. Keys never contain ':'.
constexpr long kExt4Magic = 0xEF53;
constexpr long kBtrfsMagic = 0x9123683E;
bool stable_fsid(const struct statfs& s, unsigned long long& out) {
  if (debug_force_fsid) { out = debug_fsid; return out != 0; }
  long type = static_cast<long>(static_cast<unsigned long>(s.f_type));
  if (type != kExt4Magic && type != kBtrfsMagic) return false;
  out = static_cast<unsigned long long>(static_cast<unsigned int>(s.f_fsid.__val[0])) |
    (static_cast<unsigned long long>(static_cast<unsigned int>(s.f_fsid.__val[1])) << 32);
  return out != 0;
}
// The on-disk key of the filesystem holding fd, or false (errno untouched by
// the caller's contract: the caller saves and restores it).
bool stable_volume(int fd, std::string& key) {
  struct statfs s = {}; unsigned long long fsid = 0;
  if (fstatfs(fd, &s) != 0 || !stable_fsid(s, fsid)) return false;
  char buf[20]; snprintf(buf, sizeof(buf), "f%016llx", fsid);
  key = buf;
  return true;
}
// Birth time of the open fd (statx btime where the filesystem reports it).
bool birth_time(int fd, const struct stat& s, struct timespec& out) {
  struct statx x = {};
  if (syscall(SYS_statx, fd, "", AT_EMPTY_PATH | AT_STATX_SYNC_AS_STAT,
              STATX_INO | STATX_BTIME, &x) == 0 &&
      (x.stx_mask & STATX_BTIME) && x.stx_ino == s.st_ino) {
    out.tv_sec = static_cast<time_t>(x.stx_btime.tv_sec);
    out.tv_nsec = static_cast<long>(x.stx_btime.tv_nsec);
    return true;
  }
  return false;
}
// Filesystems whose birth time is kept by the filesystem itself and cannot
// be set through any timestamp call (PR #98 review L6): ext4 and f2fs
// crtime, btrfs otime, xfs crtime. Elsewhere (tmpfs, overlayfs, FUSE, CIFS,
// NFS) it may be synthesized, set by applications, or change under the same
// inode, so no birth time is reported there. The anj_debug_volume seam that
// models a stable filesystem on a tmpfs fixture trusts it too.
constexpr long kF2fsMagic = 0xF2F52010L;
constexpr long kXfsMagic = 0x58465342L;
bool trusted_birth_fs(int dirfd) {
  if (debug_force_fsid) return true;
  struct statfs s = {};
  if (fstatfs(dirfd, &s) != 0) return false;
  long type = static_cast<long>(static_cast<unsigned long>(s.f_type));
  return type == kExt4Magic || type == kBtrfsMagic || type == kF2fsMagic ||
      type == kXfsMagic;
}
// Birth time of the entry [name] of the open directory [dirfd], already
// stat'ed as [s] (statx btime), on a filesystem in trusted_birth_fs only.
// Spec #33 / flag SC-074: ext4 and f2fs give a directory deleted and created
// again the same inode number, so the engine tells such folders apart by it.
bool birth_time_at(int dirfd, const char* name, const struct stat& s,
                   struct timespec& out) {
  if (!trusted_birth_fs(dirfd)) return false;
  struct statx x = {};
  if (syscall(SYS_statx, dirfd, name, AT_SYMLINK_NOFOLLOW | AT_STATX_SYNC_AS_STAT,
              STATX_INO | STATX_BTIME, &x) == 0 &&
      (x.stx_mask & STATX_BTIME) && x.stx_ino == s.st_ino) {
    out.tv_sec = static_cast<time_t>(x.stx_btime.tv_sec);
    out.tv_nsec = static_cast<long>(x.stx_btime.tv_nsec);
    return true;
  }
  return false;
}
// A path Dart file I/O can use for an entry of the open staging directory:
// procfs resolves it through the descriptor itself, whatever its name now.
// [fd] must be an open directory (EBADF / ENOTDIR otherwise), so a closed or
// reused descriptor number never names some other file.
bool descriptor_path(int fd, std::string& out) {
  struct stat st = {};
  if (fstat(fd, &st) != 0) return false;
  if (!S_ISDIR(st.st_mode)) { errno = ENOTDIR; return false; }
  char buf[64]; snprintf(buf, sizeof(buf), "/proc/self/fd/%d", fd);
  out = buf;
  return true;
}
// Decision #137 (2): the names a path's components have on disk. Linux
// lookups are byte-exact, so a path that resolves is spelled as stored.
// (Android's casefolded shared storage has its own, compat_android.h.)
#ifndef ANJ_COMPAT_ANDROID
std::string stored_path(int, const std::string& relative) { return relative; }
#endif
}  // namespace

#endif
