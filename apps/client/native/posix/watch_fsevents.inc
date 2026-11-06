// Included in rootfs.cc on Darwin: FSEvents-based local change notification
// (spec #31 M2, "File Watching"). It serves the same anj_watch_* ABI and the
// same compact records as watch_inotify.inc, so the shared Dart watcher
// (lib/platform/native/local_watcher.dart) runs unchanged on top of it.
//
// FSEvents watches by path prefix: one recursive stream on the root, created
// when the root itself is watched (anj_watch_add with the empty path, or the
// root step of anj_watch_scan). Every other watch is bookkeeping: a
// directory's root-relative path gets a watch descriptor, and an event for
// <dir>/<name> becomes the record (wd of <dir>, mask, 0, <name>) with the
// inotify mask bits the shared records use. Event flags are hints (they
// accumulate under coalescing); every queued path is re-read by stat.
//
//   item event, parent watched     -> record on the parent (create, delete,
//                                     moved-to, modify or attrib; IN_ISDIR
//                                     for directories)
//   item event, parent not watched -> subtree record for the child of the
//                                     nearest watched ancestor (a directory
//                                     the walk has not reached yet)
//   MustScanSubDirs, UserDropped,  -> subtree record for that directory, or
//   KernelDropped, no flag at all     IN_Q_OVERFLOW (a full audit) at the root
//   (kFSEventStreamEventFlagNone)
//   RootChanged, root removed or   -> IN_MOVE_SELF on the root (the root
//   renamed                           self-audit)
//   Mount, Unmount beneath the root -> subtree record for the mount point
//   a path outside the root        -> IN_Q_OVERFLOW
//
// Renames carry no cookie: each side is reported on its own (moved-to) and
// the engine reconciles both by stat, so watches are never remapped here.
#include <CoreServices/CoreServices.h>
#include <dispatch/dispatch.h>
#include <poll.h>
#include <sys/param.h>
#include <time.h>
#include <atomic>
#include <cstdint>
#include <map>
#include <vector>

