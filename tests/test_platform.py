from __future__ import annotations

import sys

from kindle_capture.controllers import create_controller, platform_label


def test_controller_factory_matches_current_platform() -> None:
    controller = create_controller()
    if sys.platform == "win32":
        assert type(controller).__name__ == "WindowsController"
        assert platform_label() == "Windows"
    elif sys.platform == "darwin":
        assert type(controller).__name__ == "MacOSController"
        assert platform_label() == "macOS"
    else:  # pragma: no cover - the project supports Windows and macOS only
        raise AssertionError(f"unexpected test platform: {sys.platform}")
