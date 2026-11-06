// ReadDirectoryChangesW notifications as the shared compact watch records
// (spec #32 "File Watching"). Portable C++17 with no Windows header, so the
// translation is tested on the VM host too (native/windows/test/watch_translate_test.cc);
// native/windows/rootfs_win.cc feeds it from one recursive watch on the root.
//
// There is one watch descriptor that events refer to: the root's. Each
// notification names a root-relative path (UTF-8, '/'-separated) and becomes
// the record (root wd, mask, cookie, <path>) with the inotify mask bits the
// shared Dart watcher (lib/platform/native/local_watcher.dart) reads; a name
// with '/' in it is joined onto the root as is. Events are hints: every
// queued path is re-read by stat.
//
//   FILE_ACTION_ADDED            -> IN_CREATE   (| IN_ISDIR: a subtree audit)
//   FILE_ACTION_REMOVED          -> IN_DELETE   (| IN_ISDIR)
//   FILE_ACTION_MODIFIED, file   -> IN_MODIFY
//   FILE_ACTION_MODIFIED, folder -> nothing: a folder's times change with its
//                                   entries, and each entry is reported itself
//   FILE_ACTION_RENAMED_OLD_NAME -> IN_MOVED_FROM \ one cookie per pair, as
//   FILE_ACTION_RENAMED_NEW_NAME -> IN_MOVED_TO   / inotify pairs them
//   an unknown action            -> IN_MODIFY (still a candidate)
//   a component in 8.3 form      -> a subtree audit of its parent (the re-stat
//     (REPORT~1.DOC)                cannot find an alias); at the top, a stat
//                                   audit of the root (nothing was lost)
//   a component not valid UTF-16 -> the same audit of its parent (rootfs_win.cc
//     (a lone surrogate)            converts component by component)
//   an empty name, overflow,     -> IN_Q_OVERFLOW (a full audit)
//   zero bytes
//   the watch handle failed      -> IN_MOVE_SELF on the root (the root audit)
//
// A subtree audit is IN_CREATE | IN_ISDIR on the root's descriptor naming the
// directory, as for a new folder; with an empty name it is the root's own
// stat audit (the shared watcher queues the subtree ""), which re-reads only
// files whose stat stamp changed, unlike the full audit.
#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace anj_watch {

// inotify(7) mask bits used by the shared compact records.
constexpr uint32_t kInModify = 0x2, kInAttrib = 0x4, kInMovedFrom = 0x40,
    kInMovedTo = 0x80, kInCreate = 0x100, kInDelete = 0x200, kInMoveSelf = 0x800,
    kInQueueOverflow = 0x4000, kInIsDir = 0x40000000;
// A wait reports a suspend (wd -2) when the sleep-inclusive clock advanced
// this much more than the sleep-exclusive one since the previous wait.
constexpr int kSuspendRecord = -2;
constexpr long long kSuspendNs = 2000000000LL;
// Records held for the watcher isolate beyond this many bytes are replaced
// by one IN_Q_OVERFLOW record (the engine then audits the whole root).
constexpr size_t kPendingBound = 8u << 20;
// FILE_ACTION_* (winnt.h).
constexpr uint32_t kAdded = 1, kRemoved = 2, kModified = 3, kRenamedOld = 4,
    kRenamedNew = 5;

inline void put32(std::vector<uint8_t>& out, uint32_t v) {
  uint8_t b[4];
  memcpy(b, &v, 4);
  out.insert(out.end(), b, b + 4);
}
// Compact record: int32 wd, uint32 mask, uint32 cookie, uint32 length, name.
inline void record(std::vector<uint8_t>& out, int wd, uint32_t mask, uint32_t cookie,
    const std::string& name) {
  put32(out, static_cast<uint32_t>(wd));
  put32(out, mask);
  put32(out, cookie);
  put32(out, static_cast<uint32_t>(name.size()));
  out.insert(out.end(), name.begin(), name.end());
}

