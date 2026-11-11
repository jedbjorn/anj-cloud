// Native boundary test and capability probe (spec #31 M1, acceptance rows 3,
// 5 and 7). Compiles rootfs.cc into this program, so it exercises both the
// anj_* C ABI and the per-OS primitives behind it, and writes one JSON row
// per mapping. Runs on Linux and Darwin: tool/native_test.sh.
//
//   boundary_test <scratch directory> > probe.json   (exit 0 = every row passes)
#ifndef ANJ_TEST_SEAMS
#error "build with -DANJ_TEST_SEAMS (tool/native_test.sh)"
#endif
#include "../rootfs.cc"

#include <signal.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <cstdarg>
#include <vector>

namespace probe {
struct Row { std::string name, expect, got, note; bool pass; };
std::vector<Row> rows;
std::string base;  // canonical scratch directory

void row(const std::string& name, bool pass, const std::string& expect,
         const std::string& got, const std::string& note = "") {
  rows.push_back({name, expect, got, note, pass});
}
std::string err(int code) { return anj_error_name(code); }
std::string at(const std::string& rel) { return base + "/" + rel; }
void write_file(const std::string& path, const std::string& bytes) {
  int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
  if (fd >= 0) { ssize_t n = write(fd, bytes.data(), bytes.size()); (void)n; close(fd); }
}
bool exists(const std::string& path) { struct stat s; return lstat(path.c_str(), &s) == 0; }
ino_t inode(const std::string& path) { struct stat s = {}; lstat(path.c_str(), &s); return s.st_ino; }
// Calls [action]; reports "ok" or the symbolic name of anj_error().
template <typename F> std::string outcome(F action) {
  long long n = action();
  return n < 0 ? err(anj_error()) : "ok";
}
std::string field(const std::string& json, const std::string& key) {
  std::string tag = "\"" + key + "\":\"";
  size_t a = json.find(tag);
  if (a == std::string::npos) return "";
  a += tag.size();
  return json.substr(a, json.find('"', a) - a);
}
std::string stamp_of(int dir, const char* name) {
  char* info = anj_info_at(dir, name);
  std::string s = info ? field(info, "stamp") : "";
  anj_free(info);
  return s;
}
struct Syncs { long long full = -1, barrier = -1; };
Syncs syncs() {
  Syncs s;
#ifdef __APPLE__
  anj_debug_syncs(&s.full, &s.barrier);  // ANJ_TEST_SEAMS
#endif
  return s;
}
// The syncs one boundary operation made, against decision #129's class for
// each of its sites: [full] F_FULLFSYNC (commit points) and [barrier]
// F_BARRIERFSYNC. Linux makes full + barrier fsync calls at the same sites.
template <typename F> void durability(const std::string& name, int full, int barrier, F action,
                                      int linux_sites = -1) {
  if (linux_sites < 0) linux_sites = full + barrier;
  std::string expect = std::to_string(full) + " full + " + std::to_string(barrier) + " barrier";
#ifdef __APPLE__
  Syncs before = syncs();
  int result = action();
  Syncs after = syncs();
  long long f = after.full - before.full, b = after.barrier - before.barrier;
  row("durability: " + name, result == 0 && f == full && b == barrier, expect,
      result == 0 ? std::to_string(f) + " full + " + std::to_string(b) + " barrier" : "failed " + err(anj_error()));
#else
  int result = action();
  row("durability: " + name, result == 0, "ok (fsync)", result == 0 ? "ok" : err(anj_error()),
      std::to_string(linux_sites) + " fsync sites; Darwin: " + expect);
#endif
}
std::string json_escape(const std::string& s) { return quote(s); }
}  // namespace probe

using namespace probe;

