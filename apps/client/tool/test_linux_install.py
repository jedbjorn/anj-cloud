#!/usr/bin/env python3
"""Real filesystem/process lifecycle checks. Synthetic ELFs are not release proof."""
import ctypes
import fcntl
import io
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from unittest.mock import patch

import linux_install as manager
import package_linux

ROOT = Path(__file__).resolve().parents[1]
CHILD = r'''
import ctypes, os, sys
lib = ctypes.CDLL(sys.argv[1])
lib.anj_profile_lock.argtypes = [ctypes.c_char_p, ctypes.c_int]
fd = lib.anj_profile_lock(os.fsencode(sys.argv[2]), int(sys.argv[3]))
if fd < 0:
 print('REFUSED', lib.anj_error(), flush=True)
 sys.exit(73)
print('LOCKED', fd, os.get_inheritable(fd), flush=True)
sys.stdin.readline()
'''


# Synthetic client ELF: adopts the inherited profile lock like the runner,
# records its argv, and (with a session bus) owns the per-profile activation
# name computed independently with GLib. `--own-name NAME` only owns NAME
# (a fake Secret Service / tray watcher) until stdin closes.
FIXTURE_RUNNER = r'''
#include <gio/gio.h>
#include <unistd.h>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <string>
extern "C" int anj_profile_lock(const char*, int);
static std::string profile_dir;
static void append(const char* name, const std::string& line) {
 std::ofstream(profile_dir + "/" + name, std::ios::app) << line << "\n";
}
static void on_call(GDBusConnection*, const gchar*, const gchar*, const gchar*, const gchar* method,
                    GVariant*, GDBusMethodInvocation* invocation, gpointer) {
 if (!strcmp(method, "Activate")) append("activations", "activated");
 g_dbus_method_invocation_return_value(invocation, nullptr);
}
static const GDBusInterfaceVTable vtable = {on_call, nullptr, nullptr, {nullptr}};
int main(int argc, char** argv) {
 if (argc == 3 && !strcmp(argv[1], "--own-name")) {
  GDBusConnection* bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, nullptr);
  if (!bus) return 70;
  GVariant* reply = g_dbus_connection_call_sync(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
      "org.freedesktop.DBus", "RequestName", g_variant_new("(su)", argv[2], 4u), G_VARIANT_TYPE("(u)"),
      G_DBUS_CALL_FLAGS_NONE, -1, nullptr, nullptr);
  if (!reply) return 71;
  std::cout << "OWNED" << std::endl;
  std::string ignored; std::getline(std::cin, ignored);
  return 0;
 }
 const char* profile = nullptr; int inherited = -1; bool background = false; std::string command;
 for (int i = 1; i < argc; ++i) {
  if (!strcmp(argv[i], "--profile-dir") && i+1 < argc) profile = argv[++i];
  else if (!strcmp(argv[i], "--profile-lock-fd") && i+1 < argc) inherited = atoi(argv[++i]);
  else if (!strcmp(argv[i], "--manager-command") && i+1 < argc) command = argv[++i];
  else if (!strcmp(argv[i], "--background")) background = true;
  else return 64;
 }
 if (!profile || anj_profile_lock(profile, inherited) < 0) return 73;
 profile_dir = profile;
 append("launch-args", std::string("background=") + (background ? "1" : "0") + " manager=" + command);
 if (getenv("DBUS_SESSION_BUS_ADDRESS")) {
  GDBusConnection* bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, nullptr);
  gchar* digest = g_compute_checksum_for_string(G_CHECKSUM_SHA256, profile, -1);
  std::string name = std::string("cloud.anj.AnjCloud.p") + std::string(digest).substr(0, 32);
  g_free(digest);
  GDBusNodeInfo* node = g_dbus_node_info_new_for_xml(
      "<node><interface name='cloud.anj.AnjCloud1'><method name='Activate'/></interface></node>", nullptr);
  if (!bus || !node || !g_dbus_connection_register_object(bus, "/cloud/anj/AnjCloud", node->interfaces[0],
      &vtable, nullptr, nullptr, nullptr)) return 70;
  GVariant* reply = g_dbus_connection_call_sync(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
      "org.freedesktop.DBus", "RequestName", g_variant_new("(su)", name.c_str(), 4u), G_VARIANT_TYPE("(u)"),
      G_DBUS_CALL_FLAGS_NONE, -1, nullptr, nullptr);
  if (!reply) return 71;
  append("worker-started", "worker");
  g_main_loop_run(g_main_loop_new(nullptr, FALSE));
 }
 append("worker-started", "worker");
 while (true) pause();
}
'''

BUS_CONFIG = """<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:dir={directory}</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
"""


class PrivateBus:
    """A private dbus-daemon with no service activation: never the user's
    session bus, and no real desktop service can be auto-started on it."""

    def __init__(self, directory):
        self.directory = Path(directory)
        config = self.directory / "bus.conf"
        config.write_text(BUS_CONFIG.format(directory=self.directory))
        self.process = subprocess.Popen(["dbus-daemon", f"--config-file={config}", "--nofork", "--nopidfile",
                                         "--print-address=1"], stdout=subprocess.PIPE, text=True)
        self.address = self.process.stdout.readline().strip()
        if not self.address:
            raise AssertionError("private dbus-daemon did not start")

    def close(self):
        self.process.terminate()
        self.process.wait(timeout=5)


def compile_fixture_runner(directory):
    source = Path(directory) / "runner.cc"
    source.write_text(FIXTURE_RUNNER)
    binary = Path(directory) / "fixture-runner"
    flags = subprocess.check_output(["pkg-config", "--cflags", "--libs", "gio-2.0"], text=True).split()
    subprocess.run(["clang++", "-std=c++17", str(source), str(ROOT / "native/posix/rootfs.cc"), "-o", str(binary), *flags],
                   check=True)
    return binary


def wait_for(predicate):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.01)
    raise AssertionError("Own fixture child did not reach expected boundary")