// Records not yet read by the watcher isolate, bounded.
struct Queue {
  std::vector<uint8_t> pending;
  bool overflowed = false;
  size_t bound = kPendingBound;
  uint32_t cookie = 0;  // the last rename pair's
  void emit(int wd, uint32_t mask, uint32_t cookie_value, const std::string& name) {
    if (overflowed) return;
    if (pending.size() + 16 + name.size() > bound) {
      overflow();
      return;
    }
    record(pending, wd, mask, cookie_value, name);
  }
  // Everything held is replaced by one full-audit record.
  void overflow() {
    pending.clear();
    overflowed = true;
    record(pending, -1, kInQueueOverflow, 0, "");
  }
  // A stat audit of [parent] ('/'-separated, root-relative; empty: the root).
  void audit(int root_wd, const std::string& parent) {
    if (root_wd < 0) overflow();
    else emit(root_wd, kInCreate | kInIsDir, 0, parent);
  }
  void root_self(int root_wd) {
    if (root_wd < 0) overflow();
    else emit(root_wd, kInMoveSelf, 0, "");
  }
};

// Whether [c] is spelled as a generated 8.3 alias: 1-6 characters, '~',
// digits, an optional extension of 1-3, no lowercase letter (REPORT~1.DOC,
// PROGRA~2). Office's "~$a.docx" and "~WRL0001.tmp", or "notes~", are not.
inline bool short_alias(const std::string& c) {
  size_t tilde = c.find('~');
  if (tilde == std::string::npos || tilde == 0 || tilde > 6) return false;
  size_t dot = c.find('.', tilde);
  std::string digits = c.substr(tilde + 1, dot == std::string::npos ? std::string::npos
                                                                      : dot - tilde - 1);
  if (digits.empty()) return false;
  for (char ch : digits) if (ch < '0' || ch > '9') return false;
  if (dot != std::string::npos) {
    size_t ext = c.size() - dot - 1;
    if (ext < 1 || ext > 3 || c.find('.', dot + 1) != std::string::npos) return false;
  }
  if (tilde + 1 + digits.size() > 8) return false;
  for (char ch : c) {
    if (ch >= 'a' && ch <= 'z') return false;
    if (static_cast<unsigned char>(ch) >= 0x80) return false;
  }
  for (size_t i = 0; i < tilde; i++) if (c[i] == '.') return false;
  return true;
}

// A notification whose name holds a component that is not valid UTF-16 (a
// lone surrogate), beneath the readable components [parent]: a stat audit of
// [parent], or of its nearest ancestor spelled in full when it holds an 8.3
// alias (the root at the top). Nothing was lost, so not the full audit.
inline void unreadable(Queue& q, int root_wd, const std::string& parent) {
  size_t start = 0, keep = 0;
  while (!parent.empty()) {
    size_t slash = parent.find('/', start);
    std::string component = parent.substr(start, slash == std::string::npos
        ? std::string::npos : slash - start);
    if (component.empty() || component == "." || component == "..") {
      q.emit(-1, kInQueueOverflow, 0, "");
      return;
    }
    if (short_alias(component)) break;
    if (slash == std::string::npos) { keep = parent.size(); break; }
    keep = slash;
    start = slash + 1;
  }
  q.audit(root_wd, parent.substr(0, keep));
}

// One notification for root-relative [relative] ('/'-separated, UTF-8; empty
// when the name could not be read). [directory] is the item's attribute
// (extended notifications); without it, false.
inline void translate(Queue& q, int root_wd, uint32_t action, bool directory,
    const std::string& relative) {
  if (relative.empty()) { q.emit(-1, kInQueueOverflow, 0, ""); return; }
  size_t start = 0;
  while (true) {
    size_t slash = relative.find('/', start);
    std::string component = relative.substr(start, slash == std::string::npos
        ? std::string::npos : slash - start);
    if (component.empty() || component == "." || component == "..") {
      q.emit(-1, kInQueueOverflow, 0, "");
      return;
    }
    if (short_alias(component)) {
      // The parent of the aliased component (the root at the top): re-read
      // by stat. No event was lost, so this is not the full audit.
      q.audit(root_wd, start == 0 ? std::string() : relative.substr(0, start - 1));
      return;
    }
    if (slash == std::string::npos) break;
    start = slash + 1;
  }
  uint32_t mask = 0, cookie = 0;
  switch (action) {
    case kAdded: mask = kInCreate; break;
    case kRemoved: mask = kInDelete; break;
    case kModified:
      if (directory) return;
      mask = kInModify;
      break;
    case kRenamedOld: mask = kInMovedFrom; cookie = ++q.cookie; break;
    case kRenamedNew: mask = kInMovedTo; cookie = q.cookie; break;
    default: mask = kInModify; break;
  }
  if (directory) mask |= kInIsDir;
  q.emit(root_wd, mask, cookie, relative);
}

}  // namespace anj_watch
