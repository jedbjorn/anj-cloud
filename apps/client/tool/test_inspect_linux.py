#!/usr/bin/env python3
"""Build real ELF fixtures without the host CRT to exercise packaging gates."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from inspect_linux import inspect_bundle, inspect_elf


class InspectionTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "plain.c").write_text("int answer(void) { return 42; }\n")

    def library(self, name="plain.so", *flags):
        output = self.root / name
        subprocess.run(["cc", "-nostdlib", "-shared", "-fPIC", str(self.root / "plain.c"),
                        "-o", str(output), *flags], check=True, capture_output=True)
        return output

    def test_baseline_and_missing_notes_are_accepted_as_declarations_only(self):
        self.assertEqual(inspect_elf(self.library())["isa_needed"], [])
        inspected = inspect_elf(self.library("baseline.so", "-Wl,-z,x86-64-baseline"))
        self.assertEqual(inspected["isa_needed"], ["x86-64-baseline"])

    def test_rejects_higher_cpu_requirement(self):
        for level in ("v2", "v3", "v4"):
            with self.subTest(level=level), self.assertRaisesRegex(ValueError, "nonbaseline CPU ISA"):
                inspect_elf(self.library(f"{level}.so", f"-Wl,-z,x86-64-{level}"))

    def test_rejects_newer_glibc_symbol_requirement(self):
        # A local synthetic provider gives a real ELF version requirement even
        # on older build hosts; the fixture never loads or impersonates libc.
        (self.root / "versions.map").write_text("GLIBC_2.99 { global: answer; };\n")
        self.library("provider.so", f"-Wl,--version-script={self.root / 'versions.map'}")
        (self.root / "plain.c").write_text("extern int answer(void); int call(void) { return answer(); }\n")
        consumer = self.library("consumer.so", f"-L{self.root}", "-l:provider.so")
        with self.assertRaisesRegex(ValueError, "GLIBC_2.99 exceeds"):
            inspect_elf(consumer)

    def test_rejects_absolute_runtime_paths(self):
        with self.assertRaisesRegex(ValueError, "runtime library search path"):
            inspect_elf(self.library("rpath.so", "-Wl,-rpath,/work/build/lib"))

    def test_rejects_current_directory_runtime_path(self):
        with self.assertRaisesRegex(ValueError, "runtime library search path"):
            inspect_elf(self.library("cwd.so", "-Wl,-rpath,$ORIGIN:"))

    def test_inspects_nested_assets_and_requires_expected_binaries(self):
        plain = self.library()
        for name in ("anj_cloud", "lib/libflutter_linux_gtk.so", "lib/libapp.so", "lib/libanj_rootfs.so"):
            target = self.root / "bundle" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(plain, target)
        nested = self.root / "bundle/lib/native-assets"
        nested.mkdir()
        shutil.copyfile(self.library("bad.so", "-Wl,-z,x86-64-v4"), nested / "sqlite.so")
        with self.assertRaisesRegex(ValueError, "sqlite.so: nonbaseline"):
            inspect_bundle(self.root / "bundle")
        (nested / "sqlite.so").unlink()
        self.assertEqual(len(inspect_bundle(self.root / "bundle")), 4)
        (self.root / "bundle/anj_cloud").unlink()
        with self.assertRaisesRegex(ValueError, "Missing expected runtime ELFs"):
            inspect_bundle(self.root / "bundle")

    def test_rejects_symlinks(self):
        (self.root / "linked.so").symlink_to(self.library())
        with self.assertRaisesRegex(ValueError, "Unexpected bundle symlink"):
            inspect_bundle(self.root)


if __name__ == "__main__":
    unittest.main()
