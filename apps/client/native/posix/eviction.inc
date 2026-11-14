// Included in rootfs.cc: owned staging files shared by every POSIX platform
// (spec #31 S2). The release guard itself is per OS: guard_lease.inc is the
// Linux F_SETLEASE guard.
#include <map>
#include <mutex>

namespace {
bool owned_directory(int fd) {
  struct stat s = {};
  if (fstat(fd,&s) != 0) return false;
#if defined(ANJ_COMPAT_ANDROID)
  // The phone folders' staging folder in shared storage (spec #52): a folder
  // there can be neither owned nor private (see on_shared_storage); the
  // folder itself is still required.
  if (S_ISDIR(s.st_mode) && on_shared_storage(fd)) return true;
#endif
  if (!S_ISDIR(s.st_mode) || s.st_uid != geteuid() || (s.st_mode & 0077)) { errno = EPERM; return false; }
  return true;
}
// Persisted (journal records, previews): the volume key, never raw st_dev.
// An in-memory guard may key on st_dev: it lives for 30 s in one process.
std::string stamp(const std::string& volume, const struct stat& s) {
  return identity_of(volume, s)+":"+std::to_string(s.st_size)+":"+
    std::to_string(mtim(s).tv_sec)+":"+std::to_string(mtim(s).tv_nsec)+":"+
    std::to_string(ctim(s).tv_sec)+":"+std::to_string(ctim(s).tv_nsec);
}
std::string info_json(const std::string& volume, const struct stat& s) {
  return "{\"identity\":"+quote(identity_of(volume, s))+
    ",\"stamp\":"+quote(stamp(volume, s))+",\"links\":"+std::to_string(s.st_nlink)+
    ",\"allocated\":"+std::to_string(s.st_blocks*512LL)+",\"size\":"+std::to_string(s.st_size)+",\"owned\":"+(s.st_uid == geteuid() ? "true" : "false")+",\"modifiedMs\":"+std::to_string(static_cast<long long>(mtim(s).tv_sec)*1000LL+mtim(s).tv_nsec/1000000)+"}";
}
}
extern "C" {
char* anj_info_at(int root, const char* path) {
  std::string leaf; int fd = parent(root,path,leaf); struct stat s = {}; int result = -1;
  std::string volume;
  if (fd >= 0) {
    result = fstatat(fd,leaf.c_str(),&s,AT_SYMLINK_NOFOLLOW); int saved = errno;
    if (result == 0) volume = volume_key_at(fd, leaf.c_str(), s);
    close(fd); errno = saved;
  }
  if (result != 0 || !S_ISREG(s.st_mode)) { error_number = result != 0 ? errno : EINVAL; return nullptr; }
  return strdup(info_json(volume, s).c_str());
}
char* anj_preview_editor(int directory, const char* name) {
  if (!owned_directory(directory) || !valid(name) || strchr(name,'/')) { error_number=EINVAL; return nullptr; }
  int fd=beneath(directory,name,O_RDONLY|O_NONBLOCK); struct stat s={};
  if(fd<0) { error_number=errno; return nullptr; }
  bool ok=fstat(fd,&s)==0 && S_ISREG(s.st_mode) && s.st_uid==geteuid() && s.st_nlink==1;
  int saved=errno; std::string volume = ok ? volume_key(fd, s) : std::string(); close(fd);
  if(!ok) { error_number=saved?saved:EPERM;return nullptr; }
  return strdup(info_json(volume, s).c_str());
}
char* anj_info_fd(int fd) { struct stat s = {}; if (fstat(fd,&s) != 0) { error_number=errno; return nullptr; } return strdup(info_json(volume_key(fd, s), s).c_str()); }
int anj_create_owned(int directory, const char* name) {
  if (!owned_directory(directory) || !valid(name) || strchr(name,'/')) { error_number=EINVAL; return -1; }
  int fd = open_beneath(directory,name,O_RDWR|O_CREAT|O_EXCL,0600);
  // barrier, barrier: a new empty staging file and its entry, before content.
  if (fd >= 0 && (barrier_sync(fd) != 0 || barrier_sync(directory) != 0)) { int saved=errno; close(fd); fd=-1; errno=saved; }
  error_number=fd<0?errno:0; return fd;
}
// full: an explicit directory sync is a commit point.
int anj_sync_dir(int fd) { int n=full_sync(fd); error_number=n<0?errno:0; return n; }
int anj_rewind(int fd) { int n=lseek(fd,0,SEEK_SET)<0?-1:0; error_number=n<0?errno:0; return n; }
int anj_install_owned(int root,const char* path,int directory,const char* name) {
  if (!owned_directory(directory) || !valid(name) || strchr(name,'/')) { error_number=EINVAL; return -1; }
  struct stat s={};
  if (fstatat(directory,name,&s,AT_SYMLINK_NOFOLLOW)!=0 || !S_ISREG(s.st_mode)) { error_number=EINVAL; return -1; }
  std::string leaf; int fd=parent(root,path,leaf); int n=-1;
  // barrier: the staged bytes, before the new name (Darwin; no-op on Linux).
  // full: the install is the commit point.
  if(fd>=0) {
    n=staged_data_barrier(directory,name);
    if(n==0) { n=link_file(directory,name,fd,leaf.c_str()); if(n==0 && full_sync(fd)!=0)n=-1; }
    int saved=errno;close(fd);errno=saved;
  }
  error_number=n<0?errno:0;return n;
}
// Recover (spec #25): moves a complete, fsynced staging file into the root
// under its final name. RENAME_NOREPLACE: an occupied destination is never
// overwritten (EEXIST); both directories are synced before success.
int anj_restore_owned(int root,const char* path,int directory,const char* name) {
  if (!owned_directory(directory) || !valid(name) || strchr(name,'/')) { error_number=EINVAL; return -1; }
  struct stat s={};
  if (fstatat(directory,name,&s,AT_SYMLINK_NOFOLLOW)!=0 || !S_ISREG(s.st_mode)) { error_number=EINVAL; return -1; }
  std::string leaf; int fd=parent(root,path,leaf); int n=-1;
  if(fd>=0) {
    n=rename_noreplace(directory,name,fd,leaf.c_str());
    // full: the restored file is the commit point; barrier: the staging side.
    if(n==0 && (full_sync(fd)!=0 || barrier_sync(directory)!=0))n=-1;
    int saved=errno;close(fd);errno=saved;
  }
  error_number=n<0?errno:0;return n;
}
int anj_preserve_owned(int root,const char* path,int directory,const char* name) {
  if (!owned_directory(directory) || !valid(name) || strchr(name,'/')) { error_number=EINVAL; return -1; }
  std::string leaf; int fd=parent(root,path,leaf); int n=-1; struct stat s={};
  if(fd>=0) {
    if(fstatat(fd,leaf.c_str(),&s,AT_SYMLINK_NOFOLLOW)==0 && S_ISREG(s.st_mode)) {
      n=rename_noreplace(fd,leaf.c_str(),directory,name);
      // barrier, barrier: preservation inside a larger step; its record commits full.
      if(n==0 && (barrier_sync(fd)!=0 || barrier_sync(directory)!=0))n=-1;
    } else errno=EINVAL;
    int saved=errno;close(fd);errno=saved;
  }
  error_number=n<0?errno:0;return n;
}
}