static void mapping_rows(int root, int stage) {
  // openat2 RESOLVE_BENEATH|NO_SYMLINKS -> O_RESOLVE_BENEATH|O_NOFOLLOW_ANY
  write_file(at("root/a.txt"), "alpha");
  mkdir(at("root/sub").c_str(), 0700);
  write_file(at("root/sub/f"), "f");
  symlink("a.txt", at("root/link").c_str());
  symlink("sub", at("root/dlink").c_str());
  symlink("/etc", at("root/out").c_str());
  row("beneath: plain file opens", outcome([&] { int fd = anj_open_read(root, "sub/f"); if (fd >= 0) close(fd); return fd; }) == "ok", "ok",
      outcome([&] { int fd = anj_open_read(root, "sub/f"); if (fd >= 0) close(fd); return fd; }));
  struct Refusal { const char* path; const char* expect; };
  for (auto r : {Refusal{"../escape", "invalid"}, Refusal{"sub/../a.txt", "invalid"},
                 Refusal{"/etc/hosts", "invalid"}, Refusal{"link", "loop"},
                 Refusal{"dlink/f", "loop"}, Refusal{"out/hosts", "loop"}}) {
    std::string got = outcome([&] { int fd = anj_open_read(root, r.path); if (fd >= 0) close(fd); return fd; });
    row(std::string("beneath refuses '") + r.path + "'", got == r.expect, r.expect, got,
        "anj_open_read; same set as Linux");
  }
  // The primitive itself, below the ABI's own path validation.
  {
    int fd = open_beneath(root, "../root/a.txt", O_RDONLY);
    int e = errno; if (fd >= 0) close(fd);
#ifdef __APPLE__
    row("primitive: O_RESOLVE_BENEATH refuses '..' escape", fd < 0 && e == ENOTCAPABLE, "escape (ENOTCAPABLE)", fd < 0 ? err(e) : "opened");
#else
    row("primitive: RESOLVE_BENEATH refuses '..' escape", fd < 0 && e == EXDEV, "crossDevice (EXDEV)", fd < 0 ? err(e) : "opened");
#endif
    fd = open_beneath(root, "link", O_RDONLY); e = errno; if (fd >= 0) close(fd);
    row("primitive: no symlink as last component", fd < 0 && e == ELOOP, "loop", fd < 0 ? err(e) : "opened");
    fd = open_beneath(root, "dlink/f", O_RDONLY); e = errno; if (fd >= 0) close(fd);
    row("primitive: no symlink in a middle component", fd < 0 && e == ELOOP, "loop", fd < 0 ? err(e) : "opened");
  }
  // anj_open_root: no symlink anywhere in the absolute path.
  symlink(at("root").c_str(), at("rootlink").c_str());
  {
    std::string got = outcome([&] { int fd = anj_open_root(at("rootlink").c_str()); if (fd >= 0) close(fd); return fd; });
    // Linux: O_DIRECTORY|O_NOFOLLOW meets the link itself (ENOTDIR).
    row("open root refuses a symlinked root", got == "loop" || got == "notDirectory", "loop or notDirectory", got);
    got = outcome([&] { int fd = anj_open_root(at("rootlink/sub").c_str()); if (fd >= 0) close(fd); return fd; });
    row("open root refuses a symlink in the prefix", got == "loop", "loop", got);
  }

  // renameat2 RENAME_NOREPLACE -> renameatx_np RENAME_EXCL
  write_file(at("stage/held"), "held");
  write_file(at("root/taken"), "taken");
  {
    std::string got = outcome([&] { return anj_restore_owned(root, "taken", stage, "held"); });
    row("no-replace: restore onto an existing name", got == "exists" && exists(at("stage/held")), "exists, source kept", got);
    int dir = anj_open_directory(root, "sub");
    write_file(at("root/sub/Report.txt"), "r");
    ino_t before = inode(at("root/sub/Report.txt"));
    int n = rename_noreplace(dir, "Report.txt", dir, "report.txt");
    int e = errno;
    bool same = n == 0 && inode(at("root/sub/report.txt")) == before;
    row("no-replace: case-only rename keeps the inode", same, "ok, same inode", n == 0 ? (same ? "ok" : "inode changed") : err(e),
#ifdef __APPLE__
        "APFS folds case; RENAME_EXCL accepts the same inode"
#else
        "byte-exact filesystem: an ordinary rename"
#endif
    );
    n = rename_noreplace(dir, "report.txt", dir, "f"); e = errno;
    row("no-replace: primitive refuses an existing name", n < 0 && e == EEXIST, "exists", n < 0 ? err(e) : "replaced");
#ifdef __APPLE__
    n = rename_noreplace(dir, "../a.txt", dir, "escaped"); e = errno;
    row("primitive: RENAME_RESOLVE_BENEATH refuses '..'", n < 0 && e == ENOTCAPABLE, "escape (ENOTCAPABLE)", n < 0 ? err(e) : "renamed");
#endif
    close(dir);
  }

  // st_mtim/st_ctim -> st_mtimespec/st_ctimespec; stamps carry nanoseconds.
  {
    struct timespec times[2] = {{1700000000, 123456789}, {1700000000, 123456789}};
    utimensat(AT_FDCWD, at("root/a.txt").c_str(), times, 0);
    int fd = anj_open_read(root, "a.txt");
    char* s = fd >= 0 ? anj_stamp(fd) : nullptr;
    std::string value = s ? s : "";
    anj_free(s); if (fd >= 0) close(fd);
    bool has = value.find(":1700000000:123456789:") != std::string::npos;
    row("stamp: mtime seconds and nanoseconds", has, "...:1700000000:123456789:...", value);
  }
  // Volume key and birth time (S2 volume-key source).
  {
    char* info = anj_root_info(root);
    std::string value = info ? info : "";
    anj_free(info);
#ifdef __APPLE__
    bool ok = value.find("\"identity\":\"u") != std::string::npos && value.find(":b") != std::string::npos &&
      value.find("\"stable\":true") != std::string::npos;
    row("root identity: APFS volume UUID, inode and birth time", ok, "u<uuid>:<ino>:b<sec>.<nsec>, stable", value);
#else
    row("root identity", !value.empty(), "identity json", value, "stable only on ext2/3/4 and btrfs");
#endif
  }
  // O_PATH -> O_EVTONLY; statfs f_type.
  {
    long long t = anj_fs_magic(root, "");
    long long f = anj_fs_magic(root, "sub/f");
    struct statfs s = {}; fstatfs(root, &s);
#ifdef __APPLE__
    std::string name = s.f_fstypename;
    row("statfs: root and entry beneath (O_EVTONLY)", t >= 0 && f == t, "same f_type for both", std::to_string(t) + "/" + std::to_string(f), "f_fstypename " + name + "; Darwin f_type is a per-boot index");
#else
    row("statfs: root and entry beneath (O_PATH)", t >= 0 && f == t, "same f_type for both", std::to_string(t) + "/" + std::to_string(f));
#endif
    chmod(at("root/sub/f").c_str(), 0);
    f = anj_fs_magic(root, "sub/f");
    std::string got = f >= 0 ? "ok" : err(anj_error());
    chmod(at("root/sub/f").c_str(), 0600);
#ifdef __APPLE__
    row("statfs: unreadable entry", true, "recorded", got, "O_EVTONLY needs read access, O_PATH does not; fsMagic of entries is used only for other mounts, and never on macOS (no writeback fast path)");
#else
    row("statfs: unreadable entry", f >= 0, "ok", got);
#endif
  }
  // Scan and stat walk (anj_scan, anj_watch_scan without a watch handle).
  {
    char* all = anj_scan(root);
    std::string value = all ? all : "";
    anj_free(all);
    row("scan lists the root without following symlinks", value.find("\"sub/f\"") != std::string::npos &&
        value.find("\"link\",\"kind\":\"unsupported\"") != std::string::npos, "sub/f file, link unsupported",
        value.size() > 160 ? value.substr(0, 160) + "..." : value);
    char* walk = anj_watch_scan(nullptr, root, "sub", 1);
    value = walk ? walk : "";
    anj_free(walk);
    row("stat walk without a watcher", value.find("\"sub/f\"") != std::string::npos && value.find("\"watches\":[]") != std::string::npos,
        "items, no watches", value.size() > 160 ? value.substr(0, 160) + "..." : value);
    // Link count in every listing (spec #33 I1): a file with a second name
    // reports 2 under both names, and 1 again once the second name is gone.
    std::string linked = at("root/sub/f2");
    bool made = link(at("root/sub/f").c_str(), linked.c_str()) == 0;
    auto links_of = [](const std::string& json, const std::string& path) {
      size_t a = json.find("{\"path\":\"" + path + "\"");
      if (a == std::string::npos) return std::string("missing");
      size_t b = json.find("\"links\":", a);
      size_t end = json.find('}', a);
      if (b == std::string::npos || b > end) return std::string("absent");
      b += 8;
      return json.substr(b, json.find_first_of(",}", b) - b);
    };
    all = anj_scan(root); std::string scanned = all ? all : ""; anj_free(all);
    walk = anj_watch_scan(nullptr, root, "sub", 1); std::string walked = walk ? walk : ""; anj_free(walk);
    walk = anj_watch_scan(nullptr, root, "sub/f2", 0); std::string single = walk ? walk : ""; anj_free(walk);
    std::string got = links_of(scanned, "sub/f") + "," + links_of(scanned, "sub/f2") + "," +
        links_of(walked, "sub/f") + "," + links_of(single, "sub/f2");
    unlink(linked.c_str());
    walk = anj_watch_scan(nullptr, root, "sub", 1); walked = walk ? walk : ""; anj_free(walk);
    got += "," + links_of(walked, "sub/f");
    row("scans report the link count", made && got == "2,2,2,2,1", "2,2,2,2,1", got);
    // Birth time of folders (flag SC-074; PR #98 review L5-L7): every
    // listing reports it for a folder on a filesystem whose birth time is
    // trusted (ext4, f2fs, btrfs, xfs; the stable-volume seam models one on
    // a tmpfs fixture), never for a file, never elsewhere, and never on
    // macOS. The expected value comes from statx itself, not from the code
    // under test.
    auto field_of = [](const std::string& json, const std::string& path) {
      size_t a = json.find("{\"path\":\"" + path + "\"");
      if (a == std::string::npos) return std::string("missing");
      size_t end = json.find('}', a);
      size_t b = json.find(",\"birth\":", a);
      if (b == std::string::npos || b > end) return std::string();
      return json.substr(b, end - b);
    };
    auto listed = [&](const char* label, const std::string& want) {
      char* got = anj_scan(root); std::string scanned = got ? got : ""; anj_free(got);
      got = anj_watch_scan(nullptr, root, "", 1); std::string walked = got ? got : ""; anj_free(got);
      got = anj_watch_scan(nullptr, root, "sub", 0); std::string single = got ? got : ""; anj_free(got);
      std::string births = field_of(scanned, "sub") + "|" + field_of(walked, "sub") + "|" +
          field_of(single, "sub");
      std::string files = field_of(scanned, "sub/f") + field_of(walked, "sub/f");
      row(label, births == want + "|" + want + "|" + want && files.empty(),
          want.empty() ? "no birth" : want, births + " files:" + files);
    };
#ifdef __APPLE__
    listed("scans report no folder birth time on macOS", "");
#else
    std::string direct;
    {
      struct statx x = {};
      if (syscall(SYS_statx, AT_FDCWD, at("root/sub").c_str(), AT_SYMLINK_NOFOLLOW,
                  STATX_BTIME, &x) == 0 && (x.stx_mask & STATX_BTIME)) {
        direct = ",\"birth\":" + std::to_string(
            static_cast<long long>(x.stx_btime.tv_sec) * 1000000000LL + x.stx_btime.tv_nsec);
      }
    }
    struct statfs fs = {};
    statfs(at("root").c_str(), &fs);
    long type = static_cast<long>(static_cast<unsigned long>(fs.f_type));
    bool trusted = type == 0xEF53 || type == 0x9123683E || type == 0xF2F52010L ||
        type == 0x58465342L;
    listed("scans report a folder's birth time only on a trusted filesystem",
           trusted ? direct : std::string());
    anj_debug_volume(0, 1, 0x5eed);
    if (direct.empty()) {
      row("scans report a folder's birth time (statx's own value)", true,
          "statx reports none here: not checkable", "not checked");
    } else {
      listed("scans report a folder's birth time (statx's own value)", direct);
    }
    anj_debug_volume(0, 0, 0);
#endif
  }
#ifdef __APPLE__
  // FSEvents watcher (M2): the root's watch starts the stream; an event for
  // a file in a watched directory arrives as a record on that directory, and
  // injected flags map to a subtree record (MustScanSubDirs) and the root
  // self record (RootChanged).
  {
    struct Rec { int wd; uint32_t mask; std::string name; };
    void* w = anj_watch_open();
    std::vector<Rec> seen;
    auto collect = [&](int timeout_ms) {
      std::vector<uint8_t> buf(80 * 1024);
      long n = anj_watch_wait(w, buf.data(), static_cast<long>(buf.size()), timeout_ms);
      for (long at = 0; n > 0 && at + 16 <= n;) {
        Rec r; uint32_t len;
        memcpy(&r.wd, buf.data() + at, 4); memcpy(&r.mask, buf.data() + at + 4, 4);
        memcpy(&len, buf.data() + at + 12, 4);
        r.name.assign(reinterpret_cast<char*>(buf.data()) + at + 16, len);
        seen.push_back(r); at += 16 + len;
      }
      return n;
    };
    if (w) anj_watch_latency(w, 50000);
    long long id[2]; char vol[64];
    int rootwd = w ? anj_watch_add(w, root, "", id, vol, sizeof(vol)) : -1;
    int subwd = w ? anj_watch_add(w, root, "sub", id, vol, sizeof(vol)) : -1;
    row("FSEvents watcher: root watch starts the stream", w && rootwd > 0 && subwd > 0 && subwd != rootwd &&
        anj_watch_add(w, root, "", id, vol, sizeof(vol)) == rootwd, "distinct descriptors, root re-add stable",
        std::to_string(rootwd) + "/" + std::to_string(subwd));
    write_file(at("root/sub/watched.txt"), "x");
    bool event = false;
    for (int i = 0; i < 30 && !event && w; i++) {
      collect(100);
      for (auto& r : seen) event = event || (r.wd == subwd && r.name == "watched.txt" && (r.mask & 0x100));
    }
    row("FSEvents watcher: a new file is a create record on its directory", event, "wd of sub, IN_CREATE, watched.txt",
        std::to_string(seen.size()) + " records");
    seen.clear();
    if (w) anj_watch_debug_inject(w, subwd, kFSEventStreamEventFlagMustScanSubDirs);
    if (w) collect(1000);
    bool scan = false;
    for (auto& r : seen) scan = scan || (r.wd == rootwd && r.name == "sub" && r.mask == (0x100u | 0x40000000u));
    row("FSEvents watcher: MustScanSubDirs is a subtree record", scan, "directory create of sub on the root",
        std::to_string(seen.size()) + " records");
    seen.clear();
    if (w) anj_watch_debug_inject(w, rootwd, kFSEventStreamEventFlagRootChanged);
    if (w) collect(1000);
    bool self = false;
    for (auto& r : seen) self = self || (r.wd == rootwd && r.name.empty() && r.mask == 0x800);
    row("FSEvents watcher: RootChanged is the root self record", self, "IN_MOVE_SELF on the root",
        std::to_string(seen.size()) + " records");
    // kFSEventStreamEventFlagNone: "something changed in this directory".
    seen.clear();
    if (w) anj_watch_debug_inject(w, subwd, kFSEventStreamEventFlagNone);
    if (w) anj_watch_debug_inject(w, rootwd, kFSEventStreamEventFlagNone);
    if (w) collect(1000);
    bool sub_audit = false, root_audit = false;
    for (auto& r : seen) {
      sub_audit = sub_audit || (r.wd == rootwd && r.name == "sub" && r.mask == (0x100u | 0x40000000u));
      root_audit = root_audit || (r.wd == -1 && r.mask == 0x4000u);
    }
    row("FSEvents watcher: a flagless event audits its directory", sub_audit && root_audit,
        "subtree record for sub; IN_Q_OVERFLOW at the root", std::to_string(seen.size()) + " records");
    if (w) { anj_watch_stop(w); anj_watch_release(w); anj_watch_release(w); }
  }
  // A root at "/": event paths are beneath it (translation only, no stream).
  {
    Watch fake;
    fake.prefix = "/";
    fake.path_wd[""] = 1;
    fake.path_wd["Users"] = 2;
    {
      std::lock_guard<std::mutex> hold(fake.lock);
      translate(&fake, "/Users/x.txt", kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile);
    }
    int32_t wd = 0; uint32_t mask = 0, len = 0;
    if (fake.pending.size() >= 16) {
      memcpy(&wd, fake.pending.data(), 4); memcpy(&mask, fake.pending.data() + 4, 4);
      memcpy(&len, fake.pending.data() + 12, 4);
    }
    std::string name = fake.pending.size() >= 16 + len
        ? std::string(reinterpret_cast<char*>(fake.pending.data()) + 16, len) : "";
    row("FSEvents watcher: a root at / sees its events beneath it", wd == 2 && mask == 0x100u && name == "x.txt",
        "create record on Users", std::to_string(wd) + "/" + std::to_string(mask) + "/" + name);
  }
#endif

  // Durability: F_FULLFSYNC at every Linux fsync site.
  durability("anj_mkdir", 0, 1, [&] { return anj_mkdir(root, "d1"); });
  durability("anj_mkdir_exclusive", 0, 1, [&] { return anj_mkdir_exclusive(root, "d2"); });
  {
    int fd = anj_open_directory(root, "d2");
    char* s = anj_stamp(fd); std::string id = s ? std::string(s).substr(0, std::string(s).find(':', std::string(s).find(':') + 1)) : "";
    anj_free(s); close(fd);
    durability("anj_rmdir_empty", 1, 0, [&] { return anj_rmdir_empty(root, "d2", id.c_str()); });
  }
  {
    // Journaled directory publication: staged in stage, installed in root.
    anj_mkdir_exclusive(stage, "pub");
    int pfd = anj_open_directory(stage, "pub");
    char* s = anj_stamp(pfd); std::string full = s ? s : ""; anj_free(s); close(pfd);
    std::string id = full.substr(0, full.find(':', full.find(':') + 1));
    char* r = anj_stamp(root); std::string rs = r ? r : ""; anj_free(r);
    std::string rid = rs.substr(0, rs.find(':', rs.find(':') + 1));
    durability("anj_install_directory", 1, 1, [&] { return anj_install_directory(root, stage, "pub", "published", rid.c_str(), id.c_str()); });
  }
  write_file(at("stage/linked"), "l");
  // The staged-data barrier is Darwin only: Linux makes 1 fsync here.
  durability("anj_install", 1, 1, [&] { return anj_install(root, "linked", at("stage/linked").c_str()); }, 1);
  durability("anj_quarantine", 0, 1, [&] { return anj_quarantine(root, "linked", at("stage/quarantined").c_str()); });
  {
    int fd = -1;
    durability("anj_create_owned", 0, 2, [&] { fd = anj_create_owned(stage, "owned"); return fd < 0 ? -1 : 0; });
    if (fd >= 0) close(fd);
  }
  durability("anj_sync_dir", 1, 0, [&] { return anj_sync_dir(stage); });
  durability("anj_install_owned", 1, 1, [&] { return anj_install_owned(root, "owned-link", stage, "owned"); }, 1);
#ifdef __APPLE__
  // Review F1 (decision #129): the staged file's bytes get a barrier before
  // the new name exists, then the root directory gets the full sync.
  {
    auto order = [&](const std::string& name, const std::string& staged, const std::string& dir, auto install) {
      { std::lock_guard<std::mutex> lock(sync_trace_mutex); sync_trace.clear(); }
      int result = install();
      std::vector<std::pair<char, ino_t>> seen;
      { std::lock_guard<std::mutex> lock(sync_trace_mutex); seen = sync_trace; }
      std::string got;
      for (auto& e : seen) {
        got += std::string(got.empty() ? "" : ", ") + (e.first == 'f' ? "full " : "barrier ") +
          (e.second == inode(staged) ? "staged file" : e.second == inode(dir) ? "root directory" : "other");
      }
      row("durability order: " + name, result == 0 && got == "barrier staged file, full root directory",
          "barrier staged file, full root directory", result == 0 ? got : err(anj_error()));
    };
    write_file(at("stage/order-a"), "a");
    order("anj_install", at("stage/order-a"), at("root"), [&] { return anj_install(root, "order-a", at("stage/order-a").c_str()); });
    int fd = anj_create_owned(stage, "order-b"); if (fd >= 0) close(fd);
    write_file(at("stage/order-b"), "b");
    order("anj_install_owned", at("stage/order-b"), at("root"), [&] { return anj_install_owned(root, "order-b", stage, "order-b"); });
  }
#endif
  durability("anj_preserve_owned", 0, 2, [&] { return anj_preserve_owned(root, "owned-link", stage, "preserved"); });
  {
    write_file(at("root/sub/renamed-from"), "r");
    int fd = anj_open_read(root, "sub/renamed-from");
    char* s = fd >= 0 ? anj_stamp(fd) : nullptr; std::string full = s ? s : ""; anj_free(s); if (fd >= 0) close(fd);
    std::string id = full.substr(0, full.find(':', full.find(':') + 1));
    durability("anj_rename_noreplace", 1, 1, [&] { return anj_rename_noreplace(root, "sub/renamed-from", "renamed-to", id.c_str()); });
  }
  durability("anj_restore_owned", 1, 1, [&] { return anj_restore_owned(root, "restored", stage, "preserved"); });
}

