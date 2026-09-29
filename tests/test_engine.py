from __future__ import annotations

import contextlib
from pathlib import Path

from PIL import Image, ImageDraw
from pypdf import PdfReader

from kindle_capture.engine import CaptureEngine
from kindle_capture.models import CaptureRegion, CaptureSettings, WindowInfo


def make_page(number: int) -> Image.Image:
    image = Image.new("RGB", (600, 900), "white")
    draw = ImageDraw.Draw(image)
    for index in range(20):
        width = 420 - ((index + number * 3) % 8) * 20
        draw.rectangle((80, 80 + index * 35, 80 + width, 86 + index * 35), fill="black")
    draw.rectangle((100 + number * 30, 760, 180 + number * 30, 820), fill="black")
    return image


class FakeController:
    def __init__(self) -> None:
        self.pages = [make_page(index) for index in range(3)]
        self.index = 0

    def ensure_permissions(self, request: bool = True) -> None:
        return None

    def current_window(self, expected: WindowInfo) -> WindowInfo:
        return expected

    def activate(self, window: WindowInfo, click_page: bool = False, region: CaptureRegion | None = None) -> None:
        return None

    def send_page_turn(self, window: WindowInfo, direction: str) -> None:
        if direction == "Right":
            self.index = min(len(self.pages) - 1, self.index + 1)
        else:
            self.index = max(0, self.index - 1)

    def capture_region(self, window: WindowInfo, region: CaptureRegion) -> Image.Image:
        image = self.pages[self.index]
        return image.crop(region.pixel_box(image.width, image.height))

    def is_abort_key_down(self) -> bool:
        return False

    @contextlib.contextmanager
    def prevent_sleep(self):
        yield


def test_engine_captures_pages_and_builds_pdf(tmp_path: Path) -> None:
    window = WindowInfo(10, 20, "Kindle", "Test Book", 0, 0, 600, 900)
    settings = CaptureSettings(
        output_root=tmp_path,
        max_pages=3,
        direction="Right",
        render_settle_ms=0,
        maximum_wait_ms=300,
        ocr_enabled=False,
        open_output=False,
    )
    result = CaptureEngine(FakeController(), log=lambda _message: None, countdown_seconds=0).run(
        window, CaptureRegion(), settings
    )
    assert len(result.image_paths) == 3
    assert result.pdf_path is not None and result.pdf_path.exists()
    assert len(PdfReader(result.pdf_path).pages) == 3
    assert (result.output_directory / "capture-session.json").exists()
