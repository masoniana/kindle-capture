from __future__ import annotations

import sys


def create_controller():
    if sys.platform == "darwin":
        from .macos import MacOSController

        return MacOSController()
    if sys.platform == "win32":
        from .windows import WindowsController

        return WindowsController()
    raise RuntimeError("対応OSはWindows 10/11とmacOSです。")


def platform_label() -> str:
    if sys.platform == "darwin":
        return "macOS"
    if sys.platform == "win32":
        return "Windows"
    return sys.platform