// Release guard (acceptance row 7, native part). Each busy case must refuse
// the release and keep the bytes. Both refuse at guard open (Linux: the
// lease; Darwin: the in-use query); on Darwin a descriptor opened after the
// guard is caught by the final AT_NODELETEBUSY unlink.
struct GuardResult { std::string open, unlink; bool kept; };
static GuardResult release(int stage, const char* name, int links = 1,
                           void (*between)(int guard) = nullptr) {
  GuardResult r;
  std::string expected = stamp_of(stage, name);
  int g = anj_guard_open(stage, name, expected.c_str(), links);
  r.open = g < 0 ? err(anj_error()) : "ok";
  if (g >= 0) {
    if (between) between(g);
    int n = anj_guard_unlink(g, stage, name);
    r.unlink = n < 0 ? err(anj_error()) : "ok";
    anj_guard_close(g);
  } else {
    r.unlink = "-";
  }
  r.kept = exists(at(std::string("stage/") + name));
  return r;
}
static std::string show(const GuardResult& r) {
  return "open " + r.open + ", unlink " + r.unlink + (r.kept ? ", bytes kept" : ", removed");
}
static void refused(const std::string& name, const GuardResult& r) {
  bool pass = r.kept && (r.open != "ok" || r.unlink != "ok");
#ifdef __APPLE__
  pass = pass && r.open == "busy";
  row("guard: " + name, pass, "open busy, bytes kept", show(r), "refused before anything moves, as the Linux lease");
#else
  row("guard: " + name, pass, "refused, bytes kept", show(r), "lease: refused at open");
#endif
}

