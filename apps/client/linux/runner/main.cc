#include "my_application.h"
#include "../../native/posix/lifecycle_bootstrap.h"
#include <cstdio>

int main(int argc, char** argv) {
  if (!anj_profile_argument_cloexec(argc, argv)) {
    fprintf(stderr, "anj-cloud: invalid inherited profile lock descriptor\n");
    return 64;
  }
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