namespace {
// inotify mask bits used by the shared compact records (inotify(7) values).
constexpr uint32_t kInModify = 0x2, kInAttrib = 0x4, kInMovedTo = 0x80,
    kInCreate = 0x100, kInDelete = 0x200, kInMoveSelf = 0x800,
    kInQueueOverflow = 0x4000, kInIsDir = 0x40000000;
// A wait reports a suspend when CLOCK_MONOTONIC_RAW (which keeps counting
// during sleep) advanced this much more than CLOCK_UPTIME_RAW (which stops).
constexpr long long kSuspendNs = 2000000000LL;
constexpr int kSuspendRecord = -2;
// Records held for the watcher isolate beyond this many bytes are replaced
// by one IN_Q_OVERFLOW record (the engine then audits the whole root).
constexpr size_t kPendingBound = 8u << 20;
constexpr FSEventStreamEventFlags kDropped = kFSEventStreamEventFlagMustScanSubDirs |
    kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped;
constexpr FSEventStreamEventFlags kItem = kFSEventStreamEventFlagItemCreated |
    kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemInodeMetaMod |
    kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified |
    kFSEventStreamEventFlagItemFinderInfoMod | kFSEventStreamEventFlagItemChangeOwner |
    kFSEventStreamEventFlagItemXattrMod | kFSEventStreamEventFlagItemIsFile |
    kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemIsSymlink |
    kFSEventStreamEventFlagItemIsHardlink | kFSEventStreamEventFlagItemIsLastHardlink |
    kFSEventStreamEventFlagItemCloned;

struct Watch {
  int wake[2] = {-1, -1};  // pipe: events pending, a stop, an injection
  std::atomic<long long> acked{0};  // batches the worker has processed
  std::atomic<int> refs{2};
  std::atomic<bool> stopping{false};
  long long offset = 0;  // monotonic_raw - uptime_raw at the previous wait
  double latency = 1.5;  // seconds (anj_watch_latency; the quiet period)
  FSEventStreamRef stream = nullptr;
  dispatch_queue_t queue = nullptr;
  std::mutex lock;  // everything below; the stream's callback takes it too
  std::string prefix;  // the root's path as FSEvents reports it
  std::map<std::string, int> path_wd;
  std::map<int, std::string> wd_path;
  std::map<int, ino_t> wd_ino;
  int next_wd = 1;
  std::vector<uint8_t> pending;  // compact records not yet read
  bool overflowed = false;
  long long skew = 0;  // test seam: added to monotonic_raw readings
  bool fail_set = false;
  std::string fail_prefix;  // test seam: adds at or under it fail (ENOSPC)
};

long long clock_ns(clockid_t id) {
  struct timespec t = {};
  clock_gettime(id, &t);
  return t.tv_sec * 1000000000LL + t.tv_nsec;
}
long long sleep_offset(Watch* w) {
  long long skew;
  { std::lock_guard<std::mutex> hold(w->lock); skew = w->skew; }
  return clock_ns(CLOCK_MONOTONIC_RAW) + skew - clock_ns(CLOCK_UPTIME_RAW);
}
void put32(std::vector<uint8_t>& out, uint32_t v) {
  uint8_t b[4]; memcpy(b, &v, 4); out.insert(out.end(), b, b + 4);
}
// Compact record: int32 wd, uint32 mask, uint32 cookie, uint32 length, name.
void record(std::vector<uint8_t>& out, int wd, uint32_t mask, const std::string& name) {
  put32(out, static_cast<uint32_t>(wd)); put32(out, mask); put32(out, 0);
  put32(out, static_cast<uint32_t>(name.size()));
  out.insert(out.end(), name.begin(), name.end());
}
void notify(Watch* w) {
  char one = 1; ssize_t ignored = write(w->wake[1], &one, 1); (void)ignored;
}
// Under w->lock. Appends a record for the watcher isolate, or past the bound
// replaces everything held with one overflow record.
void emit(Watch* w, int wd, uint32_t mask, const std::string& name) {
  if (w->overflowed) return;
  if (w->pending.size() + 16 + name.size() > kPendingBound) {
    w->pending.clear();
    w->overflowed = true;
    record(w->pending, -1, kInQueueOverflow, "");
    return;
  }
  record(w->pending, wd, mask, name);
}
std::string parent_of(const std::string& path) {
  size_t slash = path.rfind('/');
  return slash == std::string::npos ? std::string() : path.substr(0, slash);
}
std::string leaf_of(const std::string& path) {
  size_t slash = path.rfind('/');
  return slash == std::string::npos ? path : path.substr(slash + 1);
}
// Under w->lock. A subtree record for [path] (non-empty): a directory
// creation on the nearest watched ancestor's child on the way to [path],
// which the shared watcher queues as a subtree audit.
void subtree(Watch* w, const std::string& path) {
  std::string child = path;
  for (std::string a = parent_of(path);; child = a, a = parent_of(a)) {
    auto known = w->path_wd.find(a);
    if (known != w->path_wd.end()) {
      emit(w, known->second, kInCreate | kInIsDir, leaf_of(child));
      return;
    }
    if (a.empty()) break;
  }
  emit(w, -1, kInQueueOverflow, "");  // not even the root is watched
}
void root_self(Watch* w) {
  auto root = w->path_wd.find("");
  if (root == w->path_wd.end()) emit(w, -1, kInQueueOverflow, "");
  else emit(w, root->second, kInMoveSelf, "");
}
// Under w->lock. One FSEvents event: an absolute [path] and its flags.
void translate(Watch* w, const char* path, FSEventStreamEventFlags flags) {
  std::string p(path ? path : "");
  while (p.size() > 1 && p.back() == '/') p.pop_back();
  const std::string& prefix = w->prefix;
  std::string relative;
  bool beneath = false;
  if (p == prefix) {
    beneath = true;
  } else if (prefix == "/") {  // a root at "/": every absolute path is beneath
    beneath = !p.empty() && p[0] == '/';
    relative = beneath ? p.substr(1) : std::string();
  } else if (p.size() > prefix.size() && p.compare(0, prefix.size(), prefix) == 0 &&
      p[prefix.size()] == '/') {
    beneath = true;
    relative = p.substr(prefix.size() + 1);
  }
  if (flags & kFSEventStreamEventFlagRootChanged) { root_self(w); return; }
  if (!beneath) { emit(w, -1, kInQueueOverflow, ""); return; }
  if (flags & kDropped) {
    if (relative.empty()) emit(w, -1, kInQueueOverflow, "");
    else subtree(w, relative);
    return;
  }
  if (flags & (kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)) {
    if (relative.empty()) root_self(w);
    else subtree(w, relative);
    return;
  }
  // No flag at all (kFSEventStreamEventFlagNone, OwnEvent aside): "something
  // changed in this directory", without saying what. Audit it.
  if ((flags & ~kFSEventStreamEventFlagOwnEvent) == 0) {
    if (relative.empty()) emit(w, -1, kInQueueOverflow, "");
    else subtree(w, relative);
    return;
  }
  if (!(flags & kItem)) return;  // EventIdsWrapped, HistoryDone
  if (relative.empty()) {
    // The root's own entry: only its disappearance matters (WatchRoot
    // reports a move of the root itself as RootChanged too).
    if (flags & (kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed)) {
      root_self(w);
    }
    return;
  }
  auto parent = w->path_wd.find(parent_of(relative));
  if (parent == w->path_wd.end()) { subtree(w, relative); return; }
  uint32_t mask = 0;
  if (flags & kFSEventStreamEventFlagItemCreated) mask |= kInCreate;
  if (flags & kFSEventStreamEventFlagItemRemoved) mask |= kInDelete;
  if (flags & kFSEventStreamEventFlagItemRenamed) mask |= kInMovedTo;
  if (flags & (kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemCloned)) {
    mask |= kInModify;
  }
  if (flags & (kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemFinderInfoMod |
      kFSEventStreamEventFlagItemChangeOwner | kFSEventStreamEventFlagItemXattrMod)) {
    mask |= kInAttrib;
  }
  if (!mask) mask = kInModify;  // only type flags: still a candidate
  if (flags & kFSEventStreamEventFlagItemIsDir) mask |= kInIsDir;
  emit(w, parent->second, mask, leaf_of(relative));
}
void on_events(ConstFSEventStreamRef, void* info, size_t count, void* paths,
    const FSEventStreamEventFlags flags[], const FSEventStreamEventId[]) {
  auto* w = static_cast<Watch*>(info);
  auto** names = static_cast<char**>(paths);
  {
    std::lock_guard<std::mutex> hold(w->lock);
    for (size_t i = 0; i < count; i++) translate(w, names[i], flags[i]);
  }
  notify(w);
}
void teardown_stream(void* info) {
  auto* w = static_cast<Watch*>(info);
  FSEventStreamStop(w->stream);
  FSEventStreamInvalidate(w->stream);
  FSEventStreamRelease(w->stream);
  w->stream = nullptr;
}
// Starts the stream on the root open as [dirfd]. Called only by the worker
// (through add_fd), never concurrently with itself.
bool start_stream(Watch* w, int dirfd) {
  char buffer[MAXPATHLEN];
  if (fcntl(dirfd, F_GETPATH, buffer) == -1) return false;
  {
    std::lock_guard<std::mutex> hold(w->lock);
    w->prefix = buffer;
    while (w->prefix.size() > 1 && w->prefix.back() == '/') w->prefix.pop_back();
  }
  CFStringRef path = CFStringCreateWithFileSystemRepresentation(nullptr, buffer);
  if (!path) { errno = ENOMEM; return false; }
  CFArrayRef paths = CFArrayCreate(nullptr, reinterpret_cast<const void**>(&path), 1,
      &kCFTypeArrayCallBacks);
  CFRelease(path);
  if (!paths) { errno = ENOMEM; return false; }
  FSEventStreamContext context = {0, w, nullptr, nullptr, nullptr};
  FSEventStreamRef stream = FSEventStreamCreate(nullptr, on_events, &context, paths,
      kFSEventStreamEventIdSinceNow, w->latency,
      kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer |
      kFSEventStreamCreateFlagWatchRoot);
  CFRelease(paths);
  if (!stream) { errno = EIO; return false; }
  if (!w->queue) w->queue = dispatch_queue_create("cloud.anj.fsevents", DISPATCH_QUEUE_SERIAL);
  FSEventStreamSetDispatchQueue(stream, w->queue);
  if (!FSEventStreamStart(stream)) {
    FSEventStreamInvalidate(stream);
    FSEventStreamRelease(stream);
    errno = EIO;
    return false;
  }
  w->stream = stream;
  return true;
}
bool fails(Watch* w, const std::string& path) {
  std::lock_guard<std::mutex> hold(w->lock);
  if (!w->fail_set) return false;
  const std::string& f = w->fail_prefix;
  return f.empty() || path == f ||
      (path.size() > f.size() && path.compare(0, f.size(), f) == 0 && path[f.size()] == '/');
}
// Watches the directory open as [dirfd] at root-relative [path]: the root
// starts the stream, any other directory is bookkeeping. Re-adding the same
// directory returns its watch descriptor; a different directory at the same
// path gets a new one (as inotify does). Returns -1 with errno.
int add_fd(Watch* w, int dirfd, const std::string& path) {
  if (fails(w, path)) { errno = ENOSPC; return -1; }
  struct stat st = {};
  if (fstat(dirfd, &st) != 0) return -1;
  if (!w->stream) {
    // Bookkeeping needs the stream: the root is always watched first.
    if (!path.empty()) { errno = ENOTCONN; return -1; }
    if (!start_stream(w, dirfd)) return -1;
  }
  std::lock_guard<std::mutex> hold(w->lock);
  auto known = w->path_wd.find(path);
  if (known != w->path_wd.end() && w->wd_ino[known->second] == st.st_ino) return known->second;
  int wd = w->next_wd++;
  w->path_wd[path] = wd;
  w->wd_path[wd] = path;
  w->wd_ino[wd] = st.st_ino;
  return wd;
}
}