static void guard_rows(int root, int stage) {
  row("guard kind", std::string(anj_guard_kind()) ==
#ifdef __APPLE__
      "busyAndUnchanged",
#else
      "lease",
#endif
      "per OS", anj_guard_kind());

  write_file(at("stage/clean"), "clean bytes");
  GuardResult clean = release(stage, "clean");
  row("guard: clean release frees the file", clean.open == "ok" && clean.unlink == "ok" && !clean.kept,
      "open ok, unlink ok, removed", show(clean));

  write_file(at("stage/held"), "held bytes");
  int held = open(at("stage/held").c_str(), O_RDONLY | O_CLOEXEC);
  refused("refused while this process holds a descriptor", release(stage, "held"));
  close(held);

  write_file(at("stage/child"), "child bytes");
  int ready[2]; if (pipe(ready) != 0) return;
  pid_t child = fork();
  if (child == 0) {
    int fd = open(at("stage/child").c_str(), O_RDONLY);
    char c = fd >= 0 ? 'y' : 'n'; ssize_t n = write(ready[1], &c, 1); (void)n;
    pause(); _exit(0);
  }
  char c = 0; ssize_t got = read(ready[0], &c, 1); (void)got;
  refused("refused while a child process holds a descriptor", release(stage, "child"));
  kill(child, SIGKILL); waitpid(child, nullptr, 0);
  close(ready[0]); close(ready[1]);

#ifdef __APPLE__
  {
    write_file(at("stage/late"), "late bytes");
    std::string expected = stamp_of(stage, "late");
    int guard = anj_guard_open(stage, "late", expected.c_str(), 1);
    std::string opened = guard >= 0 ? "ok" : err(anj_error());
    int late = open(at("stage/late").c_str(), O_RDONLY | O_CLOEXEC);  // after the guard
    std::string unlinked = guard >= 0 ? outcome([&] { return anj_guard_unlink(guard, stage, "late"); }) : "-";
    if (guard >= 0) anj_guard_close(guard);
    if (late >= 0) close(late);
    bool kept = exists(at("stage/late"));
    row("guard: a descriptor opened after the guard fails the final unlink", opened == "ok" && unlinked == "busy" && kept,
        "open ok, unlink busy, bytes kept", "open " + opened + ", unlink " + unlinked + (kept ? ", bytes kept" : ", removed"));
  }
#endif
  write_file(at("stage/mapped"), "mapped bytes");
  int mfd = open(at("stage/mapped").c_str(), O_RDONLY | O_CLOEXEC);
  void* map = mmap(nullptr, 12, PROT_READ, MAP_SHARED, mfd, 0);
  close(mfd);  // only the mapping remains
  refused("refused while mapped after its descriptor closed", release(stage, "mapped"));
  if (map != MAP_FAILED) munmap(map, 12);
  GuardResult after = release(stage, "mapped");
  row("guard: releases once the mapping is gone", after.unlink == "ok" && !after.kept, "open ok, unlink ok, removed", show(after));

#ifdef __APPLE__
  // (Linux: an open for write blocks until the lease breaks; its lease
  // tests live in test/eviction_test.dart.)
  write_file(at("stage/written"), "written bytes");
  GuardResult written = release(stage, "written", 1, [](int) {
    int fd = open(at("stage/written").c_str(), O_WRONLY | O_APPEND | O_CLOEXEC);
    ssize_t n = write(fd, "!", 1); (void)n; close(fd);
  });
  row("guard: a write between guard and unlink fails the release", written.kept && written.unlink != "ok",
      "unlink refused, bytes kept", show(written));
#endif

  write_file(at("stage/two"), "two links");
  link(at("stage/two").c_str(), at("stage/two-alias").c_str());
  std::string two = stamp_of(stage, "two");
  int g = anj_guard_open(stage, "two", two.c_str(), 1);
  row("guard: one expected link refuses a second link", g < 0 && exists(at("stage/two")), "stale",
      g < 0 ? err(anj_error()) : "opened");
  if (g >= 0) anj_guard_close(g);
  g = anj_guard_open(stage, "two", two.c_str(), 2);
  std::string alias = g >= 0 ? outcome([&] { return anj_guard_unlink(g, stage, "two-alias"); }) : err(anj_error());
  std::string valid_after = g >= 0 ? outcome([&] { return anj_guard_valid(g); }) : "-";
  std::string last = g >= 0 ? outcome([&] { return anj_guard_unlink(g, stage, "two"); }) : "-";
  if (g >= 0) anj_guard_close(g);
  row("guard: aliases, then the last link", alias == "ok" && valid_after == "ok" && last == "ok" && !exists(at("stage/two")),
      "alias ok, still valid, last ok", "alias " + alias + ", valid " + valid_after + ", last " + last);

  write_file(at("root/cloud.txt"), "cloud bytes");
  std::string q = stamp_of(root, "cloud.txt");
  g = anj_guard_open(root, "cloud.txt", q.c_str(), 1);
  std::string moved = g >= 0 ? outcome([&] { return anj_guard_quarantine(g, root, "cloud.txt", stage, "cloud-staged"); }) : err(anj_error());
  std::string still = g >= 0 ? outcome([&] { return anj_guard_valid(g); }) : "-";
  std::string gone = g >= 0 ? outcome([&] { return anj_guard_unlink(g, stage, "cloud-staged"); }) : "-";
  if (g >= 0) anj_guard_close(g);
  row("guard: quarantine from the root, then release", moved == "ok" && still == "ok" && gone == "ok" &&
      !exists(at("root/cloud.txt")) && !exists(at("stage/cloud-staged")),
      "quarantine ok, valid, unlink ok", "quarantine " + moved + ", valid " + still + ", unlink " + gone);
}

