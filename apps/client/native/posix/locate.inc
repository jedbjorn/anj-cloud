// Identity lookup (spec #33 I3, decision #140): the current path of the item
// whose local identity is `<volume>:<inode>`, the same form the scans report.
// Included by rootfs.cc.
//
//   int anj_locate_identity(int root, int stage, const char* identity,
//                           char* out, int cap, long long* links)
//
// Returns one of the kLocate* values below and never fails otherwise.
// Certain answers: kLocateInside (re-opened through the boundary as the same
// dev:inode), kLocateOutside (the volume names it elsewhere) and
// kLocateNotFound (no such inode on the root's volume, a stable key for
// another volume, or a malformed identity). Every error is
// kLocateUncertain, never folded into another answer: an fsgetpath failure
// other than "no such inode", allocation, the st_dev volume-key fallback on
// a mismatch, a path that changed between fsgetpath and the re-open, a
// buffer too small. error_number then holds the errno. [out] receives the
// root-relative path (kLocateInside only; NUL-terminated, at most cap - 1
// bytes) and [links] the item's link count (1 for a folder) for
// kLocateInside and kLocateStaging. [stage] is the private staging
// directory, or -1.
//
// macOS: fsgetpath on the root's volume (one bounded kernel call), compared
// against fsgetpath of the root's own inode, so both paths share one naming
// (firmlinks included); a path beneath the root is then re-opened through the
// boundary (beneath, no symlink anywhere) and must be the same dev:inode.
// fsgetpath names one link of a hard-linked file. A download's staging copy
// is such a link (anj_install links it into the root), so a path inside the
// staging directory says nothing about where the file's other link is:
// kLocateStaging, which the engine treats as uncertain.
//
// Linux and Android: no lookup (decision #140 holds the removal instead);
// always kLocateUnsupported.
namespace {
constexpr int kLocateUnsupported = 0;
constexpr int kLocateInside = 1;
constexpr int kLocateOutside = 2;
constexpr int kLocateStaging = 3;
constexpr int kLocateNotFound = 4;
constexpr int kLocateUncertain = 5;

#if defined(__APPLE__)
// The path of inode [ino] on the volume [fsid]: kLocateInside when found,
// kLocateNotFound when the volume has no such inode (ENOENT, ESTALE), and
// kLocateUncertain on any other failure (errno kept). The kernel refuses a
// buffer larger than a page (EINVAL), so a smaller one is tried after.
int path_by_id(fsid_t fsid, unsigned long long ino, std::string& out) {
  for (size_t size : {static_cast<size_t>(4096), static_cast<size_t>(MAXPATHLEN)}) {
    std::vector<char> buf(size, '\0');
    errno = 0;
    ssize_t n = fsgetpath(buf.data(), buf.size(), &fsid, ino);
    if (n > 0) {
      out.assign(buf.data(), strnlen(buf.data(), buf.size()));
      if (!out.empty() && out[0] == '/') return kLocateInside;
      errno = EINVAL;
      return kLocateUncertain;
    }
    if (errno == ENOENT || errno == ESTALE) return kLocateNotFound;
    if (errno != EINVAL) return kLocateUncertain;
  }
  return kLocateUncertain;
}
// [path] beneath [prefix] (an absolute directory path): the remainder.
bool strip_prefix(const std::string& path, const std::string& prefix, std::string& rest) {
  std::string with_slash = prefix == "/" ? prefix : prefix + "/";
  if (path.size() <= with_slash.size() || path.compare(0, with_slash.size(), with_slash) != 0)
    return false;
  rest = path.substr(with_slash.size());
  return true;
}
// [relative] beneath [dir], opened without following any symlink, is still
// the regular file or folder [dev]:[ino]. Its link count goes to [links].
bool same_item(int dir, const std::string& relative, dev_t dev, unsigned long long ino,
               long long& links) {
  int fd = beneath(dir, relative.c_str(), kPathOpen);
  if (fd < 0) return false;
  struct stat st = {};
  bool ok = fstat(fd, &st) == 0 && st.st_dev == dev &&
    static_cast<unsigned long long>(st.st_ino) == ino &&
    (S_ISREG(st.st_mode) || S_ISDIR(st.st_mode));
  close(fd);
  if (ok) links = S_ISDIR(st.st_mode) ? 1 : static_cast<long long>(st.st_nlink);
  return ok;
}
int locate_identity(int root, int stage, const char* identity, char* out, int cap,
                    long long& links) {
  if (!out || cap <= 1) { errno = EINVAL; return kLocateUncertain; }
  if (!identity) return kLocateNotFound;
  std::string id(identity);
  size_t colon = id.rfind(':');
  if (colon == std::string::npos || colon == 0 || colon + 1 >= id.size()) return kLocateNotFound;
  std::string digits = id.substr(colon + 1);
  if (digits.find_first_not_of("0123456789") != std::string::npos) return kLocateNotFound;
  errno = 0;
  unsigned long long ino = strtoull(digits.c_str(), nullptr, 10);
  if (errno != 0 || ino == 0) return kLocateNotFound;
  struct stat rs = {};
  if (fstat(root, &rs) != 0) return kLocateUncertain;
  if (!S_ISDIR(rs.st_mode)) { errno = ENOTDIR; return kLocateUncertain; }
  // Another volume is never this root's item (a move across volumes is a
  // delete), but only a stable key (the APFS volume UUID) proves it: the
  // st_dev fallback is assigned at mount time, so a mismatch is uncertain.
  bool stable = false;
  if (volume_key(root, rs, &stable) != id.substr(0, colon)) {
    if (stable) return kLocateNotFound;
    errno = EXDEV;
    return kLocateUncertain;
  }
  struct statfs fs = {};
  if (fstatfs(root, &fs) != 0) return kLocateUncertain;
  std::string found, root_path;
  int item = path_by_id(fs.f_fsid, ino, found);
  if (item != kLocateInside) return item;
  if (path_by_id(fs.f_fsid, static_cast<unsigned long long>(rs.st_ino), root_path) !=
      kLocateInside) {
    if (errno == 0) errno = ESTALE;
    return kLocateUncertain;
  }
  std::string relative;
  if (strip_prefix(found, root_path, relative)) {
    if (!valid(relative.c_str())) { errno = EINVAL; return kLocateUncertain; }
    if (relative.size() + 1 > static_cast<size_t>(cap)) { errno = ENAMETOOLONG; return kLocateUncertain; }
    // Changed between fsgetpath and the re-open (a rename, a symlink put in
    // its way): uncertain, never outside or not found.
    if (!same_item(root, relative, rs.st_dev, ino, links)) {
      if (errno == 0) errno = ESTALE;
      return kLocateUncertain;
    }
    memcpy(out, relative.c_str(), relative.size() + 1);
    return kLocateInside;
  }
  if (stage < 0) return kLocateOutside;
  struct stat ss = {};
  if (fstat(stage, &ss) != 0) return kLocateUncertain;
  if (ss.st_dev != rs.st_dev) return kLocateOutside;  // Staging is elsewhere.
  std::string stage_path, staged;
  if (path_by_id(fs.f_fsid, static_cast<unsigned long long>(ss.st_ino), stage_path) !=
      kLocateInside) {
    if (errno == 0) errno = ESTALE;
    return kLocateUncertain;
  }
  if (!strip_prefix(found, stage_path, staged)) return kLocateOutside;
  if (!valid(staged.c_str()) || !same_item(stage, staged, ss.st_dev, ino, links)) {
    if (errno == 0) errno = ESTALE;
    return kLocateUncertain;
  }
  return kLocateStaging;
}
#endif
}  // namespace

extern "C" int anj_locate_identity(int root, int stage, const char* identity, char* out,
                                   int cap, long long* links) {
  long long count = 0;
  if (out && cap > 0) out[0] = '\0';
  int cause = 0;
#if defined(__APPLE__)
  int saved = errno;
  int result = kLocateUncertain;
  try {
    errno = 0;
    result = locate_identity(root, stage, identity, out, cap, count);
  } catch (...) {
    result = kLocateUncertain;  // std::bad_alloc: uncertain, never a crash
    errno = ENOMEM;
  }
  if (result == kLocateUncertain) cause = errno ? errno : EIO;
  errno = saved;
  if (result != kLocateInside && out && cap > 0) out[0] = '\0';
#else
  (void)root; (void)stage; (void)identity;
  int result = kLocateUnsupported;
#endif
  if (links) *links = (result == kLocateInside || result == kLocateStaging) ? count : 0;
  error_number = cause;
  return result;
}