extern "C" {
void* anj_watch_open() {
  auto* w = new Watch();
  if (pipe(w->wake) != 0) {
    int saved = errno;
    delete w;
    error_number = saved;
    return nullptr;
  }
  for (int fd : w->wake) {
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
  }
  w->offset = sleep_offset(w);
  error_number = 0;
  return w;
}
// Each of the two owners (worker and watcher isolate) releases once.
void anj_watch_release(void* handle) {
  auto* w = static_cast<Watch*>(handle);
  if (w->refs.fetch_sub(1) == 1) {
    // On the stream's own queue, so no callback runs during or after it.
    if (w->stream) dispatch_sync_f(w->queue, w, teardown_stream);
    if (w->queue) dispatch_release(w->queue);
    close(w->wake[0]); close(w->wake[1]);
    delete w;
  }
}
void anj_watch_stop(void* handle) {
  auto* w = static_cast<Watch*>(handle);
  w->stopping = true;
  notify(w);
}
// The stream's latency, the longest FSEvents holds an event back after the
// first of a burst (NoDefer delivers that one at once). Set before the root
// is watched; the shared watcher passes its quiet period, so a change
// reaches the queue no later than quiet after it happened.
void anj_watch_latency(void* handle, long long microseconds) {
  auto* w = static_cast<Watch*>(handle);
  if (!w->stream && microseconds >= 0) w->latency = static_cast<double>(microseconds) / 1e6;
}
// Watch one directory beneath the root (empty path: the root itself).
// identity receives {reported st_dev, inode} of the watched directory and
// volume (capacity bytes, NUL-terminated) its stable volume key.
int anj_watch_add(void* handle, int root, const char* path, long long* identity,
    char* volume, int capacity) {
  auto* w = static_cast<Watch*>(handle);
  int fd = (path && !*path) ? openat(root, ".", kPathOpen|O_DIRECTORY|O_CLOEXEC)
                            : beneath(root, path, kPathOpen|O_DIRECTORY);
  if (fd < 0) { error_number = errno; return -1; }
  struct stat st = {};
  int wd = fstat(fd, &st) == 0 ? add_fd(w, fd, path ? path : "") : -1;
  int saved = errno;
  if (wd >= 0 && volume && capacity > 0) {
    snprintf(volume, static_cast<size_t>(capacity), "%s", volume_key(fd, st).c_str());
  }
  close(fd);
  if (wd >= 0 && identity) {
    identity[0] = static_cast<long long>(reported_dev(st));
    identity[1] = static_cast<long long>(st.st_ino);
  }
  error_number = wd < 0 ? saved : 0;
  return wd;
}
int anj_watch_remove(void* handle, int wd) {
  auto* w = static_cast<Watch*>(handle);
  std::lock_guard<std::mutex> hold(w->lock);
  auto known = w->wd_path.find(wd);
  if (known == w->wd_path.end()) { error_number = EINVAL; return -1; }
  auto at = w->path_wd.find(known->second);
  if (at != w->path_wd.end() && at->second == wd) w->path_wd.erase(at);
  w->wd_path.erase(known);
  w->wd_ino.erase(wd);
  error_number = 0;
  return 0;
}
// Blocks until records are pending, a stop request or the timeout. Returns
// the number of bytes of compact records written to [buffer] (whole records
// only; the rest stays for the next wait), -2 once stopped, or -1 with an
// error. A sleep since the previous wait adds a record with wd -2.
long anj_watch_wait(void* handle, uint8_t* buffer, long capacity, int timeout_ms) {
  auto* w = static_cast<Watch*>(handle);
  if (w->stopping) return -2;
  bool ready;
  { std::lock_guard<std::mutex> hold(w->lock); ready = !w->pending.empty(); }
  if (!ready) {
    struct pollfd fds[1] = {{w->wake[0], POLLIN, 0}};
    const long long deadline = clock_ns(CLOCK_MONOTONIC) + timeout_ms * 1000000LL;
    int n, left = timeout_ms;
    while ((n = poll(fds, 1, left)) < 0 && errno == EINTR) {
      if (timeout_ms < 0) continue;
      long long rest = deadline - clock_ns(CLOCK_MONOTONIC);
      left = rest <= 0 ? 0 : static_cast<int>((rest + 999999) / 1000000);
    }
    if (n < 0) { error_number = errno; return -1; }
  }
  if (w->stopping) return -2;
  char drain[64];
  while (read(w->wake[0], drain, sizeof(drain)) > 0) {}
  std::vector<uint8_t> out;
  long long offset = sleep_offset(w);
  if (offset - w->offset > kSuspendNs) record(out, kSuspendRecord, 0, "");
  w->offset = offset;
  std::lock_guard<std::mutex> hold(w->lock);
  size_t take = 0;
  while (take + 16 <= w->pending.size()) {
    uint32_t length;
    memcpy(&length, w->pending.data() + take + 12, 4);
    size_t size = 16 + length;
    if (static_cast<long>(out.size() + take + size) > capacity) break;
    take += size;
  }
  if (take == 0 && !w->pending.empty() && out.empty()) { error_number = ENOBUFS; return -1; }
  out.insert(out.end(), w->pending.begin(), w->pending.begin() + static_cast<long>(take));
  w->pending.erase(w->pending.begin(), w->pending.begin() + static_cast<long>(take));
  if (w->pending.empty()) w->overflowed = false;
  else notify(w);
  if (static_cast<long>(out.size()) > capacity) { error_number = ENOBUFS; return -1; }
  memcpy(buffer, out.data(), out.size());
  error_number = 0;
  return static_cast<long>(out.size());
}
// Flow control: the worker counts processed batches; the watcher isolate
// compares with what it sent and coalesces while the worker is behind.
void anj_watch_ack(void* handle) { static_cast<Watch*>(handle)->acked++; }
long long anj_watch_acked(void* handle) { return static_cast<Watch*>(handle)->acked.load(); }
// Test seams. A negative [wd] injects that compact record as on Linux (wd -1
// with IN_Q_OVERFLOW, the synthetic records); a watch descriptor injects an
// FSEvents event with flags [mask] at that directory's path, translated as a
// real event is (MustScanSubDirs, RootChanged, ...). Shift the sleep clock;
// fail adds at or under a relative path with ENOSPC (null clears; empty
// fails every add, the root's stream included).
void anj_watch_debug_inject(void* handle, int wd, unsigned int mask) {
  auto* w = static_cast<Watch*>(handle);
  {
    std::lock_guard<std::mutex> hold(w->lock);
    if (wd < 0) {
      record(w->pending, wd, mask, "");
    } else {
      auto known = w->wd_path.find(wd);
      if (known != w->wd_path.end()) {
        std::string path = known->second.empty() ? w->prefix : w->prefix + "/" + known->second;
        translate(w, path.c_str(), mask);
      }
    }
  }
  notify(w);
}
void anj_watch_debug_clock(void* handle, long long ns) {
  auto* w = static_cast<Watch*>(handle);
  { std::lock_guard<std::mutex> hold(w->lock); w->skew += ns; }
  notify(w);
}
void anj_watch_debug_fail_add(void* handle, const char* prefix) {
  auto* w = static_cast<Watch*>(handle);
  std::lock_guard<std::mutex> hold(w->lock);
  w->fail_set = prefix != nullptr;
  w->fail_prefix = prefix ? prefix : "";
}
}
