// Included in rootfs.cc: inotify-based local change notification (spec #15).
// Every watch is added to a directory opened beneath the root descriptor and
// named through /proc/self/fd/N, so no user path string is resolved.
#include <poll.h>
#include <sys/eventfd.h>
#include <sys/inotify.h>
#include <atomic>
#include <cstdint>
#include <vector>

namespace {
constexpr uint32_t kWatchMask = IN_CREATE | IN_CLOSE_WRITE | IN_MODIFY | IN_ATTRIB |
    IN_MOVED_FROM | IN_MOVED_TO | IN_DELETE | IN_DELETE_SELF | IN_MOVE_SELF |
    IN_EXCL_UNLINK | IN_ONLYDIR;
// A wait reports a suspend when CLOCK_BOOTTIME advanced this much more than
// CLOCK_MONOTONIC (which stops during suspend) since the previous wait.
constexpr long long kSuspendNs = 2000000000LL;
// Synthetic record identifiers (never valid inotify watch descriptors).
constexpr int kSuspendRecord = -2;
constexpr int kMountRecord = -5;

struct Watch {
  int inotify = -1;
  int wake = -1;
  int mounts = -1;  // /proc/self/mountinfo: POLLPRI when the mount table changes
  std::atomic<long long> acked{0};  // batches the worker has processed
  std::atomic<int> refs{2};
  std::atomic<bool> stopping{false};
  long long offset = 0;  // boottime - monotonic at the previous wait
  std::mutex debug;
  std::vector<std::pair<int, uint32_t>> injected;
  long long skew = 0;  // test seam: added to boottime readings
  bool fail_set = false;
  std::string fail_prefix;  // test seam: adds at or under it fail (ENOSPC)
};

long long clock_ns(clockid_t id) {
  struct timespec t = {};
  clock_gettime(id, &t);
  return t.tv_sec * 1000000000LL + t.tv_nsec;
}
long long boot_offset(Watch* w) {
  long long skew;
  { std::lock_guard<std::mutex> lock(w->debug); skew = w->skew; }
  return clock_ns(CLOCK_BOOTTIME) + skew - clock_ns(CLOCK_MONOTONIC);
}
void put32(std::vector<uint8_t>& out, uint32_t v) {
  uint8_t b[4]; memcpy(b, &v, 4); out.insert(out.end(), b, b + 4);
}
// Compact record: int32 wd, uint32 mask, uint32 cookie, uint32 length, name.
void record(std::vector<uint8_t>& out, int wd, uint32_t mask, uint32_t cookie,
    const char* name, uint32_t length) {
  put32(out, static_cast<uint32_t>(wd)); put32(out, mask); put32(out, cookie);
  put32(out, length);
  out.insert(out.end(), name, name + length);
}
bool fails(Watch* w, const std::string& path) {
  std::lock_guard<std::mutex> lock(w->debug);
  if (!w->fail_set) return false;
  const std::string& f = w->fail_prefix;
  return f.empty() || path == f ||
      (path.size() > f.size() && path.compare(0, f.size(), f) == 0 && path[f.size()] == '/');
}
// Adds a watch to the directory open as [dirfd] (any open mode, including
// O_PATH). Returns the watch descriptor or -1 with errno.
int add_fd(Watch* w, int dirfd, const std::string& path) {
  if (fails(w, path)) { errno = ENOSPC; return -1; }
  char proc[64];
  snprintf(proc, sizeof(proc), "/proc/self/fd/%d", dirfd);
  return inotify_add_watch(w->inotify, proc, kWatchMask);
}
}

