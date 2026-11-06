// Included in rootfs.cc after eviction.inc on Darwin: the release guard as a
// busy-and-unchanged check (spec #31 "Release Guard", decision #42). Same C
// ABI as guard_lease.inc.
//
// F_SETLEASE does not exist on Darwin (EPERM in every mode, doc #14), so
// nothing stops a new open while the guard is held. Instead:
//   1. anj_guard_open opens the file O_EVTONLY (O_UNIQUE too when it must
//      have one link) and records its full stamp: inode, links, size, mtime,
//      ctime, birth time. An O_EVTONLY descriptor reads like O_RDONLY but
//      never counts as a user of the file, so the guard itself is never
//      "busy" (measured on mac-test, 2026-11-04).
//   2. Before anything moves (open, quarantine) it asks the kernel which
//      processes hold the file open or mapped (proc_listpidspath, event-only
//      descriptors excluded) and refuses with EBUSY if any does, as the
//      Linux lease refuses before anything moves. Only processes this user
//      may inspect are listed, so this is the early refusal, not the proof.
//   3. Every step requires the recorded stamp, through the descriptor and by
//      name. Only this guard's own renames and link removals may move ctime
//      and the link count; size, mtime and birth time never.
//   4. Removing the last link re-stats the name, requires the identical
//      stamp and unlinks with AT_NODELETEBUSY: any descriptor still open
//      anywhere (this process or another, inherited or not) or a mapping,
//      even after its descriptor closed, fails it with EBUSY.
// WEAKER THAN LINUX: a process that opens, reads and closes the file inside
// the window is not seen. Reads are harmless (the remote copy was verified);
// a write moves mtime and ctime and fails the release, as does any open
// descriptor or mapping at the final unlink. The engine keeps the bytes and
// retries on a later pass.
#include <libproc.h>
#include <time.h>

