// FSEvents watcher open/close stress under event churn (spec #31 M2, review
// of #62 F2). The stream's context holds no reference of its own, so the
// final anj_watch_release must stop, invalidate and release the stream on
// its serial queue before freeing the Watch. Built with AddressSanitizer by
// tool/macos/watch_stress.sh on mac-test; a use after free in a late
// callback, or a leak of the Watch, fails the run.
//
//   watch_stress_test <scratch directory> <cycles>   (exit 0 = clean)
#include "../rootfs.cc"

#include <atomic>
#include <thread>

int main(int argc, char** argv) {
  if (argc != 3) { fprintf(stderr, "usage: watch_stress_test <dir> <cycles>\n"); return 64; }
  std::string base = argv[1];
  int cycles = atoi(argv[2]);
  mkdir((base + "/root").c_str(), 0700);
  int root = anj_open_root((base + "/root").c_str());
  if (root < 0) { fprintf(stderr, "open root: %d\n", anj_error()); return 1; }
  std::atomic<bool> done{false};
  // Churn: files created, rewritten and removed for the whole run.
  std::thread churn([&] {
    for (long i = 0; !done; i++) {
      std::string path = base + "/root/f" + std::to_string(i % 64);
      int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
      if (fd >= 0) { ssize_t n = write(fd, "x", 1); (void)n; close(fd); }
      if (i % 3 == 0) unlink(path.c_str());
    }
  });
  long records = 0;
  for (int c = 0; c < cycles; c++) {
    void* w = anj_watch_open();
    if (!w) { fprintf(stderr, "open: %d\n", anj_error()); done = true; churn.join(); return 1; }
    anj_watch_latency(w, 1000);
    long long id[2]; char vol[64];
    if (anj_watch_add(w, root, "", id, vol, sizeof(vol)) < 0) {
      fprintf(stderr, "add root: %d\n", anj_error()); done = true; churn.join(); return 1;
    }
    std::vector<uint8_t> buf(80 * 1024);
    // A waiter on another thread, as the watcher isolate is, while the
    // owner stops and releases: both orders of the two releases occur.
    std::thread waiter([&] {
      while (true) {
        long n = anj_watch_wait(w, buf.data(), static_cast<long>(buf.size()), 5);
        if (n == -2 || n == -1) break;
        if (n > 0) records++;
      }
      anj_watch_release(w);
    });
    std::this_thread::sleep_for(std::chrono::milliseconds(c % 7));
    anj_watch_stop(w);
    if (c % 2) waiter.join();
    anj_watch_release(w);
    if (!(c % 2)) waiter.join();
  }
  done = true;
  churn.join();
  close(root);
  printf("{\"cycles\":%d,\"batches\":%ld}\n", cycles, records);
  return 0;
}