extern "C" {
void* anj_watch_open() {
  auto* w = new Watch();
  w->inotify = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
  if (w->inotify >= 0) w->wake = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
  if (w->inotify < 0 || w->wake < 0) {
    int saved = errno;
    if (w->inotify >= 0) close(w->inotify);
    delete w;
    error_number = saved;
    return nullptr;
  }
  w->offset = boot_offset(w);
  // Optional: without it, mounts appearing beneath the root are found by the
  // periodic stat audit.
  w->mounts = open("/proc/self/mountinfo", O_RDONLY | O_CLOEXEC);
  error_number = 0;
  return w;
}
// Each of the two owners (worker and watcher isolate) releases once.
void anj_watch_release(void* handle) {
  auto* w = static_cast<Watch*>(handle);
  if (w->refs.fetch_sub(1) == 1) {
    close(w->inotify); close(w->wake);
    if (w->mounts >= 0) close(w->mounts);
    delete w;
  }
}
void anj_watch_stop(void* handle) {
  auto* w = static_cast<Watch*>(handle);
  w->stopping = true;
  uint64_t one = 1;
  ssize_t ignored = write(w->wake, &one, sizeof(one)); (void)ignored;
}
// The FSEvents stream's latency on Darwin (watch_fsevents.inc). inotify has
// none: every event is read as it arrives, and the shared watcher's queue
// applies the quiet period.
void anj_watch_latency(void*, long long) {}
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
  int n = inotify_rm_watch(static_cast<Watch*>(handle)->inotify, wd);
  error_number = n < 0 ? errno : 0; return n;
}
// Blocks in poll() until events, a stop request or the timeout. Returns the
// number of bytes of compact records written to [buffer], -2 once stopped,
// or -1 with an error. A suspend since the previous wait adds a record with
// wd -2; IN_Q_OVERFLOW arrives as the kernel's record (wd -1).
long anj_watch_wait(void* handle, uint8_t* buffer, long capacity, int timeout_ms) {
  auto* w = static_cast<Watch*>(handle);
  if (w->stopping) return -2;
  struct pollfd fds[3] = {{w->inotify, POLLIN, 0}, {w->wake, POLLIN, 0},
                          {w->mounts, POLLPRI, 0}};
  // A signal (e.g. the VM's sampling profiler) interrupts poll(); retry with
  // the time left, so a wait never outlives its timeout.
  const long long deadline = clock_ns(CLOCK_MONOTONIC) + timeout_ms * 1000000LL;
  int n, left = timeout_ms;
  while ((n = poll(fds, w->mounts >= 0 ? 3 : 2, left)) < 0 && errno == EINTR) {
    if (timeout_ms < 0) continue;
    long long rest = deadline - clock_ns(CLOCK_MONOTONIC);
    left = rest <= 0 ? 0 : static_cast<int>((rest + 999999) / 1000000);
  }
  if (n < 0) { error_number = errno; return -1; }
  if (w->stopping) return -2;
  std::vector<uint8_t> out;
  if (fds[1].revents & POLLIN) {
    uint64_t value; ssize_t ignored = read(w->wake, &value, sizeof(value)); (void)ignored;
  }
  {
    std::lock_guard<std::mutex> lock(w->debug);
    for (auto& v : w->injected) record(out, v.first, v.second, 0, "", 0);
    w->injected.clear();
  }
  if (w->mounts >= 0 && (fds[2].revents & (POLLPRI | POLLERR))) {
    record(out, kMountRecord, 0, 0, "", 0);
  }
  long long offset = boot_offset(w);
  if (offset - w->offset > kSuspendNs) record(out, kSuspendRecord, 0, 0, "", 0);
  w->offset = offset;
  // Compact records are never larger than the kernel's, so reading at most
  // the remaining capacity always fits.
  long room = capacity - static_cast<long>(out.size());
  if ((fds[0].revents & POLLIN) && room >= static_cast<long>(sizeof(struct inotify_event) + NAME_MAX + 1)) {
    std::vector<char> raw(static_cast<size_t>(room < 65536 ? room : 65536));
    ssize_t got;
    do { got = read(w->inotify, raw.data(), raw.size()); } while (got < 0 && errno == EINTR);
    if (got < 0 && errno != EAGAIN) { error_number = errno; return -1; }
    for (ssize_t at = 0; got > 0 && at < got;) {
      auto* event = reinterpret_cast<struct inotify_event*>(raw.data() + at);
      record(out, event->wd, event->mask, event->cookie, event->name,
          event->len ? static_cast<uint32_t>(strnlen(event->name, event->len)) : 0);
      at += sizeof(struct inotify_event) + event->len;
    }
  }
  if (static_cast<long>(out.size()) > capacity) { error_number = ENOBUFS; return -1; }
  memcpy(buffer, out.data(), out.size());
  error_number = 0;
  return static_cast<long>(out.size());
}
// Flow control: the worker counts processed batches; the watcher isolate
// compares with what it sent and coalesces while the worker is behind.
void anj_watch_ack(void* handle) { static_cast<Watch*>(handle)->acked++; }
long long anj_watch_acked(void* handle) { return static_cast<Watch*>(handle)->acked.load(); }
// Test seams. Inject a record (e.g. wd -1 with IN_Q_OVERFLOW) and wake the
// waiter; shift CLOCK_BOOTTIME to model a suspend; fail adds at or under a
// relative path with ENOSPC (null clears; empty fails every add).
void anj_watch_debug_inject(void* handle, int wd, unsigned int mask) {
  auto* w = static_cast<Watch*>(handle);
  { std::lock_guard<std::mutex> lock(w->debug); w->injected.emplace_back(wd, mask); }
  uint64_t one = 1; ssize_t ignored = write(w->wake, &one, sizeof(one)); (void)ignored;
}
void anj_watch_debug_clock(void* handle, long long ns) {
  auto* w = static_cast<Watch*>(handle);
  { std::lock_guard<std::mutex> lock(w->debug); w->skew += ns; }
  uint64_t one = 1; ssize_t ignored = write(w->wake, &one, sizeof(one)); (void)ignored;
}
void anj_watch_debug_fail_add(void* handle, const char* prefix) {
  auto* w = static_cast<Watch*>(handle);
  std::lock_guard<std::mutex> lock(w->debug);
  w->fail_set = prefix != nullptr;
  w->fail_prefix = prefix ? prefix : "";
}
}