#ifdef __APPLE__
// Decision #129 at the guard's own sync sites.
static void guard_sync_rows(int root, int stage) {
  auto delta = [](Syncs a, Syncs b) {
    return std::to_string(b.full - a.full) + " full + " + std::to_string(b.barrier - a.barrier) + " barrier";
  };
  write_file(at("root/sync.txt"), "sync bytes");
  std::string q = stamp_of(root, "sync.txt");
  int g = anj_guard_open(root, "sync.txt", q.c_str(), 1);
  Syncs a = syncs();
  int moved = g >= 0 ? anj_guard_quarantine(g, root, "sync.txt", stage, "sync-staged") : -1;
  Syncs b = syncs();
  row("durability: anj_guard_quarantine", moved == 0 && delta(a, b) == "0 full + 2 barrier", "0 full + 2 barrier", moved == 0 ? delta(a, b) : err(anj_error()));
  int gone = g >= 0 ? anj_guard_unlink(g, stage, "sync-staged") : -1;
  Syncs c = syncs();
  row("durability: anj_guard_unlink (last link)", gone == 0 && delta(b, c) == "1 full + 0 barrier", "1 full + 0 barrier", gone == 0 ? delta(b, c) : err(anj_error()));
  if (g >= 0) anj_guard_close(g);

  write_file(at("stage/sync-two"), "two links");
  link(at("stage/sync-two").c_str(), at("stage/sync-two-alias").c_str());
  std::string two = stamp_of(stage, "sync-two");
  g = anj_guard_open(stage, "sync-two", two.c_str(), 2);
  Syncs d = syncs();
  int alias = g >= 0 ? anj_guard_unlink(g, stage, "sync-two-alias") : -1;
  Syncs e = syncs();
  row("durability: anj_guard_unlink (alias)", alias == 0 && delta(d, e) == "0 full + 1 barrier", "0 full + 1 barrier", alias == 0 ? delta(d, e) : err(anj_error()));
  if (g >= 0) { anj_guard_unlink(g, stage, "sync-two"); anj_guard_close(g); }
}
#endif