namespace {
struct BusyGuard {
  dev_t device; ino_t inode; nlink_t links; off_t size;
  struct timespec mtime, ctime, birth;
  long long deadline_ns;
};
std::map<int, BusyGuard> guards;
std::mutex guard_mutex;
long long now_ns() { struct timespec t = {}; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec*1000000000LL+t.tv_nsec; }
bool same_time(const struct timespec& a, const struct timespec& b) {
  return a.tv_sec == b.tv_sec && a.tv_nsec == b.tv_nsec;
}
bool unchanged(const BusyGuard& g, const struct stat& s) {
  return S_ISREG(s.st_mode) && s.st_dev == g.device && s.st_ino == g.inode &&
    s.st_nlink == g.links && s.st_size == g.size && same_time(mtim(s), g.mtime) &&
    same_time(ctim(s), g.ctime) && same_time(s.st_birthtimespec, g.birth);
}
// The descriptor still holds the guarded file, unchanged, inside the 30 s
// window (the same bound as the Linux lease).
bool guarded(int fd) {
  auto found = guards.find(fd);
  if (found == guards.end() || now_ns() > found->second.deadline_ns) { errno = EAGAIN; return false; }
  struct stat s = {};
  if (fstat(fd,&s) != 0) return false;
  if (!unchanged(found->second, s)) { errno = ESTALE; return false; }
  return true;
}
// [name] in [parentfd] is the guarded file, unchanged.
bool matches_guard(int guard, int parentfd, const char* name) {
  if (!guarded(guard)) return false;
  struct stat s = {};
  if (fstatat(parentfd,name,&s,AT_SYMLINK_NOFOLLOW) != 0) return false;
  if (!unchanged(guards.at(guard), s)) { errno = ESTALE; return false; }
  return true;
}
// After this guard's own rename or link removal: only ctime and the link
// count (now [links]) may have moved.
bool absorb_own_change(int guard, nlink_t links) {
  BusyGuard& g = guards.at(guard);
  struct stat s = {};
  if (fstat(guard,&s) != 0) return false;
  if (!S_ISREG(s.st_mode) || s.st_dev != g.device || s.st_ino != g.inode || s.st_nlink != links ||
      s.st_size != g.size || !same_time(mtim(s), g.mtime) || !same_time(s.st_birthtimespec, g.birth)) {
    errno = ESTALE; return false;
  }
  g.ctime = ctim(s); g.links = links;
  return true;
}
// Whether any process this user may inspect holds the file of [fd] open or
// mapped, apart from event-only descriptors such as the guard's own (EBUSY).
// A failed query refuses nothing: the final AT_NODELETEBUSY unlink decides.
bool in_use(int fd) {
  char path[MAXPATHLEN];
  if (fcntl(fd, F_GETPATH, path) == -1) return false;
  int pids[1024];
  int bytes = proc_listpidspath(PROC_ALL_PIDS, 0, path, PROC_LISTPIDSPATH_EXCLUDE_EVTONLY,
      pids, sizeof(pids));
  if (bytes > 0) { errno = EBUSY; return true; }
  return false;
}
}
extern "C" {
// The guard this library implements (ReleaseGuardStrength in Dart).
const char* anj_guard_kind() { return "busyAndUnchanged"; }
int anj_guard_open(int directory,const char* path,const char* expected,int links) {
  std::lock_guard<std::mutex> lock(guard_mutex);
  if (links < 1) { error_number=EINVAL; return -1; }
  int fd=beneath(directory,path,O_EVTONLY|O_NONBLOCK|(links==1?O_UNIQUE:0)); struct stat s={};
  if(fd<0) {
    // O_UNIQUE refuses a second link with ENOTCAPABLE; Linux reports a link
    // count mismatch as a stale stamp.
    error_number=(errno==ENOTCAPABLE && links==1)?ESTALE:errno; return -1;
  }
  if(fstat(fd,&s)!=0 || !S_ISREG(s.st_mode) || stamp(volume_key(fd, s), s)!=expected || s.st_nlink!=static_cast<nlink_t>(links)) {
    int saved=errno?errno:ESTALE;close(fd);error_number=saved;return -1;
  }
  guards[fd]={s.st_dev,s.st_ino,s.st_nlink,s.st_size,mtim(s),ctim(s),s.st_birthtimespec,now_ns()+30000000000LL};
  if(in_use(fd) || !guarded(fd)) {
    int saved=errno;guards.erase(fd);close(fd);error_number=saved;return -1;
  }
  error_number=0;return fd;
}
int anj_guard_valid(int fd) { std::lock_guard<std::mutex> lock(guard_mutex);int n=guarded(fd)?0:-1;error_number=n<0?errno:0;return n; }
int anj_guard_close(int fd) {
  std::lock_guard<std::mutex> lock(guard_mutex);
  auto found=guards.find(fd);if(found==guards.end()){error_number=EINVAL;return -1;}
  guards.erase(found);return close(fd);
}
int anj_guard_quarantine(int guard,int root,const char* path,int directory,const char* name) {
  std::lock_guard<std::mutex> lock(guard_mutex);
  if(!owned_directory(directory)||!valid(name)||strchr(name,'/')){error_number=EINVAL;return -1;}
  std::string leaf;int fd=parent(root,path,leaf);int n=-1;
  if(fd>=0) {
    if(matches_guard(guard,fd,leaf.c_str()) && !in_use(guard)) {
      nlink_t links=guards.at(guard).links;
      n=rename_noreplace(fd,leaf.c_str(),directory,name);
      // barrier, barrier: quarantine is a step of a release, not its end.
      if(n==0 && (barrier_sync(fd)!=0 || barrier_sync(directory)!=0 ||
                  !absorb_own_change(guard,links) || !matches_guard(guard,directory,name)))n=-1;
    }
    int saved=errno;close(fd);errno=saved;
  }
  error_number=n<0?errno:0;return n;
}
int anj_guard_unlink(int guard,int directory,const char* name) {
  std::lock_guard<std::mutex> lock(guard_mutex);
  if(!owned_directory(directory)||!valid(name)||strchr(name,'/')){error_number=EINVAL;return -1;}
  int n=-1;
  if(matches_guard(guard,directory,name)) {
    nlink_t links=guards.at(guard).links;
    if(links>1) {
      // Another link keeps the bytes: removing this one frees nothing, so
      // it needs no busy check, and the guard keeps its descriptor.
      n=unlinkat(directory,name,0);
      // barrier: another link still holds the bytes; the last unlink is full.
      if(n==0 && (barrier_sync(directory)!=0 || !absorb_own_change(guard,links-1)))n=-1;
    } else {
      // The last link: re-stat, then let the kernel refuse a busy file.
      struct stat s={};
      if(fstatat(directory,name,&s,AT_SYMLINK_NOFOLLOW)!=0) n=-1;
      else if(!unchanged(guards.at(guard),s)) errno=ESTALE;
      else {
        n=unlinkat(directory,name,AT_NODELETEBUSY);
        // full: the last unlink completes the release.
        if(n==0 && full_sync(directory)!=0)n=-1;
      }
    }
  }
  error_number=n<0?errno:0;return n;
}
}
