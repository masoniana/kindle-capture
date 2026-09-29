from __future__ import annotations

import sys


def create_ocr(language: str):
    if sys.platform == "darwin":
        from .ocr import VisionOcr

        return VisionOcr(language)
    if sys.platform == "win32":
        from .windows_ocr import WindowsOcr

        return WindowsOcr(language)
    raise RuntimeError("このOSではOCRを利用できません。")
