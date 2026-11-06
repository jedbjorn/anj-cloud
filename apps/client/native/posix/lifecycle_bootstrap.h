#ifndef ANJ_LIFECYCLE_BOOTSTRAP_H
#define ANJ_LIFECYCLE_BOOTSTRAP_H

#include <cerrno>
#include <climits>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>

// Run before GTK, Flutter or plugins can spawn a helper. This only prevents
// inheritance; the full native profile gate later validates ownership and flock.
inline bool anj_profile_argument_cloexec(int argc, char** argv) {
  bool seen = false;
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "--profile-dir") == 0) {
      if (++i >= argc) return false;
    } else if (strcmp(argv[i], "--profile-lock-fd") == 0) {
      if (seen || ++i >= argc) return false;
      seen = true;
      char* end = nullptr;
      errno = 0;
      long value = strtol(argv[i], &end, 10);
      if (errno || end == argv[i] || *end || value < 3 || value > INT_MAX) return false;
      int descriptor = static_cast<int>(value);
      int flags = fcntl(descriptor, F_GETFD);
      if (flags < 0 || fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) < 0) return false;
    }
  }
  return true;
}
#endif