static void lock_rows() {
  mkdir(at("profile").c_str(), 0700);
  int first = anj_profile_lock(at("profile").c_str(), -1);
  int second = anj_profile_lock(at("profile").c_str(), -1);
  int code = anj_error();
  row("profile lock: second holder gets wouldBlock", first >= 0 && second < 0 && code == EWOULDBLOCK &&
      err(code) == "wouldBlock", "wouldBlock (EWOULDBLOCK " + std::to_string(EWOULDBLOCK) + ")",
      second < 0 ? err(code) + " (" + std::to_string(code) + ")" : "acquired twice");
  if (first >= 0) close(first);
  if (second >= 0) close(second);
}

static void stage_path_rows(int stage) {
  char* p = anj_stage_path(stage);
  std::string got = p ? p : err(anj_error());
  anj_free(p);
#ifdef __APPLE__
  row("staging path: current path of the descriptor", got == at("stage"), at("stage"), got);
  rename(at("stage").c_str(), at("stage-moved").c_str());
  mkdir(at("stage").c_str(), 0700);
  p = anj_stage_path(stage); got = p ? p : err(anj_error()); anj_free(p);
  row("staging path follows the directory, not its old name", got == at("stage-moved"), at("stage-moved"), got);
  rmdir(at("stage").c_str());
  rename(at("stage-moved").c_str(), at("stage").c_str());
#else
  row("staging path: procfs names the descriptor", got == "/proc/self/fd/" + std::to_string(stage),
      "/proc/self/fd/" + std::to_string(stage), got);
#endif
}

