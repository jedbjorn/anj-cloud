// Included in rootfs.cc after the per-OS watch file (watch_inotify.inc on
// Linux), which defines Watch and add_fd: the stat-only walk behind
// anj_watch_scan, shared by every POSIX platform (spec #31 S2).

#include <vector>

namespace {
bool vanished(int e) { return e == ENOENT || e == ENOTDIR || e == ELOOP; }
// Volume key of an entry, through the per-call st_dev cache of anj_scan /
// anj_watch_scan when one is active (stable form; see volume_key).
std::string walk_volume(int dirfd, const char* name, const struct stat& st) {
  if (!scan_volumes) return volume_key_at(dirfd, name, st);
  auto known = scan_volumes->find(st.st_dev);
  if (known == scan_volumes->end())
    known = scan_volumes->emplace(st.st_dev, volume_key_at(dirfd, name, st)).first;
  return known->second;
}
// One listed item. "links" is st_nlink: the engine pairs a vanished and an
// appeared file by identity only when it is 1 (spec #33, decision #139).
std::string item_json(const std::string& relative, const struct stat& st,
    const std::string& volume, const std::string& birth) {
  std::string kind = S_ISREG(st.st_mode) ? "file" : S_ISDIR(st.st_mode) ? "directory" : "unsupported";
  return "{\"path\":" + quote(relative) + ",\"kind\":" + quote(kind) +
    ",\"size\":" + std::to_string(st.st_size) + ",\"inode\":" + std::to_string(st.st_ino) +
    ",\"links\":" + std::to_string(static_cast<unsigned long long>(st.st_nlink)) +
    ",\"volume\":" + quote(volume) + ",\"mtime\":" +
    std::to_string(static_cast<long long>(mtim(st).tv_sec)*1000000000LL + mtim(st).tv_nsec) +
    ",\"ctime\":" +
    std::to_string(static_cast<long long>(ctim(st).tv_sec)*1000000000LL + ctim(st).tv_nsec) +
    birth + "}";
}
struct WalkOut { std::string items; std::string watches; bool first_item = true; bool first_watch = true; };
void watch_json(WalkOut& out, const std::string& path, int wd, int error, const struct stat& st,
    const std::string& volume) {
  if (!out.first_watch) out.watches += ',';
  out.first_watch = false;
  out.watches += "{\"path\":" + quote(path) + ",\"wd\":" + std::to_string(wd) +
    ",\"error\":" + std::to_string(error) + ",\"volume\":" + quote(volume) +
    ",\"inode\":" + std::to_string(st.st_ino) + "}";
}
// Top-down walk. With a watcher, each directory's watch is added (through an
// path-only descriptor of exactly that directory) before the directory is read,
// so an entry created after the read is reported by an event, and one created
// before it is in the listing. Entries that vanish mid-walk are skipped: their
// removal is reported by the watch that already exists.
bool walk(Watch* w, int root, const std::string& path, WalkOut& out) {
  int handle = path.empty() ? openat(root, ".", kPathOpen|O_DIRECTORY|O_CLOEXEC)
                            : beneath(root, path.c_str(), kPathOpen|O_DIRECTORY);
  if (handle < 0) return !path.empty() && vanished(errno);
  struct stat self = {};
  if (fstat(handle, &self) != 0) { int e = errno; close(handle); errno = e; return false; }
  if (w) {
    int wd = add_fd(w, handle, path);
    int e = wd < 0 ? errno : 0;
    watch_json(out, path, wd, e, self, volume_key(handle, self));
  }
  int fd = openat(handle, ".", O_RDONLY|O_DIRECTORY|O_CLOEXEC);
  int saved = errno; close(handle); errno = saved;
  if (fd < 0) return !path.empty() && vanished(errno);
  DIR* dir = fdopendir(fd);
  if (!dir) { saved = errno; close(fd); errno = saved; return false; }
  bool success = true;
  std::vector<std::string> children;
  while (true) {
    errno = 0; struct dirent* ent = readdir(dir);
    if (!ent) { if (errno) success = false; break; }
    std::string name(ent->d_name);
    if (name == "." || name == "..") continue;
    struct stat st = {};
    if (fstatat(fd, name.c_str(), &st, AT_SYMLINK_NOFOLLOW) != 0) {
      if (errno == ENOENT) continue;
      success = false; break;
    }
    std::string relative = path.empty() ? name : path + "/" + name;
    if (!out.first_item) out.items += ',';
    out.first_item = false;
    out.items += item_json(relative, st, walk_volume(fd, name.c_str(), st),
                           birth_field(fd, name.c_str(), st));
    if (S_ISDIR(st.st_mode)) children.push_back(relative);
  }
  saved = errno; closedir(dir); errno = saved;
  if (!success) return false;
  for (const auto& child : children) if (!walk(w, root, child, out)) return false;
  return true;
}
}

extern "C" {
// Stat-only enumeration of [path] (empty: the root's children) and, when it
// is a directory and [recursive] is set, of everything beneath it, adding
// watches top-down first when [handle] is non-null. A path that does not
// exist (or is no longer reachable beneath the root without symlinks) yields
// no items. Returns {"items":[...],"watches":[...]}.
char* anj_watch_scan(void* handle, int root, const char* path, int recursive) {
  auto* w = static_cast<Watch*>(handle);
  if (!path || (*path && !valid(path))) { error_number = EINVAL; return nullptr; }
  std::string relative(path);
  WalkOut out;
  bool ok = true;
  std::map<dev_t, std::string> volumes; scan_volumes = &volumes;
  if (relative.empty()) {
    ok = walk(w, root, relative, out);
  } else {
    std::string leaf; int parentfd = parent(root, path, leaf);
    struct stat st = {};
    if (parentfd < 0) {
      ok = vanished(errno);
    } else {
      int n = fstatat(parentfd, leaf.c_str(), &st, AT_SYMLINK_NOFOLLOW);
      int saved = errno;
      std::string volume = n == 0 ? volume_key_at(parentfd, leaf.c_str(), st) : std::string();
      std::string birth = n == 0 ? birth_field(parentfd, leaf.c_str(), st) : std::string();
      close(parentfd); errno = saved;
      if (n != 0) {
        ok = vanished(errno);
      } else {
        // Decision #137 (2): on a case- or normalization-insensitive volume
        // the path may resolve to an entry stored under another spelling (a
        // case-only rename). That entry is reported with its stored path,
        // never walked or watched under this one; the caller treats the
        // path as gone (RootTree.scanTree).
        std::string stored = stored_path(root, relative);
        std::string item = item_json(relative, st, volume, birth);
        if (stored != relative) item.insert(item.size() - 1, ",\"stored\":" + quote(stored));
        out.items += item;
        out.first_item = false;
        if (stored == relative && S_ISDIR(st.st_mode) && recursive && !walk(w, root, relative, out)) ok = false;
      }
    }
  }
  scan_volumes = nullptr;
  if (!ok) { error_number = errno ? errno : EIO; return nullptr; }
  error_number = 0;
  return strdup(("{\"items\":[" + out.items + "],\"watches\":[" + out.watches + "]}").c_str());
}
}
