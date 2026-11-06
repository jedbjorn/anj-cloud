// the VM host test of native/windows/watch_translate.h (spec #32 File Watching): the
// ReadDirectoryChangesW notification -> compact record table, the 8.3 alias
// rule and the pending bound. Built and run by tool/test_windows_watch.sh
// (check.sh); the watch itself is tested on the seat (rootfs_win_test.cc).
#include "../watch_translate.h"

#include <cstdio>
#include <string>
#include <vector>

using namespace anj_watch;

namespace {
int passed = 0, failed = 0;
void check(const char* name, bool ok) {
  (ok ? passed : failed)++;
  printf("%s %s\n", ok ? "PASS" : "FAIL", name);
}
struct Rec { int wd; uint32_t mask; uint32_t cookie; std::string name; };
std::vector<Rec> decode(const std::vector<uint8_t>& b) {
  std::vector<Rec> out;
  for (size_t at = 0; at + 16 <= b.size();) {
    Rec r;
    uint32_t length;
    memcpy(&r.wd, b.data() + at, 4);
    memcpy(&r.mask, b.data() + at + 4, 4);
    memcpy(&r.cookie, b.data() + at + 8, 4);
    memcpy(&length, b.data() + at + 12, 4);
    r.name.assign(reinterpret_cast<const char*>(b.data() + at + 16), length);
    out.push_back(r);
    at += 16 + length;
  }
  return out;
}
std::vector<Rec> one(uint32_t action, bool directory, const std::string& path) {
  Queue q;
  translate(q, 1, action, directory, path);
  return decode(q.pending);
}
bool is(const std::vector<Rec>& r, int wd, uint32_t mask, const std::string& name) {
  return r.size() == 1 && r[0].wd == wd && r[0].mask == mask && r[0].name == name;
}
}  // namespace

int main() {
  check("added file", is(one(kAdded, false, "a.txt"), 1, kInCreate, "a.txt"));
  check("added folder is a subtree record", is(one(kAdded, true, "Docs"), 1, kInCreate | kInIsDir, "Docs"));
  check("nested path kept whole", is(one(kAdded, false, "Docs/2026/r.pdf"), 1, kInCreate, "Docs/2026/r.pdf"));
  check("removed", is(one(kRemoved, false, "a.txt"), 1, kInDelete, "a.txt"));
  check("removed folder", is(one(kRemoved, true, "Docs"), 1, kInDelete | kInIsDir, "Docs"));
  check("modified file", is(one(kModified, false, "a.txt"), 1, kInModify, "a.txt"));
  check("modified folder is dropped", one(kModified, true, "Docs").empty());
  check("unknown action is a modify", is(one(9, false, "a.txt"), 1, kInModify, "a.txt"));
  check("empty name is a full audit", is(one(kAdded, false, ""), -1, kInQueueOverflow, ""));
  check("dot component is a full audit", is(one(kAdded, false, "a/../b"), -1, kInQueueOverflow, ""));
  {
    Queue q;
    translate(q, 1, kRenamedOld, false, "old.txt");
    translate(q, 1, kRenamedNew, false, "Docs/new.txt");
    translate(q, 1, kRenamedOld, true, "A");
    translate(q, 1, kRenamedNew, true, "B");
    auto r = decode(q.pending);
    check("rename pairs share a cookie, pairs differ",
        r.size() == 4 && r[0].mask == kInMovedFrom && r[1].mask == kInMovedTo &&
        r[0].cookie && r[0].cookie == r[1].cookie && r[2].cookie == r[3].cookie &&
        r[2].cookie != r[0].cookie && r[2].mask == (kInMovedFrom | kInIsDir) &&
        r[3].name == "B");
  }
  check("8.3 file: its folder is audited", is(one(kModified, false, "Docs/REPORT~1.DOC"), 1, kInCreate | kInIsDir, "Docs"));
  check("8.3 folder: its parent is audited", is(one(kAdded, false, "Docs/PROGRA~2/x.txt"), 1, kInCreate | kInIsDir, "Docs"));
  check("8.3 at the top: a stat audit of the root", is(one(kModified, false, "MYDOCU~1/x"), 1, kInCreate | kInIsDir, ""));
  check("8.3 file at the top: a stat audit of the root", is(one(kModified, false, "REPORT~1.DOC"), 1, kInCreate | kInIsDir, ""));
  {
    Queue q;
    q.audit(1, "a/b");
    q.audit(-1, "a");
    auto r = decode(q.pending);
    check("an audit names its directory; without a root watch, a full audit",
        r.size() == 1 && r[0].wd == -1 && r[0].mask == kInQueueOverflow);
    Queue q2;
    q2.audit(1, "a/b");
    auto r2 = decode(q2.pending);
    check("a subtree audit record", r2.size() == 1 && r2[0].wd == 1 && r2[0].mask == (kInCreate | kInIsDir) && r2[0].name == "a/b");
  }
  {
    auto bad = [](const std::string& parent) {
      Queue q;
      unreadable(q, 1, parent);
      return decode(q.pending);
    };
    check("unreadable name at the top: a stat audit of the root", is(bad(""), 1, kInCreate | kInIsDir, ""));
    check("unreadable name beneath: its parent is audited", is(bad("Docs/2026"), 1, kInCreate | kInIsDir, "Docs/2026"));
    check("unreadable name beneath an 8.3 folder: the folder's parent", is(bad("Docs/PROGRA~2/x"), 1, kInCreate | kInIsDir, "Docs"));
    check("unreadable name beneath an 8.3 top folder: the root", is(bad("MYDOCU~1"), 1, kInCreate | kInIsDir, ""));
  }
  check("~$ Office lock is a name", is(one(kAdded, false, "~$port.docx"), 1, kInCreate, "~$port.docx"));
  check("~WRL temp is a name", is(one(kAdded, false, "~WRL0001.tmp"), 1, kInCreate, "~WRL0001.tmp"));
  check("trailing ~ is a name", is(one(kModified, false, "notes~"), 1, kInModify, "notes~"));
  check("lowercase ~1 is a name", is(one(kModified, false, "report~1.doc"), 1, kInModify, "report~1.doc"));
  check("long base ~1 is a name", is(one(kModified, false, "LONGNAME~1.TXT"), 1, kInModify, "LONGNAME~1.TXT"));
  check("~ without digits is a name", is(one(kModified, false, "AB~C.TXT"), 1, kInModify, "AB~C.TXT"));
  check("4-character extension is a name", is(one(kModified, false, "AB~1.DOCX"), 1, kInModify, "AB~1.DOCX"));
  {
    Queue q;
    q.bound = 200;
    for (int i = 0; i < 50; i++) translate(q, 1, kAdded, false, "file-" + std::to_string(i));
    auto r = decode(q.pending);
    check("past the bound: one overflow record", r.size() == 1 && r[0].wd == -1 && r[0].mask == kInQueueOverflow);
    translate(q, 1, kAdded, false, "after");
    check("nothing after an overflow until drained", decode(q.pending).size() == 1);
  }
  {
    Queue q;
    q.root_self(1);
    auto r = decode(q.pending);
    check("root self is IN_MOVE_SELF on the root", r.size() == 1 && r[0].wd == 1 && r[0].mask == kInMoveSelf && r[0].name.empty());
    Queue none;
    none.root_self(-1);
    check("root self with no root watch is a full audit", decode(none.pending)[0].mask == kInQueueOverflow);
  }
  printf("watch_translate: %d passed, %d failed\n", passed, failed);
  return failed ? 1 : 0;
}