// Spec #33 I3: anj_locate_identity. Linux: unsupported (0) whatever is
// asked. Darwin: a rename and a folder move are found at their new paths
// (1), a move out of the root is outside (2), a file whose only remaining
// link is in staging is staging (3), and a deleted file, another volume and
// malformed identities are not found (4). Every error is uncertain (5,
// decision #143), with anj_error set: a closed root, a short buffer, a
// volume key that fell back to st_dev and does not match.
void locate_rows(int root, int stage) {
  auto identity = [&](const std::string& rel) {
    struct stat st = {};
    lstat(at("root/" + rel).c_str(), &st);
    return volume_key(root, st) + ":" + std::to_string(st.st_ino);
  };
  auto locate = [&](const std::string& id) {
    char out[4096];
    long long links = -1;
    int place = anj_locate_identity(root, stage, id.c_str(), out, sizeof(out), &links);
    return std::to_string(place) + (place == 1 ? " " + std::string(out) : "") +
      " links=" + std::to_string(links);
  };
  mkdir(at("root/loc").c_str(), 0700);
  mkdir(at("root/loc/from").c_str(), 0700);
  write_file(at("root/loc/from/a.txt"), "a");
  std::string file = identity("loc/from/a.txt"), folder = identity("loc/from");
  rename(at("root/loc/from/a.txt").c_str(), at("root/loc/from/b c.txt").c_str());
#ifdef __APPLE__
  row("locate: renamed file", locate(file) == "1 loc/from/b c.txt links=1",
      "1 loc/from/b c.txt links=1", locate(file));
  rename(at("root/loc/from").c_str(), at("root/loc/to").c_str());
  row("locate: moved folder and the file beneath it",
      locate(folder) == "1 loc/to links=1" && locate(file) == "1 loc/to/b c.txt links=1",
      "1 loc/to links=1; 1 loc/to/b c.txt links=1", locate(folder) + "; " + locate(file));
  rename(at("root/loc/to/b c.txt").c_str(), at("outside.txt").c_str());
  row("locate: moved out of the root", locate(file) == "2 links=0", "2 links=0", locate(file));
  unlink(at("outside.txt").c_str());
  row("locate: deleted", locate(file) == "4 links=0", "4 links=0", locate(file));
  write_file(at("stage/down.part"), "d");
  int linked = anj_install(root, "loc/down.txt", at("stage/down.part").c_str());
  std::string down = identity("loc/down.txt");
  rename(at("root/loc/down.txt").c_str(), at("root/loc/to/down.txt").c_str());
  std::string renamed = locate(down);
  row("locate: renamed download (its other link in staging)",
      linked == 0 && (renamed == "1 loc/to/down.txt links=2" || renamed == "3 links=2"),
      "1 loc/to/down.txt links=2 or 3 links=2", renamed,
      "fsgetpath names one link of a hard-linked file");
  unlink(at("root/loc/to/down.txt").c_str());
  row("locate: download deleted (only the staging link left)", locate(down) == "3 links=1",
      "3 links=1", locate(down));
  unlink(at("stage/down.part").c_str());
  std::string volume = file.substr(0, file.rfind(':'));
  std::string bad;
  for (const char* id : {"", "x", ":5", "u:"}) bad += locate(id) + ";";
  bad += locate(volume + ":abc") + ";";
  row("locate: malformed identities are not found", bad == std::string(
      "4 links=0;4 links=0;4 links=0;4 links=0;4 links=0;"), "4 for each", bad);
  // Another volume: proven only by a stable root key (the APFS volume UUID);
  // against the st_dev fallback a mismatch is uncertain (decision #143).
  struct stat root_st = {};
  fstat(root, &root_st);
  bool stable = false;
  volume_key(root, root_st, &stable);
  std::string other = locate("nonsense:12") + ";" +
    locate(volume + "x:" + file.substr(file.rfind(':') + 1)) + ";";
  std::string want_other = stable ? "4 links=0;4 links=0;" : "5 links=0;5 links=0;";
  row("locate: another volume", other == want_other, want_other, other,
      stable ? "stable root key" : "st_dev fallback root key");
  char small[4];
  write_file(at("root/loc/to/long-name.txt"), "l");
  long long links = -1;
  int place = anj_locate_identity(root, stage, identity("loc/to/long-name.txt").c_str(), small,
                                  sizeof(small), &links);
  row("locate: a path longer than the buffer is uncertain",
      place == 5 && small[0] == 0 && links == 0 && anj_error() == ENAMETOOLONG, "5 ENAMETOOLONG",
      std::to_string(place) + " " + err(anj_error()));
  place = anj_locate_identity(-1, -1, file.c_str(), small, sizeof(small), &links);
  row("locate: a closed root is uncertain", place == 5 && anj_error() == EBADF, "5 EBADF",
      std::to_string(place) + " " + err(anj_error()));
  {
    // A sibling whose name extends the root's ("root2"): outside.
    mkdir(at("root2").c_str(), 0700);
    write_file(at("root/loc/to/sib.txt"), "s");
    std::string sib = identity("loc/to/sib.txt");
    rename(at("root/loc/to/sib.txt").c_str(), at("root2/sib.txt").c_str());
    row("locate: moved to a sibling named root2 is outside", locate(sib) == "2 links=0",
        "2 links=0", locate(sib));
    unlink(at("root2/sib.txt").c_str());
    rmdir(at("root2").c_str());
  }
  {
    // Moved out of the root, with a symlink inside the root to where it
    // went: outside, never reached through the link.
    mkdir(at("root/loc/st").c_str(), 0700);
    write_file(at("root/loc/st/s.txt"), "s");
    std::string sfolder = identity("loc/st"), sfile = identity("loc/st/s.txt");
    rename(at("root/loc/st").c_str(), at("st-outside").c_str());
    bool linked_in = symlink(at("st-outside").c_str(), at("root/loc/slink").c_str()) == 0;
    row("locate: moved out, a symlink inside the root to it: outside",
        linked_in && locate(sfolder) == "2 links=0" && locate(sfile) == "2 links=0",
        "2 links=0; 2 links=0",
        locate(sfolder) + "; " + locate(sfile));
    unlink(at("root/loc/slink").c_str());
    unlink(at("st-outside/s.txt").c_str());
    rmdir(at("st-outside").c_str());
  }
  {
    // Case-only and normalization-only renames come back spelled as the
    // directory now lists them.
    auto listed = [&](const std::string& dir, const std::string& prefix) {
      std::string name;
      if (DIR* d = opendir(at(dir).c_str())) {
        while (dirent* e = readdir(d))
          if (std::string(e->d_name).compare(0, prefix.size(), prefix) == 0) name = e->d_name;
        closedir(d);
      }
      return name;
    };
    write_file(at("root/loc/to/case.txt"), "c");
    std::string cased = identity("loc/to/case.txt");
    rename(at("root/loc/to/case.txt").c_str(), at("root/loc/to/CASE.TXT").c_str());
    std::string want = "1 loc/to/" + listed("root/loc/to", "CASE") + " links=1";
    row("locate: a case-only rename", locate(cased) == want && want == "1 loc/to/CASE.TXT links=1",
        want, locate(cased));
    const std::string nfc = "caf\xc3\xa9.txt", nfd = "cafe\xcc\x81.txt";
    write_file(at("root/loc/to/" + nfc), "n");
    std::string normal = identity("loc/to/" + nfc);
    rename(at("root/loc/to/" + nfc).c_str(), at("root/loc/to/" + nfd).c_str());
    want = "1 loc/to/" + listed("root/loc/to", "caf") + " links=1";
    row("locate: an NFC name renamed to its NFD spelling", locate(normal) == want, want,
        locate(normal));
    unlink(at("root/loc/to/CASE.TXT").c_str());
    unlink(at("root/loc/to/" + nfd).c_str());
  }
  {
    // The volume key (anj_debug_volume): a stable key for another volume is
    // not found; a key that fell back to st_dev proves nothing (uncertain).
    write_file(at("root/loc/to/vol.txt"), "v");
    anj_debug_volume(0, 1, 0x1234);
    std::string keyed = identity("loc/to/vol.txt");
    anj_debug_volume(0, 1, 0x5678);
    row("locate: a stable key for another volume is not found", locate(keyed) == "4 links=0",
        "4 links=0", locate(keyed));
    anj_debug_volume(0, 0, 0);
    std::string real = identity("loc/to/vol.txt");
    // stable_volume fails now (an APFS attribute read failing, say): the
    // key falls back to st_dev and no longer matches the recorded one.
    anj_debug_volume(0, 1, 0x1234);
    std::string recorded = identity("loc/to/vol.txt");
    anj_debug_volume(0, 1, 0);
    std::string fallback = locate(recorded);
    int cause = anj_error();
    anj_debug_volume(0, 0, 0);
    row("locate: a mismatch on the st_dev fallback key is uncertain",
        fallback == "5 links=0" && cause == EXDEV, "5 links=0 EXDEV",
        fallback + " " + err(cause));
    row("locate: the stable key again finds it", locate(real) == "1 loc/to/vol.txt links=1",
        "1 loc/to/vol.txt links=1", locate(real));
    unlink(at("root/loc/to/vol.txt").c_str());
  }
#else
  (void)folder;
  row("locate: unsupported on Linux", locate(file) == "0 links=0", "0 links=0", locate(file));
#endif
}

