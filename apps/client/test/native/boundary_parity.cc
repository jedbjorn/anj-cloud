// Refusal parity of the Android filesystem boundary (spec #28 Native Boundary,
// decision #123). Built and run on Linux by test/android_boundary_test.dart:
//
//   boundary_parity <libanj_rootfs.so> <empty dir> [--android-sandbox]
//
// It builds one fixture tree (symlinks to directories, files and outside the
// root, a dangling link, a file used as a directory, owned staging), drives
// the anj_* ABI through every confined entry point and prints one line per
// case: the case name, "ok" or the errno, and what an install left behind.
// The test runs it against the Linux library and against the same source
// built with the Android boundary (-DANJ_ANDROID_BOUNDARY), and requires
// identical output except where an install's mechanism differs by design
// (hard link on Linux, copy plus RENAME_NOREPLACE on Android: link counts).
//
// --android-sandbox installs a seccomp filter first, as Android's app sandbox
// does for the two calls A1 found refused: openat2 kills the process (SIGSYS)
// and linkat fails with EACCES. The Android build must pass every case
// under it, which shows it never calls either.
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <string>

namespace {
void* lib = nullptr;
template <typename T> T sym(const char* name) {
  void* f = dlsym(lib, name);
  if (!f) { fprintf(stderr, "missing %s\n", name); exit(3); }
  return reinterpret_cast<T>(f);
}
int (*anj_error)();
int (*anj_open_root)(const char*);
int (*anj_check_root)(int, const char*);
int (*anj_open_read)(int, const char*);
int (*anj_open_directory)(int, const char*);
int (*anj_mkdir)(int, const char*);
int (*anj_mkdir_exclusive)(int, const char*);
long long (*anj_fs_magic)(int, const char*);
int (*anj_install)(int, const char*, const char*);
int (*anj_quarantine)(int, const char*, const char*);
char* (*anj_info_at)(int, const char*);
int (*anj_create_owned)(int, const char*);
int (*anj_install_owned)(int, const char*, int, const char*);
int (*anj_restore_owned)(int, const char*, int, const char*);
char* (*anj_watch_scan)(void*, int, const char*, int);
char* (*anj_scan)(int);
void (*anj_free)(void*);
int (*anj_close)(int);

std::string base;
void report(const char* name, int result, const char* extra = "") {
  if (result >= 0) printf("%-34s ok%s\n", name, extra);
  else printf("%-34s errno=%d%s\n", name, anj_error(), extra);
}
void fd_case(const char* name, int fd) {
  report(name, fd);
  if (fd >= 0) anj_close(fd);
}
void ptr_case(const char* name, char* value) {
  report(name, value ? 0 : -1);
  if (value) anj_free(value);
}
std::string slurp(const std::string& path) {
  FILE* f = fopen(path.c_str(), "rb");
  if (!f) return "<absent>";
  std::string s; char b[256]; size_t n;
  while ((n = fread(b, 1, sizeof(b), f)) > 0) s.append(b, n);
  fclose(f);
  return s;
}
void write_file(const std::string& path, const char* text) {
  FILE* f = fopen(path.c_str(), "wb");
  if (!f) { perror(path.c_str()); exit(4); }
  fputs(text, f); fclose(f);
}
void must(int r, const char* what) { if (r != 0) { perror(what); exit(4); } }

void fixture() {
  std::string r = base + "/root";
  must(mkdir(r.c_str(), 0700), "root");
  must(mkdir((r + "/a").c_str(), 0700), "a");
  must(mkdir((r + "/a/b").c_str(), 0700), "a/b");
  write_file(r + "/a/b/f", "inner");
  write_file(r + "/a/file.txt", "text");
  must(symlink("b", (r + "/a/dirlink").c_str()), "dirlink");
  must(symlink("file.txt", (r + "/a/filelink").c_str()), "filelink");
  must(symlink("/", (r + "/a/abs").c_str()), "abs");
  must(symlink("missing", (r + "/a/dangling").c_str()), "dangling");
  must(symlink("../..", (r + "/a/up").c_str()), "up");
  must(mkdir((base + "/outside").c_str(), 0700), "outside");
  write_file(base + "/outside/secret", "secret");
  must(symlink((base + "/outside").c_str(), (r + "/escape").c_str()), "escape");
  must(symlink("root", (base + "/rootlink").c_str()), "rootlink");
  must(mkdir((base + "/stage").c_str(), 0700), "stage");
}

// Seccomp filter: openat2 kills the process, linkat returns EACCES.
void android_sandbox() {
  struct sock_filter filter[] = {
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch)),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_X86_64, 1, 0),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 437 /* openat2 */, 0, 1),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_linkat, 0, 1),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EACCES),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_link, 0, 1),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EACCES),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
  };
  struct sock_fprog prog = {static_cast<unsigned short>(sizeof(filter) / sizeof(filter[0])), filter};
  must(prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0), "no_new_privs");
  must(prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog), "seccomp");
}
}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) { fprintf(stderr, "usage: %s <lib> <dir> [--android-sandbox]\n", argv[0]); return 2; }
  base = argv[2];
  fixture();
  lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!lib) { fprintf(stderr, "%s\n", dlerror()); return 3; }
  anj_error = sym<int (*)()>("anj_error");
  anj_open_root = sym<int (*)(const char*)>("anj_open_root");
  anj_check_root = sym<int (*)(int, const char*)>("anj_check_root");
  anj_open_read = sym<int (*)(int, const char*)>("anj_open_read");
  anj_open_directory = sym<int (*)(int, const char*)>("anj_open_directory");
  anj_mkdir = sym<int (*)(int, const char*)>("anj_mkdir");
  anj_mkdir_exclusive = sym<int (*)(int, const char*)>("anj_mkdir_exclusive");
  anj_fs_magic = sym<long long (*)(int, const char*)>("anj_fs_magic");
  anj_install = sym<int (*)(int, const char*, const char*)>("anj_install");
  anj_quarantine = sym<int (*)(int, const char*, const char*)>("anj_quarantine");
  anj_info_at = sym<char* (*)(int, const char*)>("anj_info_at");
  anj_create_owned = sym<int (*)(int, const char*)>("anj_create_owned");
  anj_install_owned = sym<int (*)(int, const char*, int, const char*)>("anj_install_owned");
  anj_restore_owned = sym<int (*)(int, const char*, int, const char*)>("anj_restore_owned");
  anj_watch_scan = sym<char* (*)(void*, int, const char*, int)>("anj_watch_scan");
  anj_scan = sym<char* (*)(int)>("anj_scan");
  anj_free = sym<void (*)(void*)>("anj_free");
  anj_close = sym<int (*)(int)>("anj_close");
  if (argc > 3 && strcmp(argv[3], "--android-sandbox") == 0) android_sandbox();

  const std::string r = base + "/root";
  // The root: absolute, no symlink anywhere in it.
  int root = anj_open_root(r.c_str());
  report("open_root", root);
  if (root < 0) return 5;
  fd_case("open_root through symlink", anj_open_root((base + "/rootlink").c_str()));
  fd_case("open_root symlink component", anj_open_root((base + "/rootlink/a").c_str()));
  fd_case("open_root missing", anj_open_root((base + "/nope").c_str()));
  fd_case("open_root file", anj_open_root((r + "/a/file.txt").c_str()));
  report("check_root", anj_check_root(root, r.c_str()));
  report("check_root via symlink", anj_check_root(root, (base + "/rootlink").c_str()));

  // Confined resolution beneath the root.
  const char* reads[] = {
    "a/file.txt", "a/b/f", "a/filelink", "a/dirlink/f", "a/abs/etc/hostname",
    "a/dangling", "a/up/outside/secret", "escape/secret", "a/file.txt/x",
    "missing/x", "a/missing", "a", "a/../a/file.txt", "./a/file.txt",
    "/etc/hostname", "", "a//file.txt", "a/b/",
  };
  for (const char* path : reads) fd_case((std::string("read ") + path).c_str(), anj_open_read(root, path));
  const char* dirs[] = {"a", "a/b", "a/dirlink", "escape", "a/file.txt", "a/up", "missing"};
  for (const char* path : dirs) fd_case((std::string("dir ") + path).c_str(), anj_open_directory(root, path));
  const char* infos[] = {"a/file.txt", "a/filelink", "a/dirlink/f", "escape/secret", "a/b"};
  for (const char* path : infos) ptr_case((std::string("info ") + path).c_str(), anj_info_at(root, path));
  for (const char* path : {"", "a", "a/dirlink", "escape", "a/b/f"}) {
    long long magic = anj_fs_magic(root, path);
    report((std::string("magic ") + path).c_str(), magic < 0 ? -1 : 0);
  }
  for (const char* path : {"a/new", "a/dirlink/new", "escape/new", "a/file.txt/new", "a/b"}) {
    report((std::string("mkdir ") + path).c_str(), anj_mkdir(root, path));
  }
  for (const char* path : {"a/new", "a/fresh"}) {
    report((std::string("mkdir_exclusive ") + path).c_str(), anj_mkdir_exclusive(root, path));
  }
  for (const char* path : {"a", "a/dirlink", "escape", "a/file.txt"}) {
    ptr_case((std::string("watch_scan ") + path).c_str(), anj_watch_scan(nullptr, root, path, 1));
  }
  ptr_case("scan", anj_scan(root));

  // Install from an absolute staged path (RootTree.installAbsent).
  const std::string staged = base + "/stage/transfer-1";
  write_file(staged, "installed bytes");
  report("install a/new/x", anj_install(root, "a/new/x", staged.c_str()));
  printf("  content=%s staged=%s\n", slurp(r + "/a/new/x").c_str(), slurp(staged).c_str());
  report("install onto existing", anj_install(root, "a/file.txt", staged.c_str()));
  printf("  content=%s\n", slurp(r + "/a/file.txt").c_str());
  report("install through dir symlink", anj_install(root, "a/dirlink/x", staged.c_str()));
  report("install through escape", anj_install(root, "escape/x", staged.c_str()));
  report("install onto symlink", anj_install(root, "a/dangling", staged.c_str()));
  printf("  outside=%s\n", slurp(base + "/outside/x").c_str());
  report("install missing staged", anj_install(root, "a/other", (base + "/stage/none").c_str()));

  // Owned staging (ReleaseGuard): create, install, restore.
  int stage = open((base + "/stage").c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  int created = anj_create_owned(stage, "download-1");
  report("create_owned", created);
  if (created >= 0) {
    ssize_t ignored = write(created, "owned bytes", 11); (void)ignored;
    fsync(created); anj_close(created);
  }
  fd_case("create_owned existing", anj_create_owned(stage, "download-1"));
  must(symlink("/tmp", (base + "/stage/linked").c_str()), "linked");
  fd_case("create_owned onto symlink", anj_create_owned(stage, "linked"));
  fd_case("create_owned nested", anj_create_owned(stage, "a/b"));
  report("install_owned a/b/owned", anj_install_owned(root, "a/b/owned", stage, "download-1"));
  struct stat st = {};
  stat((r + "/a/b/owned").c_str(), &st);
  printf("  content=%s staged=%s mode=%o\n", slurp(r + "/a/b/owned").c_str(),
         slurp(base + "/stage/download-1").c_str(), st.st_mode & 0777);
  // Mechanism, not refusal: Linux links (2), Android copies (1). Reported apart.
  printf("MECHANISM links=%ld\n", static_cast<long>(st.st_nlink));
  report("install_owned onto existing", anj_install_owned(root, "a/b/f", stage, "download-1"));
  printf("  content=%s\n", slurp(r + "/a/b/f").c_str());
  report("install_owned through symlink", anj_install_owned(root, "a/dirlink/o", stage, "download-1"));
  report("install_owned escape", anj_install_owned(root, "escape/o", stage, "download-1"));
  report("install_owned missing", anj_install_owned(root, "a/o2", stage, "none"));
  report("install_owned symlink staged", anj_install_owned(root, "a/o3", stage, "linked"));
  write_file(base + "/stage/recover-1", "recovered");
  report("restore_owned onto existing", anj_restore_owned(root, "a/file.txt", stage, "recover-1"));
  report("restore_owned a/restored", anj_restore_owned(root, "a/restored", stage, "recover-1"));
  printf("  content=%s staged=%s\n", slurp(r + "/a/restored").c_str(), slurp(base + "/stage/recover-1").c_str());
  report("quarantine a/restored", anj_quarantine(root, "a/restored", (base + "/stage/q-1").c_str()));
  report("quarantine symlink", anj_quarantine(root, "a/filelink", (base + "/stage/q-2").c_str()));
  // Nothing an install created may remain in staging under a temporary name.
  std::string leftovers;
  if (DIR* d = opendir((base + "/stage").c_str())) {
    while (struct dirent* e = readdir(d)) {
      if (strcmp(e->d_name, ".") && strcmp(e->d_name, "..")) leftovers += std::string(e->d_name) + " ";
    }
    closedir(d);
  }
  printf("staging: %s\n", leftovers.c_str());
  printf("done\n");
  return 0;
}