class NativeLifetime(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compilation = tempfile.TemporaryDirectory(prefix="anj-lifetime-native-")
        cls.library = Path(cls.compilation.name) / "libroot.so"
        wrapper = Path(cls.compilation.name) / "bootstrap.cc"
        wrapper.write_text('#include "' + str(ROOT / 'native/posix/lifecycle_bootstrap.h') + '"\nextern "C" int test_bootstrap(int argc, char** argv) { return anj_profile_argument_cloexec(argc, argv); }\n')
        subprocess.run(["clang++", "-std=c++17", "-Wall", "-Wextra", "-Werror", "-O2", "-fPIC", "-shared", str(ROOT / "native/posix/rootfs.cc"), str(wrapper), "-o", str(cls.library)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.compilation.cleanup()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="anj-lifetime-case-")
        self.profile = Path(self.temporary.name) / "profile"
        self.profile.mkdir(mode=0o700)
        self.children = []

    def tearDown(self):
        for child in self.children:
            if child.poll() is None:
                child.terminate()
            child.communicate(timeout=5)
        self.temporary.cleanup()

    def child(self, profile=None, inherited=-1):
        child = subprocess.Popen([sys.executable, "-c", CHILD, str(self.library), str(profile or self.profile), str(inherited)], pass_fds=(() if inherited < 0 else (inherited,)), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.children.append(child)
        return child, child.stdout.readline().strip()

    def test_canonical_alias_competes_separate_profile_and_crash_releases(self):
        first, output = self.child()
        self.assertIn("LOCKED", output)
        self.assertTrue(output.endswith("False"))
        alias = self.profile.parent / "alias"
        alias.symlink_to(self.profile, target_is_directory=True)
        refused, output = self.child(alias.resolve())
        self.assertEqual(output, "REFUSED 11")
        refused.wait(timeout=5)
        separate = self.profile.parent / "separate"
        separate.mkdir(mode=0o700)
        self.assertIn("LOCKED", self.child(separate)[1])
        first.kill()
        first.wait(timeout=5)
        self.assertIn("LOCKED", self.child()[1])

    def test_earliest_runner_cloexec_prevents_pre_dart_helper_lock_leak(self):
        script = r'''
import ctypes, os, subprocess, sys
lib = ctypes.CDLL(sys.argv[1])
args = [b'anj_cloud', b'--profile-dir', os.fsencode(sys.argv[2]), b'--profile-lock-fd', os.fsencode(sys.argv[3])]
argv = (ctypes.c_char_p * len(args))(*args)
lib.test_bootstrap.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_char_p)]
assert lib.test_bootstrap(len(args), argv) == 1
helper = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(15)'], close_fds=False)
print('HELPER', helper.pid, flush=True)
sys.stdin.readline()
'''
        with manager.exclusive(self.profile / '.instance.lock', profile=True) as fd:
            child = subprocess.Popen([sys.executable, '-c', script, str(self.library), str(self.profile), str(fd)], pass_fds=(fd,), stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
            self.children.append(child)
            helper = int(child.stdout.readline().split()[1])
        try:
            # App dies BEFORE Dart/full guard adoption. The toolkit helper lives.
            child.kill()
            child.wait(timeout=5)
            os.kill(helper, 0)
            self.assertIn('LOCKED', self.child()[1])
        finally:
            os.kill(helper, signal.SIGTERM)

    def test_handoff_holds_description_after_parent_close(self):
        with manager.exclusive(self.profile / ".instance.lock", profile=True) as fd:
            child, output = self.child(inherited=fd)
            self.assertIn("LOCKED", output)
            self.assertTrue(output.endswith("False"))
        with self.assertRaises(manager.Refused):
            with manager.exclusive(self.profile / ".instance.lock", profile=True):
                pass
        child.stdin.write("close\n")
        child.stdin.flush()
        child.wait(timeout=5)
        with manager.exclusive(self.profile / ".instance.lock", profile=True):
            pass

    def test_valid_unlocked_fd_is_reacquired_not_trusted_as_already_locked(self):
        fd = os.open(self.profile / ".instance.lock", os.O_RDWR | os.O_CREAT, 0o600)
        try:
            self.assertIn("LOCKED", self.child(inherited=fd)[1])
        finally:
            os.close(fd)
        with self.assertRaises(manager.Refused):
            with manager.exclusive(self.profile / ".instance.lock", profile=True):
                pass

    def test_parent_exits_handoff_before_native_adoption_has_no_gap(self):
        waiting = CHILD.replace("lib = ctypes.CDLL(sys.argv[1])", "print('WAITING', flush=True); sys.stdin.readline(); lib = ctypes.CDLL(sys.argv[1])")
        with manager.exclusive(self.profile / ".instance.lock", profile=True) as fd:
            child = subprocess.Popen([sys.executable, "-c", waiting, str(self.library), str(self.profile), str(fd)], pass_fds=(fd,), stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
            self.children.append(child)
            self.assertEqual(child.stdout.readline().strip(), "WAITING")
        # Parent has closed its descriptor; child has not called the native API.
        with self.assertRaises(manager.Refused):
            with manager.exclusive(self.profile / ".instance.lock", profile=True):
                pass
        child.stdin.write("adopt\n")
        child.stdin.flush()
        self.assertIn("LOCKED", child.stdout.readline())

    def test_wrong_inode_symlink_hardlink_mode_and_noncanonical_refused(self):
        (self.profile / ".instance.lock").touch(mode=0o600)
        other = self.profile.parent / "other"
        other.touch(mode=0o600)
        fd = os.open(other, os.O_RDWR)
        try:
            self.assertIn("REFUSED", self.child(inherited=fd)[1])
        finally:
            os.close(fd)
        slot = self.profile / ".instance.lock"
        slot.unlink()
        slot.symlink_to(other)
        self.assertIn("REFUSED", self.child()[1])
        slot.unlink()
        os.link(other, slot)
        self.assertIn("REFUSED", self.child()[1])
        slot.unlink()
        slot.touch(mode=0o644)
        self.assertIn("REFUSED", self.child()[1])
        slot.chmod(0o600)
        alias = self.profile.parent / "alias"
        alias.symlink_to(self.profile)
        self.assertIn("REFUSED", self.child(alias)[1])

    def test_external_exec_does_not_inherit_lifetime(self):
        script = CHILD.replace("sys.stdin.readline()", """
helper = __import__('subprocess').Popen([sys.executable, '-c', 'import time; time.sleep(15)'], close_fds=False)
print('HELPER', helper.pid, flush=True)
sys.stdin.readline()
""")
        child = subprocess.Popen([sys.executable, "-c", script, str(self.library), str(self.profile), "-1"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.children.append(child)
        self.assertIn("LOCKED", child.stdout.readline())
        helper = int(child.stdout.readline().split()[1])
        try:
            child.stdin.write("close\n")
            child.stdin.flush()
            child.wait(timeout=5)
            os.kill(helper, 0)  # helper is still alive, but cannot retain flock
            self.assertIn("LOCKED", self.child()[1])
        finally:
            os.kill(helper, signal.SIGTERM)


class PackageProvenance(unittest.TestCase):
    def test_bundled_manager_comes_from_committed_blob_despite_worktree_edit(self):
        with tempfile.TemporaryDirectory(prefix='anj-manager-source-') as temporary:
            root = Path(temporary)
            repo = root / 'repo'
            repo.mkdir()
            source = repo / 'apps/client/tool/linux_install.py'
            source.parent.mkdir(parents=True)
            committed = b"print('committed manager A')\n"
            source.write_bytes(committed)
            (repo / 'apps/client/release-version.json').write_text('{"version_code":167}\n')
            icon = repo / 'apps/client/assets/branding/harbor/icon-512.png'
            icon.parent.mkdir(parents=True)
            committed_icon = (ROOT / 'assets/branding/harbor/icon-512.png').read_bytes()
            icon.write_bytes(committed_icon)
            subprocess.run(['git', 'init', '-q', str(repo)], check=True)
            subprocess.run(['git', 'add', '.'], cwd=repo, check=True)
            subprocess.run(['git', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'Committed manager A'], cwd=repo, check=True)
            head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip()
            source.write_bytes(b"print('uncommitted manager B')\n")
            icon.write_bytes(b'uncommitted replacement icon')
            output = root / 'build-output'
            (output / 'bundle').mkdir(parents=True)
            (output / 'bundle/anj_cloud').write_bytes(b'private packaging fixture')
            bundled_icon = output / 'bundle' / manager.ICON_PAYLOAD
            bundled_icon.parent.mkdir(parents=True)
            bundled_icon.write_bytes(committed_icon)
            for evidence in ('elf-audit.json', 'dependency-resolution.json', 'build-toolchain.txt'):
                (output / evidence).write_text('{}')
            destination = root / 'artifact'
            with patch.object(package_linux, 'REPO', repo):
                package_linux._package(destination, head, output, {}, 'fixture-image')
            bundle = destination / f'anj-cloud-linux-x86_64-{head[:12]}'
            self.assertEqual((bundle / 'linux_install.py').read_bytes(), committed)
            receipt = json.loads((bundle / 'bundle-receipt.json').read_text())
            self.assertEqual(receipt['source_head'], head)
            # Public history may have only one commit; the allocated release is still 167.
            self.assertEqual((receipt['version_code'], receipt['version'][-4:]), (167, '.167'))
            self.assertEqual(receipt['files_sha256']['linux_install.py'], manager.digest(bundle / 'linux_install.py'))
            self.assertEqual((bundle / manager.ICON_PAYLOAD).read_bytes(), committed_icon)
            self.assertEqual(receipt['files_sha256'][manager.ICON_PAYLOAD], manager.digest(bundle / manager.ICON_PAYLOAD))
            bundled_icon.write_bytes(b'mismatched build icon')
            with patch.object(package_linux, 'REPO', repo):
                with self.assertRaisesRegex(ValueError, 'icon'):
                    package_linux._package(root / 'bad-artifact', head, output, {}, 'fixture-image')
            self.assertFalse((root / 'bad-artifact').exists())


class ManagerFiles(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='anj install " % $ ` \\ ')
        self.home = Path(self.temporary.name)
        self.env = patch.dict(os.environ, {"HOME": str(self.home), "XDG_DATA_HOME": str(self.home / "data %"), "XDG_CONFIG_HOME": str(self.home / "config \""), "XDG_STATE_HOME": str(self.home / "state")})
        self.env.start()
        # Never the user's session bus: tests that need one start a private bus.
        os.environ.pop("DBUS_SESSION_BUS_ADDRESS", None)
        self.installation = manager.Installation()
        self.runtime = patch.object(manager, "runtime_check")
        self.runtime.start()
        self.counter = 0

    def tearDown(self):
        self.runtime.stop()
        self.env.stop()
        # Published immutable program files are only made removable in this own
        # disposable test tree, never by the production installer.
        for path in self.home.rglob("*"):
            if path.is_dir() and not path.is_symlink():
                path.chmod(0o700)
        self.temporary.cleanup()

    def archive(self, *, source=None, extra=None, receipt_change=None, mutate=None):
        self.counter += 1
        source = source or f"{self.counter:040x}"
        name = f"anj-cloud-linux-x86_64-{source[:12]}"
        root = self.home / f"payload-{self.counter}" / name
        root.mkdir(parents=True, mode=0o700)
        for relative in manager.REQUIRED:
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            if relative == 'linux_install.py':
                payload = (ROOT / 'tool/linux_install.py').read_bytes()
            elif relative == manager.ICON_PAYLOAD:
                payload = (ROOT / 'assets/branding/harbor/icon-512.png').read_bytes()
            else:
                payload = b"fixture\n"
            target.write_bytes(payload)
            target.chmod(0o700 if relative == "anj_cloud" else 0o600)
        if mutate:
            mutate(root)
        receipt = {"source_head": source, "platform": "Linux x86_64", "profile_lifetime_protocol": 1,
                   "files_sha256": {relative: manager.digest(root / relative) for relative in manager.REQUIRED}}
        if receipt_change:
            receipt_change(receipt)
        (root / "bundle-receipt.json").write_text(json.dumps(receipt))
        archive = self.home / f"archive-{self.counter}.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            tar.add(root, arcname=name)
            if extra:
                extra(tar, name)
        return archive, manager.digest(archive)

    def install(self, archive=None, expected=None, **kwargs):
        if archive is None:
            archive, expected = self.archive()
        return manager.install(self.installation, archive, expected, **kwargs)

    def assert_preserved(self, state):
        self.assertEqual(manager.read_json(self.installation.state_file), state)
        self.assertEqual((Path(state["profile"]) / "sentinel").read_bytes(), b"paired data\n")

    def initial(self):
        state = self.install()
        (Path(state["profile"]) / "sentinel").write_bytes(b"paired data\n")
        return state

    def test_install_update_keep_profile_payload_and_launcher_argv(self):
        first = self.initial()
        second = self.install()
        self.assertEqual(first["profile"], second["profile"])
        self.assertEqual(second["previous"], first["release"])
        self.assertTrue((self.installation.releases / first["release"] / "anj_cloud").exists())
        self.assertEqual((self.installation.releases / second["release"]).stat().st_mode & 0o777, 0o500)
        # Execute the generated launcher in a path containing quotes, backslash,
        # percent, dollar and backtick. It uses execv literals, not shell parsing.
        result = subprocess.run([self.installation.layout["command"], "status"], capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(result.stdout)["source"], second["source"])
        subprocess.run(["desktop-file-validate", self.installation.layout["desktop"]], check=True)
        self.assertIn("%%", Path(self.installation.layout["desktop"]).read_text())
        self.assert_preserved(second)

    def test_harbor_icon_is_receipted_and_desktop_resolves_literal_owned_path(self):
        first = self.initial()
        icon = Path(self.installation.layout['data']) / 'icons' / manager.ICON_NAME
        payload = self.installation.releases / first['release'] / manager.ICON_PAYLOAD
        self.assertEqual(icon.read_bytes(), (ROOT / 'assets/branding/harbor/icon-512.png').read_bytes())
        receipt = manager.read_json(self.installation.releases / first['release'] / 'bundle-receipt.json')
        self.assertEqual(receipt['files_sha256'][manager.ICON_PAYLOAD], manager.digest(icon))
        desktop = Path(self.installation.layout['desktop'])
        self.assertIn('Name=AnJ Cloud\n', desktop.read_text())
        self.assertIn('StartupWMClass=cloud.anj.anj_cloud\n', desktop.read_text())
        # Actual GIO parsing checks generic desktop escaping separately from
        # Exec escaping, including literal percent signs and backslashes.
        gio = ctypes.CDLL('libgio-2.0.so.0')
        gio.g_desktop_app_info_new_from_filename.argtypes = [ctypes.c_char_p]
        gio.g_desktop_app_info_new_from_filename.restype = ctypes.c_void_p
        gio.g_app_info_get_icon.argtypes = [ctypes.c_void_p]
        gio.g_app_info_get_icon.restype = ctypes.c_void_p
        gio.g_icon_to_string.argtypes = [ctypes.c_void_p]
        gio.g_icon_to_string.restype = ctypes.c_void_p
        glib = ctypes.CDLL('libglib-2.0.so.0')
        glib.g_free.argtypes = [ctypes.c_void_p]
        gobject = ctypes.CDLL('libgobject-2.0.so.0')
        gobject.g_object_unref.argtypes = [ctypes.c_void_p]
        info = gio.g_desktop_app_info_new_from_filename(os.fsencode(desktop))
        self.assertTrue(info)
        value = None
        try:
            value = gio.g_icon_to_string(gio.g_app_info_get_icon(info))
            self.assertEqual(os.fsdecode(ctypes.string_at(value)), str(icon))
        finally:
            if value:
                glib.g_free(value)
            gobject.g_object_unref(info)
        second = self.install()
        self.assert_preserved(second)
        self.assertEqual(icon.read_bytes(), payload.read_bytes())
        self.assertFalse((Path(os.environ['XDG_DATA_HOME']) / 'icons').exists())

    def legacy_desktop(self):
        desktop = Path(self.installation.layout['desktop'])
        entry = desktop.read_text().replace('Name=AnJ Cloud\n', 'Name=anj-cloud\n', 1)
        entry = '\n'.join(line for line in entry.split('\n')
                          if not line.startswith(('Icon=', 'StartupWMClass=')))
        desktop.write_text(entry)
        return desktop, entry

    def test_exact_legacy_desktop_upgrades_and_failure_keeps_icon_independent_of_activation(self):
        first = self.initial()
        desktop, _ = self.legacy_desktop()
        icon = Path(self.installation.layout['data']) / 'icons' / manager.ICON_NAME
        icon.unlink()
        archive, expected = self.archive()
        original = manager.atomic_json
        def fail_activation(path, value):
            if path == self.installation.state_file:
                raise OSError('publication failed')
            original(path, value)
        with patch.object(manager, 'atomic_json', side_effect=fail_activation):
            with self.assertRaisesRegex(OSError, 'publication failed'):
                self.install(archive, expected)
        self.assert_preserved(first)
        self.assertIn('Name=AnJ Cloud\n', desktop.read_text())
        self.assertIn('Icon=' + manager.desktop_value(str(icon)) + '\n', desktop.read_text())
        self.assertNotIn(str(self.installation.releases), desktop.read_text())
        self.assertEqual(icon.read_bytes(), (ROOT / 'assets/branding/harbor/icon-512.png').read_bytes())
        second = self.install(archive, expected)
        self.assert_preserved(second)
        self.assertEqual(second['previous'], first['release'])

    def test_modified_desktop_and_icon_collision_refuse_without_profile_or_activation_change(self):
        first = self.initial()
        desktop, legacy = self.legacy_desktop()
        icon = Path(self.installation.layout['data']) / 'icons' / manager.ICON_NAME
        icon.unlink()
        modified = legacy + '# user modification\n'
        desktop.write_text(modified)
        with self.assertRaisesRegex(manager.Refused, 'Managed integration changed'):
            self.install()
        self.assert_preserved(first)
        self.assertEqual(desktop.read_text(), modified)
        self.assertFalse(icon.exists())
        desktop.write_text(legacy)
        icon.write_bytes(b'unrelated icon')
        with self.assertRaisesRegex(manager.Refused, 'icon collision'):
            self.install()
        self.assert_preserved(first)
        self.assertEqual(desktop.read_text(), legacy)
        self.assertEqual(icon.read_bytes(), b'unrelated icon')
        icon.unlink()
        command = Path(self.installation.layout['command'])
        command.write_text(command.read_text() + '# user modification\n')
        with self.assertRaisesRegex(manager.Refused, 'Managed integration changed'):
            self.install()
        self.assert_preserved(first)
        self.assertEqual(desktop.read_text(), legacy)
        self.assertFalse(icon.exists())

    def test_desktop_exec_really_launches_literal_quoted_percent_argv(self):
        self.initial()
        output = self.home / 'desktop argv.json'
        probe = self.home / 'probe " % $ ` \\ executable'
        probe.write_text('#!' + sys.executable + '\nimport json, pathlib, sys\npathlib.Path(' + repr(str(output)) + ').write_text(json.dumps(sys.argv))\n')
        probe.chmod(0o700)
        argument = 'literal " % $ ` \\ argument'
        desktop = self.home / 'argv.desktop'
        desktop.write_text('[Desktop Entry]\nType=Application\nName=Own argument probe\nExec=' + manager.desktop_quote(sys.executable) + ' ' + manager.desktop_quote(str(probe)) + ' ' + manager.desktop_quote(argument) + '\n')
        subprocess.run(['desktop-file-validate', str(desktop)], check=True)
        launched = subprocess.run(['gio', 'launch', str(desktop)], capture_output=True, text=True)
        self.assertEqual(launched.returncode, 0, launched.stderr)
        wait_for(output.exists)
        self.assertEqual(json.loads(output.read_text()), [str(probe), argument])

    def test_verified_snapshot_cannot_be_switched_by_original_path_replacement(self):
        archive, expected = self.archive()
        original_source = f'{self.counter:040x}'
        replacement, _ = self.archive()
        open_tar = manager.tarfile.open
        def switch_input(path, *args, **kwargs):
            archive.write_bytes(replacement.read_bytes())
            self.assertEqual(Path(path).name, '.verified-input.tar.gz')
            return open_tar(path, *args, **kwargs)
        with patch.object(manager.tarfile, 'open', side_effect=switch_input):
            installed = self.install(archive, expected)
        self.assertEqual(installed['source'], original_source)
        self.assertNotEqual(manager.digest(archive), expected)

    def test_member_and_size_limits_refuse_before_activation(self):
        first = self.initial()
        archive, expected = self.archive()
        with patch.object(manager, 'MAX_MEMBERS', 2):
            with self.assertRaisesRegex(manager.Refused, 'members'):
                self.install(archive, expected)
        with patch.object(manager, 'MAX_BYTES', 10):
            with self.assertRaisesRegex(manager.Refused, 'size limit'):
                self.install(archive, expected)
        self.assert_preserved(first)

    def test_bad_digest_and_missing_dependency_leave_activation_unchanged(self):
        first = self.initial()
        archive, expected = self.archive()
        with self.assertRaises(manager.Refused):
            self.install(archive, "0" * 64)
        with patch.object(manager, "runtime_check", side_effect=manager.Refused("missing GTK")):
            with self.assertRaisesRegex(manager.Refused, "GTK"):
                self.install(archive, expected)
        self.assert_preserved(first)

    def test_unsafe_archive_members_and_receipts_preserve_previous(self):
        first = self.initial()
        def member(name, kind=tarfile.REGTYPE):
            def append(tar, top):
                info = tarfile.TarInfo(name.replace("TOP", top))
                info.type = kind
                info.linkname = "/tmp/unrelated"
                tar.addfile(info, io.BytesIO())
            return append
        cases = [member("../outside"), member("/absolute"), member("TOP/anj_cloud"),
                 member("TOP/link", tarfile.SYMTYPE), member("TOP/link", tarfile.LNKTYPE),
                 member("TOP/device", tarfile.CHRTYPE), member("TOP/unexpected")]
        for extra in cases:
            with self.subTest(extra=extra):
                archive, expected = self.archive(extra=extra)
                with self.assertRaises(manager.Refused):
                    self.install(archive, expected)
                self.assert_preserved(first)
        for change in (lambda r: r.update(platform="Darwin arm64"), lambda r: r.pop("profile_lifetime_protocol"),
                       lambda r: r['files_sha256'].pop(manager.ICON_PAYLOAD),
                       lambda r: r["files_sha256"].pop("anj_cloud"), lambda r: r["files_sha256"].update(anj_cloud="0" * 64)):
            archive, expected = self.archive(receipt_change=change)
            with self.assertRaises(manager.Refused):
                self.install(archive, expected)
            self.assert_preserved(first)

    def test_extraction_space_and_activation_failure_preserve_previous(self):
        first = self.initial()
        archive, expected = self.archive()
        with patch.object(manager.shutil, "copyfileobj", side_effect=OSError(28, "No space left")):
            with self.assertRaises(OSError):
                self.install(archive, expected)
        self.assert_preserved(first)
        original = manager.atomic_json
        def fail_activation(path, value):
            if path == self.installation.state_file:
                raise OSError("publication failed")
            original(path, value)
        with patch.object(manager, "atomic_json", side_effect=fail_activation):
            with self.assertRaises(OSError):
                self.install(archive, expected)
        self.assert_preserved(first)
        self.assertEqual(self.install(archive, expected)["profile"], first["profile"])

    def test_real_interruption_before_activation_keeps_old_manager_and_release(self):
        first = self.initial()
        archive, expected = self.archive()
        script = """
import sys
sys.path.insert(0, sys.argv[1])
import linux_install as m
m.runtime_check = lambda *a, **k: None
original = m.atomic_json
def barrier(path, value):
 if path.name == 'active.json':
  print('BEFORE_ACTIVATION', flush=True)
  sys.stdin.readline()
 original(path, value)
m.atomic_json = barrier
m.install(m.Installation(), sys.argv[2], sys.argv[3])
"""
        child = subprocess.Popen([sys.executable, "-c", script, str(ROOT / "tool"), str(archive), expected], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertEqual(child.stdout.readline().strip(), "BEFORE_ACTIVATION")
            child.kill()
            child.communicate(timeout=5)
        finally:
            if child.poll() is None:
                child.kill()
                child.communicate(timeout=5)
        self.assert_preserved(first)
        result = subprocess.run([self.installation.layout["command"], "status"], capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(result.stdout)["source"], first["source"])
        self.assertEqual(self.install(archive, expected)["profile"], first["profile"])

    def test_native_managed_direct_launch_and_updater_race(self):
        # This ELF exercises actual inherited-FD argument handling and a worker
        # marker after the gate. It is a fixture, not a second source release.
        binary = compile_fixture_runner(self.home)
        def executable(root):
            (root / 'anj_cloud').write_bytes(binary.read_bytes())
        # mutate before hash capture is intentional for this valid fixture.
        archive, expected = self.archive(mutate=executable)
        state = self.install(archive, expected)
        marker = Path(state['profile']) / 'worker-started'
        launched, child = manager.launch(self.installation)
        try:
            wait_for(marker.exists)
            self.assertEqual(marker.read_text(), 'worker\n')
            with self.assertRaisesRegex(manager.Refused, 'already running'):
                manager.launch(self.installation)
            with self.assertRaisesRegex(manager.Refused, 'already running'):
                self.install()
            direct = subprocess.run([str(self.installation.releases / state['release'] / 'anj_cloud'), '--profile-dir', state['profile']], timeout=5)
            self.assertEqual(direct.returncode, 73)
            self.assertEqual(marker.read_text(), 'worker\n')
        finally:
            self.assertEqual(launched['pid'], child.pid)
            child.kill()
            child.wait(timeout=5)
        # Conversely an updater holds transaction -> profile and a concurrent
        # launcher/direct binary cannot pass it. No second worker marker appears.
        with manager.exclusive(self.installation.lock_file):
            with manager.exclusive(Path(state['profile']) / '.instance.lock', profile=True):
                with self.assertRaisesRegex(manager.Refused, 'transaction'):
                    manager.launch(self.installation)
                direct = subprocess.run([str(self.installation.releases / state['release'] / 'anj_cloud'), '--profile-dir', state['profile']], timeout=5)
                self.assertEqual(direct.returncode, 73)
        self.assertEqual(marker.read_text(), 'worker\n')

    def test_bootstrap_selection_race_refuses_stale_installed_manager(self):
        first = self.initial()
        old_program = Path(self.installation.layout['data']) / 'managers' / (first['manager_sha256'] + '.py')
        script = """
import importlib.util, sys
spec = importlib.util.spec_from_file_location('oldmanager', sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.runtime_check = lambda *a, **k: None
print('OLD_MANAGER_LOADED', flush=True)
sys.stdin.readline()
try:
 if sys.argv[2] == 'run': m.launch(m.Installation())
 else: m.install(m.Installation(), sys.argv[3], sys.argv[4])
except m.Refused as error:
 print(str(error), flush=True)
 sys.exit(73)
sys.exit(99)
"""
        # Real separate code revision for the manager mechanics fixture. This is
        # not presented as the required two real application source releases.
        def new_manager(root):
            path = root / 'linux_install.py'
            path.write_bytes(path.read_bytes() + b'\n# synthetic updated manager fixture\n')
        archive, expected = self.archive(mutate=new_manager)
        next_archive, next_expected = self.archive()
        children = []
        try:
            for action in ('run', 'update'):
                child = subprocess.Popen([sys.executable, '-c', script, str(old_program), action, str(next_archive), next_expected], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                children.append(child)
                self.assertEqual(child.stdout.readline().strip(), 'OLD_MANAGER_LOADED')
            second = self.install(archive, expected)
            self.assertNotEqual(second['manager_sha256'], first['manager_sha256'])
            for child in children:
                child.stdin.write('enter after activation\n')
                child.stdin.flush()
                output, errors = child.communicate(timeout=5)
                self.assertEqual(child.returncode, 73, errors)
                self.assertIn('Installation changed', output)
            # Stable launcher now runs the newly selected, verified manager code.
            result = subprocess.run([self.installation.layout['command'], 'status'], capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(result.stdout)['manager_sha256'], second['manager_sha256'])
            self.assert_preserved(second)
        finally:
            for child in children:
                if child.poll() is None:
                    child.kill()
                child.communicate(timeout=5)

    def test_installed_command_updates_bundled_manager_with_archive_only(self):
        first = self.initial()
        # The actual installed command performs the update and executes normal
        # validation except host ELF prerequisites, using a controlled module
        # preloader solely inside this subprocess fixture.
        def new_manager(root):
            path = root / 'linux_install.py'
            path.write_bytes(path.read_bytes() + b'\n# second synthetic manager code\n')
        archive, expected = self.archive(mutate=new_manager)
        selected = self.installation.releases / first['release'] / 'linux_install.py'
        # runpy invokes the exact installed manager bytes with the usual CLI;
        # patching runtime_check in its module avoids fake ELF acceptance claims.
        script = """
import runpy, sys
ns = runpy.run_path(sys.argv[1], run_name='fixturemanager')
ns['main'].__globals__['runtime_check'] = lambda *a, **k: None
sys.argv = [sys.argv[1], 'update', sys.argv[2], '--sha256', sys.argv[3]]
sys.exit(ns['main']())
"""
        # The source file has identical bytes to the installed selected manager.
        actual_manager = Path(self.installation.layout['data']) / 'managers' / (first['manager_sha256'] + '.py')
        self.assertEqual(manager.digest(selected), manager.digest(actual_manager))
        result = subprocess.run([sys.executable, '-c', script, str(actual_manager), str(archive), expected], capture_output=True, text=True, check=True)
        second = json.loads(result.stdout)
        self.assertEqual(second['previous'], first['release'])
        self.assertNotEqual(second['manager_sha256'], first['manager_sha256'])
        self.assert_preserved(second)

    def test_existing_profile_explicit_ack_and_update_cannot_retarget(self):
        existing = self.home / "existing profile"
        existing.mkdir(mode=0o700)
        (existing / "manifest.sqlite").write_bytes(b"not touched")
        alias = self.home / "alias"
        alias.symlink_to(existing)
        archive, expected = self.archive()
        with self.assertRaisesRegex(manager.Refused, "legacy-app-closed"):
            self.install(archive, expected, profile=alias)
        state = self.install(archive, expected, profile=alias, legacy_closed=True)
        self.assertEqual(state["profile"], str(existing))
        self.assertEqual((existing / "manifest.sqlite").read_bytes(), b"not touched")
        with self.assertRaisesRegex(manager.Refused, "cannot change"):
            self.install(profile=self.home / "other")

    def test_unavailable_selected_profile_is_never_recreated(self):
        first = self.initial()
        profile = Path(first['profile'])
        retained = profile.with_name('temporarily-unavailable-profile')
        profile.rename(retained)
        archive, expected = self.archive()
        for operation in (self.installation.active, lambda: manager.launch(self.installation), lambda: self.install(archive, expected)):
            with self.assertRaisesRegex(manager.Refused, 'unavailable'):
                operation()
            self.assertFalse(profile.exists())
            self.assertEqual(manager.read_json(self.installation.state_file), first)
            self.assertEqual((retained / 'sentinel').read_bytes(), b'paired data\n')
        status = subprocess.run([self.installation.layout['command'], 'status'], capture_output=True, text=True)
        self.assertNotEqual(status.returncode, 0)
        self.assertIn('unavailable', status.stderr)
        self.assertFalse(profile.exists())

    def test_live_profile_and_transaction_lock_refuse_update(self):
        first = self.initial()
        archive, expected = self.archive()
        with manager.exclusive(Path(first["profile"]) / ".instance.lock", profile=True):
            with self.assertRaisesRegex(manager.Refused, "already running"):
                self.install(archive, expected)
        with manager.exclusive(self.installation.lock_file):
            with self.assertRaisesRegex(manager.Refused, "transaction"):
                self.install(archive, expected)
        self.assert_preserved(first)

    def test_unrelated_launcher_symlink_and_nonprivate_profile_are_not_repaired(self):
        command = self.home / ".local/bin/anj-cloud"
        command.parent.mkdir(parents=True)
        command.write_text("unrelated")
        with self.assertRaisesRegex(manager.Refused, "collision"):
            self.install()
        self.assertEqual(command.read_text(), "unrelated")
        command.unlink()
        command.symlink_to(self.home / "absent")
        with self.assertRaises(manager.Refused):
            self.install()
        command.unlink()
        existing = self.home / "not private"
        existing.mkdir(mode=0o755)
        with self.assertRaisesRegex(manager.Refused, "private"):
            self.install(profile=existing, legacy_closed=True)
        self.assertEqual(existing.stat().st_mode & 0o777, 0o755)


    # --- Spec #16: autostart, login start, single-instance activation -------

    def autostart_path(self):
        return Path(os.environ["XDG_CONFIG_HOME"]) / "autostart" / manager.AUTOSTART_NAME

    def cli(self, *arguments, program=None, env=None, patch_runtime=True):
        """The real manager CLI (main) in a subprocess; runtime_check is
        replaced only because fixture payloads are not real ELF releases."""
        script = """
import runpy, sys
ns = runpy.run_path(sys.argv[1], run_name='fixturemanager')
if sys.argv[2] == '1':
    ns['main'].__globals__['runtime_check'] = lambda *a, **k: None
ns['main'].__globals__['LOGIN_WAIT_SECONDS'] = float(sys.argv[3])
ns['main'].__globals__['LOGIN_POLL_SECONDS'] = 0.05
sys.argv = [sys.argv[1], '--installation', sys.argv[4], *sys.argv[5:]]
sys.exit(ns['main']())
"""
        program = program or (Path(self.installation.layout['data']) / 'managers'
                              / (manager.read_json(self.installation.state_file)['manager_sha256'] + '.py'))
        return subprocess.run([sys.executable, '-c', script, str(program), '1' if patch_runtime else '0',
                               str(getattr(self, 'login_wait', 2)), str(self.installation.config), *arguments],
                              capture_output=True, text=True, env=env, timeout=60)

    def fixture_install(self):
        binary = compile_fixture_runner(self.home)
        def executable(root):
            (root / 'anj_cloud').write_bytes(binary.read_bytes())
        archive, expected = self.archive(mutate=executable)
        return self.install(archive, expected)

    def private_bus(self, *, secrets=True):
        # Plain short directory: socket paths and the bus XML stay literal.
        directory = tempfile.mkdtemp(prefix="anj-bus-")
        self.addCleanup(shutil.rmtree, directory, True)
        bus = PrivateBus(directory)
        self.addCleanup(bus.close)
        os.environ["DBUS_SESSION_BUS_ADDRESS"] = bus.address
        os.environ.setdefault("WAYLAND_DISPLAY", "fixture-display")
        if secrets:
            self.own_name("org.freedesktop.secrets")
        return bus

    def own_name(self, name):
        runner = self.home / 'fixture-runner'
        if not runner.exists():
            compile_fixture_runner(self.home)
        owner = subprocess.Popen([str(runner), '--own-name', name], stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, text=True)
        def stop():
            owner.stdin.close()
            owner.wait(timeout=5)
        self.addCleanup(stop)
        self.assertEqual(owner.stdout.readline().strip(), 'OWNED')
        return owner

    def kill_client(self, profile):
        # The fixture client is detached; find it through its own lock holder.
        result = subprocess.run(['fuser', str(Path(profile) / '.instance.lock')], capture_output=True, text=True)
        for pid in result.stdout.split():
            os.kill(int(pid), signal.SIGKILL)

    def test_activation_name_matches_client_vector(self):
        # Same vector as test/lifecycle_test.dart (Dart) and GLib in the fixture.
        self.assertEqual(manager.activation_name('/home/user/.local/share/anj-cloud/profiles/default'),
                         'cloud.anj.AnjCloud.p1375a8456229d3fabd546f85d6acf6b2')
        self.assertEqual(manager.activation_name('/tmp/profile " % $ é'),
                         'cloud.anj.AnjCloud.p38a88d30f064480aa4bebb125cea351a')

    def test_fresh_install_enables_exact_owned_autostart_and_keeps_layout_keys(self):
        state = self.initial()
        path = self.autostart_path()
        content = path.read_bytes()
        self.assertEqual(content, manager.autostart_entry(self.installation))
        self.assertIn(b'run --background\n', content)
        self.assertIn(f'X-Anj-Cloud-Owner={manager.OWNER}\n'.encode(), content)
        subprocess.run(['desktop-file-validate', str(path)], check=True)
        settings = manager.read_json(self.installation.autostart_file)
        self.assertEqual(settings['source'], 'default')
        self.assertTrue(settings['enabled'])
        # installation.json keeps exactly the keys older managers accept.
        self.assertEqual(set(manager.read_json(self.installation.layout_file)),
                         {"owner", "data", "state", "command", "desktop"})
        status = json.loads(subprocess.run([self.installation.layout['command'], 'status'],
                                           capture_output=True, text=True, check=True).stdout)
        self.assertTrue(status['autostart']['enabled'])
        self.assertEqual(status['source'], state['source'])

    def test_autostart_exec_runs_stable_command_in_background_mode(self):
        self.initial()
        # Real GIO parsing of the generated Exec line (literal quotes, %, $).
        gio = ctypes.CDLL('libgio-2.0.so.0')
        gio.g_desktop_app_info_new_from_filename.argtypes = [ctypes.c_char_p]
        gio.g_desktop_app_info_new_from_filename.restype = ctypes.c_void_p
        gio.g_app_info_get_commandline.argtypes = [ctypes.c_void_p]
        gio.g_app_info_get_commandline.restype = ctypes.c_char_p
        glib = ctypes.CDLL('libglib-2.0.so.0')
        glib.g_shell_parse_argv.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_int),
                                            ctypes.POINTER(ctypes.POINTER(ctypes.c_char_p)), ctypes.c_void_p]
        gobject = ctypes.CDLL('libgobject-2.0.so.0')
        gobject.g_object_unref.argtypes = [ctypes.c_void_p]
        info = gio.g_desktop_app_info_new_from_filename(os.fsencode(self.autostart_path()))
        self.assertTrue(info)
        try:
            # GIO expands %% to % (no other field codes here), then parses.
            line = gio.g_app_info_get_commandline(info).replace(b'%%', b'%')
            count, argv = ctypes.c_int(), ctypes.POINTER(ctypes.c_char_p)()
            self.assertTrue(glib.g_shell_parse_argv(line, ctypes.byref(count), ctypes.byref(argv), None))
            parsed = [os.fsdecode(argv[i]) for i in range(count.value)]
        finally:
            gobject.g_object_unref(info)
        self.assertEqual(parsed, [sys.executable, self.installation.layout['command'], 'run', '--background'])

    def test_disable_removes_exactly_and_is_never_reenabled_by_run_or_update(self):
        state = self.fixture_install()
        result = self.cli('autostart', 'disable')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(json.loads(result.stdout)['enabled'])
        self.assertFalse(self.autostart_path().exists())
        self.assertTrue(self.autostart_path().parent.exists())
        again = self.cli('autostart', 'disable')
        self.assertEqual(again.returncode, 0, again.stderr)
        self.fixture_install()  # an update by this manager
        launched, child = manager.launch(self.installation)
        try:
            self.assertFalse(self.autostart_path().exists())
        finally:
            child.kill()
            child.wait(timeout=5)
        self.assertEqual(manager.read_json(self.installation.autostart_file)['source'], 'user')
        enabled = self.cli('autostart', 'enable')
        self.assertEqual(enabled.returncode, 0, enabled.stderr)
        self.assertTrue(json.loads(enabled.stdout)['enabled'])
        before = self.autostart_path().stat()
        self.assertEqual(self.cli('autostart', 'enable').returncode, 0)
        after = self.autostart_path().stat()
        self.assertEqual((before.st_ino, before.st_mtime_ns), (after.st_ino, after.st_mtime_ns))
        self.assertEqual(self.autostart_path().read_bytes(), manager.autostart_entry(self.installation))
        self.assertEqual(Path(state['profile']), Path(manager.read_json(self.installation.state_file)['profile']))

    def test_foreign_or_edited_autostart_file_is_refused_never_overwritten_or_removed(self):
        path = self.autostart_path()
        path.parent.mkdir(parents=True)
        path.write_text('[Desktop Entry]\nType=Application\nName=Someone else\nExec=true\n')
        foreign = path.read_bytes()
        self.initial()  # default-on records the problem, never blocks install
        self.assertEqual(path.read_bytes(), foreign)
        settings = manager.read_json(self.installation.autostart_file)
        self.assertFalse(settings['enabled'])
        self.assertIn('left untouched', settings['problem'])
        for action in ('enable', 'disable'):
            result = self.cli('autostart', action)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('left untouched', result.stderr)
            self.assertEqual(path.read_bytes(), foreign)
        status = json.loads(self.cli('autostart', 'status').stdout)
        self.assertEqual((status['enabled'], status['file']), (False, 'foreign'))
        # Once the foreign file is gone the recorded problem no longer applies.
        path.unlink()
        status = json.loads(self.cli('autostart', 'status').stdout)
        self.assertEqual((status['enabled'], status['file'], status['problem']), (False, 'absent', None))
        path.write_bytes(foreign)
        # An owner-marked file changed outside AnJ Cloud is not ours either.
        path.unlink()
        self.assertEqual(self.cli('autostart', 'enable').returncode, 0)
        edited = path.read_bytes() + b'Hidden=true\n'
        path.write_bytes(edited)
        for action in ('enable', 'disable'):
            result = self.cli('autostart', action)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('changed outside', result.stderr)
            self.assertEqual(path.read_bytes(), edited)
        path.unlink()
        path.symlink_to(self.home / 'elsewhere.desktop')
        self.assertNotEqual(self.cli('autostart', 'enable').returncode, 0)
        self.assertTrue(path.is_symlink())
        self.assertFalse((self.home / 'elsewhere.desktop').exists())

    def test_previous_exact_entry_is_upgraded_and_removed_by_recorded_hash(self):
        self.initial()
        path = self.autostart_path()
        # A different interpreter path changes the expected Exec line; the
        # previously written bytes are still exactly ours (recorded hash).
        with patch.object(manager.sys, 'executable', sys.executable + '-other'):
            with manager.exclusive(self.installation.lock_file):
                result = manager.set_autostart(self.installation, True, 'user')
        self.assertTrue(result['enabled'])
        self.assertIn(b'-other', path.read_bytes())
        with manager.exclusive(self.installation.lock_file):
            self.assertTrue(manager.autostart_status(self.installation)['enabled'])
            manager.set_autostart(self.installation, False, 'user')
        self.assertFalse(path.exists())

    def test_unknown_autostart_settings_refuse_changes_but_not_launch_or_status(self):
        self.fixture_install()
        settings = manager.read_json(self.installation.autostart_file)
        settings['unexpected'] = True
        manager.atomic_json(self.installation.autostart_file, settings)
        before = self.autostart_path().read_bytes()
        result = self.cli('autostart', 'disable')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Unknown autostart settings', result.stderr)
        self.assertEqual(self.autostart_path().read_bytes(), before)
        status = subprocess.run([self.installation.layout['command'], 'status'], capture_output=True, text=True)
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertIn('Unknown autostart settings', json.loads(status.stdout)['autostart']['problem'])
        launched, child = manager.launch(self.installation)
        child.kill()
        child.wait(timeout=5)

    def test_existing_install_from_previous_manager_gets_default_on_at_first_new_manager_run(self):
        # The previously released manager (a2ba2380..., committed verbatim)
        # installs and then performs the update to this manager, exactly as
        # `anj-cloud update` does on existing installs.
        legacy = ROOT / 'tool/testdata/linux_install_a2ba2380.py'
        self.assertEqual(manager.digest(legacy), 'a2ba2380d9804bc12ca10c40f5ffd3f612621897c1ba11941155e3202be926fc')
        def old_manager(root):
            (root / 'linux_install.py').write_bytes(legacy.read_bytes())
        binary = compile_fixture_runner(self.home)
        def new_client(root):
            (root / 'anj_cloud').write_bytes(binary.read_bytes())
        old_archive, old_expected = self.archive(mutate=old_manager)
        installed = self.cli('install', str(old_archive), '--sha256', old_expected, program=legacy)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        first = json.loads(installed.stdout)
        self.assertEqual(first['manager_sha256'], manager.digest(legacy))
        self.assertFalse(self.installation.autostart_file.exists())
        self.assertFalse(self.autostart_path().exists())
        new_archive, new_expected = self.archive(mutate=new_client)
        self.installation.load()
        updated = self.cli('update', str(new_archive), '--sha256', new_expected)  # selected = old manager
        self.assertEqual(updated.returncode, 0, updated.stderr)
        second = json.loads(updated.stdout)
        self.assertEqual(second['manager_sha256'], manager.digest(ROOT / 'tool/linux_install.py'))
        # The old manager cannot know about login start; the update itself
        # writes nothing there and keeps installation.json readable by it.
        self.assertFalse(self.autostart_path().exists())
        status = json.loads(subprocess.run([self.installation.layout['command'], 'status'],
                                           capture_output=True, text=True, check=True).stdout)
        self.assertTrue(status['autostart']['default_pending'])
        # First run through the stable command (now the new manager).
        self.installation.load()
        launched, child = manager.launch(self.installation)
        try:
            self.assertEqual(self.autostart_path().read_bytes(), manager.autostart_entry(self.installation))
            self.assertEqual(manager.read_json(self.installation.autostart_file)['source'], 'default')
            args = (Path(second['profile']) / 'launch-args')
            wait_for(args.exists)
            self.assertIn(f"manager={self.installation.layout['command']}", args.read_text())
        finally:
            child.kill()
            child.wait(timeout=5)
        # The previous manager still reads this installation (no new
        # installation.json keys); autostart.json is invisible to it.
        old_status = self.cli('status', program=legacy)
        self.assertEqual(old_status.returncode, 0, old_status.stderr)
        self.assertEqual(json.loads(old_status.stdout)['source'], second['source'])

    def test_second_run_activates_running_instance_without_second_process(self):
        self.private_bus()
        state = self.fixture_install()
        profile = Path(state['profile'])
        first = self.cli('run', '--background')
        self.assertEqual(first.returncode, 0, first.stderr)
        launched = json.loads(first.stdout)
        self.addCleanup(self.kill_client, state['profile'])
        wait_for((profile / 'worker-started').exists)
        # Background run returned immediately (detached), the client lives on.
        os.kill(launched['pid'], 0)
        self.assertIn('background=1', (profile / 'launch-args').read_text())
        second = self.cli('run')
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(json.loads(second.stdout), {"already_running": True, "activated": True, "profile": state['profile']})
        wait_for((profile / 'activations').exists)
        self.assertEqual((profile / 'activations').read_text(), 'activated\n')
        self.assertEqual((profile / 'worker-started').read_text(), 'worker\n')
        # A login start while running stays quiet: no window, no process.
        third = self.cli('run', '--background')
        self.assertEqual(third.returncode, 0, third.stderr)
        self.assertTrue(json.loads(third.stdout)['already_running'])
        self.assertEqual((profile / 'activations').read_text(), 'activated\n')
        self.assertEqual((profile / 'worker-started').read_text(), 'worker\n')

    def test_second_run_without_activation_service_fails_clearly(self):
        state = self.fixture_install()  # no session bus: an older client case
        launched, child = manager.launch(self.installation)
        try:
            wait_for((Path(state['profile']) / 'worker-started').exists)
            result = self.cli('run')
            self.assertEqual(result.returncode, 1)
            self.assertIn('already running', result.stderr)
            self.assertIn('could not be shown', result.stderr)
        finally:
            child.kill()
            child.wait(timeout=5)

    def test_login_start_waits_for_bus_and_secret_service_then_starts_hidden(self):
        self.private_bus(secrets=False)
        state = self.fixture_install()
        profile = Path(state['profile'])
        self.login_wait = 20
        # The keyring appears one second after the login entry ran.
        runner = self.home / 'fixture-runner'
        delayed = subprocess.Popen(['sh', '-c', 'sleep 1; exec "$0" --own-name org.freedesktop.secrets', str(runner)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.addCleanup(lambda: (delayed.stdin.close(), delayed.wait(timeout=5)))
        started = time.monotonic()
        result = self.cli('run', '--background')
        self.addCleanup(self.kill_client, state['profile'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreaterEqual(time.monotonic() - started, 1)
        self.assertLess(time.monotonic() - started, 20)
        wait_for((profile / 'launch-args').exists)
        self.assertIn('background=1', (profile / 'launch-args').read_text())

    def test_login_start_without_keyring_starts_visible_and_without_bus_starts_nothing(self):
        self.private_bus(secrets=False)
        state = self.fixture_install()
        profile = Path(state['profile'])
        self.login_wait = 0.3
        result = self.cli('run', '--background')
        self.addCleanup(self.kill_client, state['profile'])
        self.assertEqual(result.returncode, 0, result.stderr)
        wait_for((profile / 'launch-args').exists)
        # Visible start: the app reports the locked keyring itself.
        self.assertIn('background=0', (profile / 'launch-args').read_text())
        log = (Path(self.installation.layout['state']) / 'manager.jsonl').read_text()
        self.assertIn('login_keyring_unavailable', log)
        self.kill_client(state['profile'])
        time.sleep(.2)
        environment = dict(os.environ)
        environment.pop('DBUS_SESSION_BUS_ADDRESS')
        (profile / 'launch-args').unlink()
        missing = self.cli('run', '--background', env=environment)
        self.assertEqual(missing.returncode, 1)
        self.assertIn('no graphical session bus', missing.stderr)
        self.assertFalse((profile / 'launch-args').exists())


def tree_snapshot(path):
    """Every entry's relative path, type, mode, size, mtime and bytes: proves a profile unmodified."""
    path = Path(path)
    snapshot = {}
    for item in sorted([path, *path.rglob("*")]):
        info = item.lstat()
        snapshot[str(item.relative_to(path))] = (info.st_mode, info.st_size, info.st_mtime_ns,
                                                 item.read_bytes() if item.is_file() else None)
    return snapshot


class ProfileSelection(unittest.TestCase):
    """Spec #23 production pairing: select-profile --new / select-profile <existing>."""

    setUp = ManagerFiles.setUp
    tearDown = ManagerFiles.tearDown
    archive = ManagerFiles.archive
    install = ManagerFiles.install

    def dev(self):
        """An installed, paired dev profile whose client root and staging are recorded in its manifest."""
        state = self.install()
        profile = Path(state["profile"])
        self.dev_root = self.home / "dev parent" / "anj-cloud"
        self.dev_staging = self.home / "dev parent" / ".anj-cloud-p1"
        for directory in (self.dev_root / "Documents", self.dev_staging):
            directory.mkdir(parents=True, mode=0o700)
        (self.dev_root / "Documents" / "synthetic.txt").write_text("fixture data\n")
        db = sqlite3.connect(profile / "manifest.sqlite")
        db.execute("CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        db.executemany("INSERT INTO settings VALUES (?,?)", [("root", str(self.dev_root)), ("staging", str(self.dev_staging)),
                                                             ("server", "https://127.0.0.1:8834"), ("certificate", "pem")])
        db.commit()
        db.close()
        return state, profile

    def active(self):
        return manager.read_json(self.installation.state_file)

    def test_new_profile_switches_activation_only_and_leaves_dev_profile_untouched(self):
        state, dev = self.dev()
        before = tree_snapshot(dev)
        new, root = self.home / "prod-profile", self.home / "AnjCloud"
        result = manager.select_new_profile(self.installation, new, root)
        self.assertEqual(result["profile"], str(new))
        self.assertEqual(result["previous_profile"], str(dev))
        self.assertIn(str(self.dev_root), result["known_roots"])
        self.assertEqual(self.active(), dict(state, profile=str(new)))
        self.assertEqual(tree_snapshot(dev), before)
        for directory in (new, root):
            self.assertEqual(list(directory.iterdir()), [])
            self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
        record = manager.read_json(self.installation.config / "profiles.json")
        self.assertEqual(record["profiles"], {str(dev): None, str(new): str(root)})
        # The stable command, desktop entry and autostart follow active.json; none names a profile.
        status = subprocess.run([self.installation.layout["command"], "status"], capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(status.stdout)["profile"], str(new))
        for integration in (Path(self.installation.layout["desktop"]), manager.default_autostart_path()):
            self.assertNotIn(str(dev), integration.read_text())
        with patch.object(manager.subprocess, "Popen") as popen:
            popen.return_value.pid = 4242
            launched, _ = manager.launch(self.installation)
        self.assertEqual(launched["profile"], str(new))
        argv = popen.call_args.args[0]
        self.assertEqual(argv[argv.index("--profile-dir") + 1], str(new))
        # Spec #34 P1: the reserved root reaches the app, which creates anj-cloud/ there itself.
        self.assertEqual(argv[argv.index("--default-root") + 1], str(root))

    def test_reserved_root_is_passed_only_until_the_app_records_its_root(self):
        state, dev = self.dev()
        with patch.object(manager.subprocess, "Popen") as popen:
            popen.return_value.pid = 4242
            manager.launch(self.installation)
        self.assertNotIn("--default-root", popen.call_args.args[0])  # dev: no reservation
        new = self.home / "prod-profile"
        manager.select_new_profile(self.installation, new, self.home)
        db = sqlite3.connect(new / "manifest.sqlite")
        db.execute("CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        db.execute("INSERT INTO settings VALUES ('root', ?)", (str(self.home / "anj-cloud"),))
        db.commit()
        db.close()
        with patch.object(manager.subprocess, "Popen") as popen:
            popen.return_value.pid = 4242
            manager.launch(self.installation)
        self.assertNotIn("--default-root", popen.call_args.args[0])

    def test_switching_back_leaves_desktop_shortcuts_alone(self):
        # Spec #34 P2.3: the app makes the AnJ Cloud link; profile switches never touch it.
        state, dev = self.dev()
        desktop = self.home / "Desktop"
        desktop.mkdir()
        (desktop / "AnJ Cloud").symlink_to(self.dev_root)
        prod = self.home / "prod"
        manager.select_new_profile(self.installation, prod, self.home / "AnjCloud")
        manager.select_existing_profile(self.installation, dev, True)
        self.assertEqual(os.readlink(desktop / "AnJ Cloud"), str(self.dev_root))
        self.assertEqual(sorted(entry.name for entry in desktop.iterdir()), ["AnJ Cloud"])

    def test_refuses_roots_whose_synced_folder_exists_or_overlaps_another_profile(self):
        state, dev = self.dev()
        filled = self.home / "filled"
        (filled / "anj-cloud").mkdir(parents=True, mode=0o700)
        (filled / "anj-cloud" / "synthetic.txt").write_text("x")
        linked = self.home / "linked"
        linked.mkdir(mode=0o700)
        (linked / "anj-cloud").symlink_to(self.home / "nowhere")
        # Another known profile whose recorded synced folder was deleted on disk still owns it.
        vanished = self.home / "gone parent"
        other = Path(self.installation.layout["data"]) / "profiles" / "other"
        other.mkdir(mode=0o700)
        db = sqlite3.connect(other / "manifest.sqlite")
        db.execute("CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        db.execute("INSERT INTO settings VALUES ('root', ?)", (str(vanished / "anj-cloud"),))
        db.commit()
        db.close()
        cases = {
            "root holding anj-cloud/": (self.home / "p1", filled, "already exists"),
            "anj-cloud/ is a dangling symlink": (self.home / "p1b", linked, "already exists"),
            "dev synced folder as root": (self.home / "p2", self.dev_root, "overlaps"),
            "inside dev synced folder": (self.home / "p3", self.dev_root / "Documents" / "new", "overlaps"),
            "inside dev staging": (self.home / "p4", self.dev_staging / "x", "overlaps"),
            "dev root parent (its anj-cloud/ exists)": (self.home / "p5", self.home / "dev parent", "already exists"),
            "inside dev profile": (self.home / "p6", dev / "root", "overlaps"),
            "another profile's deleted synced folder": (self.home / "p6b", vanished, "overlaps"),
            "profile inside dev synced folder": (self.dev_root / "profile", self.home / "r7", "overlaps"),
            "profile is dev profile": (dev, self.home / "r8", "not empty"),
            "profile inside the new synced folder": (self.home / "r9" / "anj-cloud" / "profile", self.home / "r9", "contain each other"),
            "synced folder inside installation": (self.home / "p10", Path(self.installation.layout["data"]) / "releases", "installation"),
            "non-empty profile": (filled, self.home / "r11", "not empty"),
            "root is a file": (self.home / "p12", Path(self.installation.layout["desktop"]), "not a directory"),
        }
        before = tree_snapshot(dev)
        for label, (profile, root, message) in cases.items():
            with self.subTest(label):
                existed = {p: p.exists() for p in (profile, root, root / "anj-cloud")}
                with self.assertRaisesRegex(manager.Refused, message):
                    manager.select_new_profile(self.installation, profile, root)
                self.assertEqual(self.active(), state)
                self.assertFalse((self.installation.config / "profiles.json").exists())
                for path, was in existed.items():
                    self.assertEqual(path.exists(), was)
        self.assertEqual(tree_snapshot(dev), before)
        self.assertFalse(vanished.exists())
        self.assertEqual((filled / "anj-cloud" / "synthetic.txt").read_text(), "x")

    def test_reserved_synced_folder_of_another_profile_is_refused_before_the_app_creates_it(self):
        self.dev()
        root = self.home / "AnjCloud"
        manager.select_new_profile(self.installation, self.home / "prod-a", root)
        current = self.active()
        with self.assertRaisesRegex(manager.Refused, "reserved synced folder"):
            manager.select_new_profile(self.installation, self.home / "prod-b", root)
        with self.assertRaisesRegex(manager.Refused, "reserved synced folder"):
            manager.select_new_profile(self.installation, self.home / "prod-c", root / "anj-cloud" / "x")
        self.assertEqual(self.active(), current)
        self.assertFalse((root / "anj-cloud").exists())

    def test_running_app_refuses_either_switch(self):
        state, dev = self.dev()
        with manager.exclusive(dev / ".instance.lock", profile=True):
            with self.assertRaisesRegex(manager.Refused, "already running"):
                manager.select_new_profile(self.installation, self.home / "prod", self.home / "AnjCloud")
        self.assertEqual(self.active(), state)
        self.assertFalse((self.home / "prod").exists() or (self.home / "AnjCloud").exists())
        manager.select_new_profile(self.installation, self.home / "prod", self.home / "AnjCloud")
        prod = self.home / "prod"
        (prod / ".instance.lock").touch(mode=0o600)
        for held in (prod, dev):
            with self.subTest(held=held.name), manager.exclusive(held / ".instance.lock", profile=True):
                with self.assertRaisesRegex(manager.Refused, "already running"):
                    manager.select_existing_profile(self.installation, dev, True)
            self.assertEqual(self.active()["profile"], str(prod))

    def test_reverse_switch_needs_the_adoption_guard_and_keeps_both_profiles(self):
        state, dev = self.dev()
        dev_before = tree_snapshot(dev)
        prod = self.home / "prod"
        manager.select_new_profile(self.installation, prod, self.home / "AnjCloud")
        (prod / "manifest.sqlite").write_bytes(b"production pairing")
        prod_before = tree_snapshot(prod)
        with self.assertRaisesRegex(manager.Refused, "legacy-app-closed"):
            manager.select_existing_profile(self.installation, dev, False)
        self.assertEqual(self.active()["profile"], str(prod))
        alias = self.home / "dev alias"
        alias.symlink_to(dev)
        result = manager.select_existing_profile(self.installation, alias, True)
        self.assertEqual((result["profile"], result["changed"]), (str(dev), True))
        self.assertEqual(self.active(), state)
        self.assertEqual(tree_snapshot(dev), dev_before)
        self.assertEqual(tree_snapshot(prod), prod_before)
        # And forward again: the production profile is known, so it is a plain switch.
        manager.select_existing_profile(self.installation, prod, True)
        self.assertEqual(self.active()["profile"], str(prod))
        status = subprocess.run([self.installation.layout["command"], "status"], capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(status.stdout)["profile"], str(prod))

    def test_home_folder_is_accepted_as_root_when_its_anj_cloud_folder_is_absent(self):
        state, dev = self.dev()
        home = self.home
        (home / "Documents").mkdir()
        (home / "Documents" / "letter.txt").write_text("personal\n")
        home.chmod(0o751)
        top_before = sorted(entry.name for entry in home.iterdir())
        dev_before = tree_snapshot(dev)
        profile = Path(self.installation.layout["data"]) / "profiles" / "production"
        result = manager.select_new_profile(self.installation, profile, home)
        self.assertEqual((result["root"], result["synced_folder"]), (str(home), str(home / "anj-cloud")))
        self.assertEqual(self.active(), dict(state, profile=str(profile)))
        self.assertEqual(sorted(entry.name for entry in home.iterdir()), top_before)  # nothing added to home
        self.assertFalse((home / "anj-cloud").exists())
        self.assertEqual(home.stat().st_mode & 0o777, 0o751)  # never changed
        self.assertEqual((home / "Documents" / "letter.txt").read_text(), "personal\n")
        self.assertEqual(tree_snapshot(dev), dev_before)
        self.assertIn(str(self.dev_root), result["known_roots"])

    def test_home_folder_is_refused_when_its_anj_cloud_folder_exists(self):
        state, _ = self.dev()
        (self.home / "anj-cloud").mkdir(mode=0o700)
        with self.assertRaisesRegex(manager.Refused, "already exists"):
            manager.select_new_profile(self.installation, self.home / "prod", self.home)
        self.assertFalse((self.home / "prod").exists())
        self.assertEqual(self.active(), state)
        self.assertEqual(list((self.home / "anj-cloud").iterdir()), [])

    def test_existing_profile_directory_must_be_private_before_anything_is_created(self):
        state, _ = self.dev()
        profile = self.home / "prod"
        profile.mkdir(mode=0o755)
        profile.chmod(0o755)
        with self.assertRaisesRegex(manager.Refused, "private"):
            manager.select_new_profile(self.installation, profile, self.home / "AnjCloud")
        self.assertFalse((self.home / "AnjCloud").exists())
        self.assertEqual(self.active(), state)

    def test_unknown_or_missing_existing_profile_is_refused(self):
        state, _ = self.dev()
        stranger = self.home / "stranger"
        stranger.mkdir(mode=0o700)
        with self.assertRaisesRegex(manager.Refused, "not a known"):
            manager.select_existing_profile(self.installation, stranger, True)
        with self.assertRaisesRegex(manager.Refused, "does not exist"):
            manager.select_existing_profile(self.installation, self.home / "absent", True)
        self.assertFalse((self.home / "absent").exists())
        self.assertEqual(self.active(), state)

    def test_installed_command_select_profile(self):
        _, dev = self.dev()
        command = self.installation.layout["command"]
        bad = subprocess.run([command, "select-profile", "--new", str(self.home / "prod"), str(dev)], capture_output=True, text=True)
        self.assertEqual(bad.returncode, 1)
        self.assertIn("--root", bad.stderr)
        result = subprocess.run([command, "select-profile", "--new", str(self.home / "prod"), "--root", str(self.home / "AnjCloud")],
                                capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(result.stdout)["profile"], str(self.home / "prod"))
        # Spec #34 P1.3: without --root the root is the home folder.
        home = subprocess.run([command, "select-profile", "--new", str(self.home / "prod2")], capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(home.stdout)["root"], str(self.home.resolve()))
        back = subprocess.run([command, "select-profile", str(dev), "--legacy-app-closed"], capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(back.stdout)["profile"], str(dev))


# A fake client for move-root: proves it holds the inherited profile lock, records its argv and
# answers as the profile's `move-root-reply.json` says (exit code, stdout lines, delay).
FAKE_MOVE_CLIENT = r'''
import errno, fcntl, json, os, sys, time
args = sys.argv[1:]
profile = args[args.index("--profile-dir") + 1]
fd = int(args[args.index("--profile-lock-fd") + 1])
os.fstat(fd)
probe = os.open(os.path.join(profile, ".instance.lock"), os.O_RDWR)
try:
    fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
    held = False
except OSError as error:
    held = error.errno in (errno.EWOULDBLOCK, errno.EAGAIN)
with open(os.path.join(profile, "move-root-argv.json"), "w") as stream:
    json.dump({"argv": args, "lock_held": held}, stream)
reply = json.load(open(os.path.join(profile, "move-root-reply.json")))
time.sleep(reply.get("sleep", 0))
for line in reply.get("stdout", []):
    print(line, flush=True)
sys.exit(reply.get("code", 0))
'''


class MoveRoot(unittest.TestCase):
    """move-root: the manager guards (installation + profile lifetime locks, overlap list, desktop session)
    and delegates to the active client, which owns the manifest (root_move.dart, root_move_test.dart)."""

    setUp = ManagerFiles.setUp
    tearDown = ManagerFiles.tearDown
    archive = ManagerFiles.archive
    install = ManagerFiles.install

    def fake_install(self):
        def client(root):
            (root / "anj_cloud").write_text(f"#!{sys.executable}\n" + FAKE_MOVE_CLIENT)
            (root / "anj_cloud").chmod(0o700)
        archive, expected = self.archive(mutate=client)
        state = self.install(archive, expected)
        self.profile = Path(state["profile"])
        os.environ["WAYLAND_DISPLAY"] = "wayland-test"
        return state

    def reply(self, code=0, stdout=(), sleep=0):
        (self.profile / "move-root-reply.json").write_text(json.dumps({"code": code, "stdout": list(stdout), "sleep": sleep}))

    def recorded(self):
        return json.loads((self.profile / "move-root-argv.json").read_text())

    def test_delegates_on_the_held_lock_with_other_profiles_as_known_roots(self):
        self.fake_install()
        other = self.home / "other-profile"
        other.mkdir(mode=0o700)
        other_root = self.home / "other parent" / "anj-cloud"
        db = sqlite3.connect(other / "manifest.sqlite")
        db.execute("CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        db.execute("INSERT INTO settings VALUES ('root', ?)", (str(other_root),))
        db.commit()
        db.close()
        manager.atomic_json(self.installation.config / "profiles.json",
                            {"owner": manager.OWNER, "profiles": {str(other): None, str(self.profile): None}})
        # This profile's own root is not passed: the client checks the target against its own state.
        own = sqlite3.connect(self.profile / "manifest.sqlite")
        own.execute("CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        own.execute("INSERT INTO settings VALUES ('root', ?)", (str(self.home / "AnJ Cloud" / "anj-cloud"),))
        own.commit()
        own.close()
        moved = {"moved": True, "from": str(self.home / "AnJ Cloud" / "anj-cloud"), "to": str(self.home / "anj-cloud")}
        self.reply(stdout=["Gtk-Message: noise", json.dumps(moved)])
        result = manager.move_root(self.installation)
        self.assertEqual({k: result[k] for k in moved}, moved)
        self.assertIn("nothing is transferred again", result["next"])
        recorded = self.recorded()
        self.assertTrue(recorded["lock_held"])
        argv = recorded["argv"]
        self.assertEqual(argv[argv.index("--move-root") + 1], str(self.home / "anj-cloud"))
        self.assertEqual(argv[argv.index("--profile-dir") + 1], str(self.profile))
        known = [argv[i + 1] for i, value in enumerate(argv) if value == "--known-root"]
        self.assertIn(str(other), known)
        self.assertIn(str(other_root), known)
        self.assertNotIn(str(self.home / "AnJ Cloud" / "anj-cloud"), known)
        self.assertNotIn(str(self.profile), known)
        events = [json.loads(line)["event"] for line in (Path(self.installation.layout["state"]) / "manager.jsonl").read_text().splitlines()]
        self.assertEqual(events[-2:], ["root_move_started", "root_move_finished"])

    def test_target_option_and_already_there(self):
        self.fake_install()
        self.reply(stdout=[json.dumps({"moved": False, "root": str(self.home / "elsewhere" / "anj-cloud")})])
        result = manager.move_root(self.installation, str(self.home / "elsewhere" / "anj-cloud"))
        self.assertIn("already at", result["next"])
        argv = self.recorded()["argv"]
        self.assertEqual(argv[argv.index("--move-root") + 1], str(self.home / "elsewhere" / "anj-cloud"))

    def test_client_refusal_is_relayed(self):
        self.fake_install()
        self.reply(code=2, stdout=[json.dumps({"refused": "/x/anj-cloud already exists. move-root never merges"})])
        with self.assertRaisesRegex(manager.Refused, "already exists. move-root never merges"):
            manager.move_root(self.installation)

    def test_running_app_refuses_before_the_client_runs(self):
        self.fake_install()
        self.reply()
        with manager.exclusive(self.profile / ".instance.lock", profile=True):
            with self.assertRaisesRegex(manager.Refused, "AnJ Cloud is running for this profile. Quit it"):
                manager.move_root(self.installation)
        self.assertFalse((self.profile / "move-root-argv.json").exists())

    def test_without_a_desktop_session_nothing_runs(self):
        self.fake_install()
        self.reply()
        for name in ("WAYLAND_DISPLAY", "DISPLAY"):
            os.environ.pop(name, None)
        with self.assertRaisesRegex(manager.Refused, "desktop session"):
            manager.move_root(self.installation)
        self.assertFalse((self.profile / "move-root-argv.json").exists())

    def test_failure_and_timeout_point_at_a_rerun(self):
        self.fake_install()
        self.reply(code=1, stdout=[json.dumps({"error": "boom"})])
        with self.assertRaisesRegex(manager.Refused, r"move-root failed \(boom\).*run move-root again"):
            manager.move_root(self.installation)
        self.reply(sleep=5)
        with self.assertRaisesRegex(manager.Refused, "did not finish move-root within 1 seconds"):
            manager.move_root(self.installation, timeout=1)
        # The profile lock was released: the next run proceeds.
        self.reply(stdout=[json.dumps({"moved": True})])
        self.assertTrue(manager.move_root(self.installation)["moved"])

    def test_installed_command(self):
        self.fake_install()
        self.reply(stdout=[json.dumps({"moved": True, "to": str(self.home / "anj-cloud")})])
        command = self.installation.layout["command"]
        result = subprocess.run([command, "move-root"], capture_output=True, text=True, check=True)
        self.assertTrue(json.loads(result.stdout)["moved"])
        self.reply(code=2, stdout=[json.dumps({"refused": "Nope."})])
        refused = subprocess.run([command, "move-root", "--to", str(self.home / "x" / "anj-cloud")], capture_output=True, text=True)
        self.assertEqual(refused.returncode, 1)
        self.assertIn("anj-cloud: Nope.", refused.stderr)


if __name__ == "__main__":
    unittest.main()