int main(int argc, char** argv) {
  if (argc != 2) { fprintf(stderr, "usage: boundary_test <scratch directory>\n"); return 64; }
  char* real = realpath(argv[1], nullptr);
  if (!real) { perror("realpath"); return 64; }
  base = real; free(real);
  mkdir(at("root").c_str(), 0700);
  mkdir(at("stage").c_str(), 0700);
  int root = anj_open_root(at("root").c_str());
  int stage = anj_open_root(at("stage").c_str());
  row("open root and private staging", root >= 0 && stage >= 0, "ok", root >= 0 && stage >= 0 ? "ok" : err(anj_error()));
  if (root < 0 || stage < 0) return 1;
  mapping_rows(root, stage);
  stage_path_rows(stage);
  guard_rows(root, stage);
#ifdef __APPLE__
  guard_sync_rows(root, stage);
#endif
  lock_rows();
  locate_rows(root, stage);

  int failed = 0;
  std::string out = "{\"platform\":" + json_escape(
#ifdef __APPLE__
      "darwin"
#else
      "linux"
#endif
  ) + ",\"rows\":[";
  for (size_t i = 0; i < rows.size(); i++) {
    const Row& r = rows[i];
    if (!r.pass) failed++;
    out += std::string(i ? "," : "") + "\n {\"row\":" + json_escape(r.name) + ",\"pass\":" + (r.pass ? "true" : "false") +
      ",\"expect\":" + json_escape(r.expect) + ",\"got\":" + json_escape(r.got) +
      (r.note.empty() ? "" : ",\"note\":" + json_escape(r.note)) + "}";
  }
  out += "\n],\"pass\":" + std::to_string(rows.size() - failed) + ",\"fail\":" + std::to_string(failed) + "}\n";
  fputs(out.c_str(), stdout);
  return failed ? 1 : 0;
}
