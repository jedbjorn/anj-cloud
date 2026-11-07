#!/usr/bin/env python3
"""Verify Open folder lands at the requested provider folder in DocumentsUI.

Build a QA APK with -t tool/android/folder_navigation_fixture.dart, then run:
  APKS=<directory containing app-debug.apk> OUT=<evidence directory> \
    anj-emu-run <tag> <n> python3 tool/android/emu_folder_navigation.py

Uses synthetic metadata; no account, review server or personal files required.
"""
import json

import emu_updater as u


def main():
    u.OUT.mkdir(parents=True, exist_ok=True)
    try:
        u.adb("install", "-r", "-t", "-g", str(u.APKS / "app-debug.apk"), timeout=300)
        u.adb("logcat", "-c")
        u.launch()
        for button, marker, absent in (
            ("Open root fixture", "Navigation root marker", "Target child"),
            ("Open nested fixture", "Target child", "Navigation root marker"),
        ):
            u.tap(f"^{button}$", timeout=60)
            found = u.find(f"^{marker}$", timeout=30, pkg=r"documentsui")
            screen = u.screen_text()
            u.step(button, found is not None and absent not in screen, screen=screen)
            # Return to the fixture explicitly: Files has its own back stack.
            u.launch()
    finally:
        (u.OUT / "logcat.txt").write_text(u.adb("logcat", "-d", check=False))
        (u.OUT / "steps.json").write_text(json.dumps(u.STEPS, indent=2) + "\n")
        u.adb("uninstall", u.PKG, check=False)


if __name__ == "__main__":
    main()
