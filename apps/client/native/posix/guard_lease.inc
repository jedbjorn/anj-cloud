// Included in rootfs.cc after eviction.inc: the Linux release guard, a
// bounded F_SETLEASE mechanism, not a filesystem.
#include <signal.h>
#include <time.h>

namespace {
// [weak]: no lease could be taken (a phone folder file in shared storage,
// spec #52 and #108 Q15); the guard then holds only while the file keeps the
// size and modification time it had at guard open: the weaker guard,
// behind the app's own open-file tracking (RegisteredReleaseGuard).
struct LeaseState {
  dev_t device; ino_t inode; long long deadline_ns;
  bool weak; off_t size; struct timespec mtime;
};
std::map<int, LeaseState> leases;
std::mutex lease_mutex;
volatile sig_atomic_t lease_broken = 0;
int lease_signal = 0;
long long now_ns() { struct timespec t = {}; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec*1000000000LL+t.tv_nsec; }
void lease_break_handler(int, siginfo_t*, void*) { lease_broken = 1; }
bool establish_handler() {
  if (lease_signal) {
    struct sigaction current = {};
    if (sigaction(lease_signal,nullptr,&current) != 0 || current.sa_sigaction != lease_break_handler) { errno = ENOTSUP; return false; }
    return true;
  }
  for (int number = SIGRTMIN+6; number <= SIGRTMAX; number++) {
    struct sigaction prior = {};
    if (sigaction(number,nullptr,&prior) != 0 || prior.sa_handler != SIG_DFL) continue;
    struct sigaction action = {};
    action.sa_sigaction = lease_break_handler; action.sa_flags = SA_SIGINFO|SA_RESTART; sigemptyset(&action.sa_mask);
    if (sigaction(number,&action,nullptr) == 0) { lease_signal = number; return true; }
  }
  errno = ENOTSUP; return false;
}
bool guarded(int fd) {
  auto found = leases.find(fd);
  if (found == leases.end() || now_ns() > found->second.deadline_ns) { errno = EAGAIN; return false; }
  const LeaseState& held = found->second;
  if (!held.weak && (lease_broken || fcntl(fd,F_GETLEASE) != F_WRLCK)) { errno = EAGAIN; return false; }
  struct stat s = {};
  if (fstat(fd,&s) != 0 || s.st_dev != held.device || s.st_ino != held.inode) { errno = ESTALE; return false; }
  if (held.weak && (s.st_size != held.size || mtim(s).tv_sec != held.mtime.tv_sec ||
                    mtim(s).tv_nsec != held.mtime.tv_nsec)) { errno = EAGAIN; return false; }
  return true;
}
bool matches_guard(int guard, int parentfd, const char* name) {
  if (!guarded(guard)) return false;
  struct stat s = {};
  if (fstatat(parentfd,name,&s,AT_SYMLINK_NOFOLLOW) != 0) return false;
  const auto& held = leases.at(guard);
  if (!S_ISREG(s.st_mode) || s.st_dev != held.device || s.st_ino != held.inode) { errno = ESTALE; return false; }
  return true;
}
}
extern "C" {
// The guard this library implements (ReleaseGuardStrength in Dart).
const char* anj_guard_kind() { return "lease"; }
int anj_guard_open(int directory,const char* path,const char* expected,int links) {
  std::lock_guard<std::mutex> lock(lease_mutex);
  int fd=beneath(directory,path,O_RDONLY|O_NONBLOCK); struct stat s={};
  if(fd<0) { error_number=errno;return -1; }
  if(fstat(fd,&s)!=0 || !S_ISREG(s.st_mode) || stamp(volume_key(fd, s), s)!=expected || s.st_nlink!=static_cast<nlink_t>(links) || !establish_handler()) {
    int saved=errno?errno:ESTALE;close(fd);error_number=saved;return -1;
  }
  if(leases.empty())lease_broken=0;
  bool weak=false;
  if(lease_broken || fcntl(fd,F_SETOWN,getpid())<0 || fcntl(fd,F_SETSIG,lease_signal)<0 || fcntl(fd,F_SETLEASE,F_WRLCK)<0) {
    int saved=errno?errno:EAGAIN;
#if defined(ANJ_COMPAT_ANDROID)
    // Shared storage refuses every lease (EACCES, AC0): the weaker guard.
    weak = !lease_broken && saved==EACCES && on_shared_storage(fd);
#endif
    if(!weak) { close(fd);error_number=saved;return -1; }
  }
  leases[fd]={s.st_dev,s.st_ino,now_ns()+30000000000LL,weak,s.st_size,mtim(s)};error_number=0;return fd;
}
int anj_guard_valid(int fd) { std::lock_guard<std::mutex> lock(lease_mutex);int n=guarded(fd)?0:-1;error_number=n<0?errno:0;return n; }
int anj_guard_close(int fd) {
  std::lock_guard<std::mutex> lock(lease_mutex);
  auto found=leases.find(fd);if(found==leases.end()){error_number=EINVAL;return -1;}
  if(!found->second.weak)fcntl(fd,F_SETLEASE,F_UNLCK);
  leases.erase(found);return close(fd);
  // Keep our nonterminating signal handler installed: late queued break signals
  // must never be delivered to SIG_DFL after the guard has closed.
}
int anj_guard_quarantine(int guard,int root,const char* path,int directory,const char* name) {
  std::lock_guard<std::mutex> lock(lease_mutex);
  if(!owned_directory(directory)||!valid(name)||strchr(name,'/')){error_number=EINVAL;return -1;}
  std::string leaf;int fd=parent(root,path,leaf);int n=-1;
  if(fd>=0) {
    if(matches_guard(guard,fd,leaf.c_str())) {
      n=rename_noreplace(fd,leaf.c_str(),directory,name);
      // barrier, barrier: quarantine is a step of a release, not its end.
      if(n==0 && (barrier_sync(fd)!=0 || barrier_sync(directory)!=0 || !matches_guard(guard,directory,name)))n=-1;
    }
    int saved=errno;close(fd);errno=saved;
  }
  error_number=n<0?errno:0;return n;
}
int anj_guard_unlink(int guard,int directory,const char* name) {
  std::lock_guard<std::mutex> lock(lease_mutex);
  if(!owned_directory(directory)||!valid(name)||strchr(name,'/')){error_number=EINVAL;return -1;}
  int n=-1;
  // full: an unlink completes a release (or removes one alias of it).
  if(matches_guard(guard,directory,name)) { n=unlinkat(directory,name,0);if(n==0 && full_sync(directory)!=0)n=-1; }
  error_number=n<0?errno:0;return n;
}
}
