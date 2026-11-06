// A separate flock, never the Manifest's record lock. Keep the returned descriptor
// alive until process exit; do not unlink this inode or unlock a shared handoff.
namespace {
bool instance_file(const struct stat& st) {
  return S_ISREG(st.st_mode) && st.st_uid == geteuid() && st.st_nlink == 1 &&
         (st.st_mode & 077) == 0;
}
bool same_inode(const struct stat& a, const struct stat& b) {
  return a.st_dev == b.st_dev && a.st_ino == b.st_ino;
}
}
extern "C" int anj_profile_lock(const char* path, int inherited) {
  int directory = -1, held = -1, probe = -1;
  auto fail = [&]() {
    int saved = errno;
    if (probe >= 0) close(probe);
    if (held >= 0) close(held);
    if (directory >= 0) close(directory);
    error_number = saved;
    return -1;
  };
  char* canonical = realpath(path, nullptr);
  if (!canonical) { error_number = errno; return -1; }
  bool exact = std::string(canonical) == path;
  free(canonical);
  if (!exact) { errno = EINVAL; return fail(); }
  directory = open(path, O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);
  struct stat dir = {}, now = {}, slot = {}, supplied = {};
  if (directory < 0 || fstat(directory, &dir) || !owned_directory(directory)) {
    errno = EPERM; return fail();
  }
  if (inherited >= 0) {
    int flags = fcntl(inherited, F_GETFL);
    if (flags < 0 || (flags & O_ACCMODE) != O_RDWR ||
        fstat(inherited, &supplied) || !instance_file(supplied)) {
      errno = EINVAL; return fail();
    }
    // CLOEXEC before any subsequent helper can be spawned. Duplication retains
    // the parent's open-file-description lock without an unlock/relock window.
    if (fcntl(inherited, F_SETFD, FD_CLOEXEC) < 0) return fail();
    held = fcntl(inherited, F_DUPFD_CLOEXEC, 3);
    if (held < 0) return fail();
    close(inherited);
  } else {
    held = openat(directory, ".instance.lock", O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC, 0600);
    if (held < 0) return fail();
  }
  if (fstat(held, &supplied) || !instance_file(supplied) ||
      fstatat(directory, ".instance.lock", &slot, AT_SYMLINK_NOFOLLOW) ||
      !same_inode(supplied, slot)) { errno = ESTALE; return fail(); }
  // The number/environment alone grants nothing: acquire or adopt the actual
  // exclusive kernel lock, then prove another open description cannot acquire.
  if (flock(held, LOCK_EX|LOCK_NB) < 0) return fail();
  probe = openat(directory, ".instance.lock", O_RDWR|O_NOFOLLOW|O_CLOEXEC);
  if (probe < 0) return fail();
  struct stat other = {};
  if (fstat(probe, &other) || !same_inode(other, supplied)) {
    errno = ESTALE; return fail();
  }
  if (flock(probe, LOCK_EX|LOCK_NB) == 0) { errno = EINVAL; return fail(); }
  if (errno != EWOULDBLOCK && errno != EAGAIN) return fail();
  close(probe); probe = -1;
  if (stat(path, &now) || !same_inode(dir, now) ||
      fstatat(directory, ".instance.lock", &slot, AT_SYMLINK_NOFOLLOW) ||
      !same_inode(supplied, slot) || !instance_file(slot)) {
    errno = ESTALE; return fail();
  }
  close(directory);
  error_number = 0;
  return held;
}
