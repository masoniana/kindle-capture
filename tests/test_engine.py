from __future__ import annotations

import contextlib
import json
from pathlib import Path

from PIL import Image, ImageDraw
from pypdf import PdfReader

from kindle_capture.engine import CaptureEngine, rebuild_pdf
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
    controller = FakeController()
    result = CaptureEngine(controller, log=lambda _message: None, countdown_seconds=0).run(
        window, CaptureRegion(), settings
    )
    assert len(result.image_paths) == 3
    assert result.pdf_path is not None and result.pdf_path.exists()
    reader = PdfReader(result.pdf_path)
    assert len(reader.pages) == 3
    for index, path in enumerate(result.image_paths):
        assert path.name == f"page_{index + 1:05d}.png"
        with Image.open(path) as image:
            assert image.format == "PNG"
            assert image.tobytes() == controller.pages[index].tobytes()
            embedded = reader.pages[index]["/Resources"]["/XObject"]["/Im0"]
            assert embedded["/Filter"] == "/FlateDecode"
            assert embedded.get_data() == image.tobytes()
    assert not list(result.output_directory.glob("*.jpg"))
    manifest = json.loads((result.output_directory / "capture-session.json").read_text(encoding="utf-8"))
    assert manifest["image_format"] == "PNG"


def test_rebuild_orders_png_pages_and_supports_old_jpeg(tmp_path: Path) -> None:
    images = [make_page(index) for index in range(3)]
    images[0].save(tmp_path / "page_00001.png", "PNG")
    images[1].save(tmp_path / "page_00002.jpg", "JPEG")
    images[2].save(tmp_path / "page_00010.PNG", "PNG")
    output = rebuild_pdf(tmp_path, ocr_enabled=False, log=lambda _message: None)
    pages = PdfReader(output).pages
    assert len(pages) == 3
    for index in (0, 2):
        embedded = pages[index]["/Resources"]["/XObject"]["/Im0"]
        assert embedded["/Filter"] == "/FlateDecode"
        assert embedded.get_data() == images[index].tobytes()
    legacy = pages[1]["/Resources"]["/XObject"]["/Im0"]
    assert legacy["/Filter"] == "/DCTDecode"
    assert legacy.get_data() == (tmp_path / "page_00002.jpg").read_bytes()
