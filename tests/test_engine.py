from __future__ import annotations

import contextlib
import json
import threading
from pathlib import Path

import pytest
from PIL import Image, ImageDraw
from pypdf import PdfReader

from kindle_capture import engine
from kindle_capture.engine import CaptureEngine, rebuild_pdf
from kindle_capture.models import (
    CaptureRegion,
    CaptureSettings,
    PageReadyResult,
    WindowInfo,
)


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
        self.capture_calls = 0

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
        self.capture_calls += 1
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
    # Initial capture + three readiness samples for each subsequent page.
    assert controller.capture_calls == 7
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


def test_png_save_overlaps_page_turn_and_all_writes_finish(tmp_path: Path, monkeypatch) -> None:
    save_started = threading.Event()
    page_turned = threading.Event()
    real_save = engine._save_png

    def slow_save(image: Image.Image, path: Path) -> None:
        if path.name == "page_00001.png":
            save_started.set()
            assert page_turned.wait(3), "Page turn should not wait for PNG encoding"
        real_save(image, path)

    class Controller(FakeController):
        def send_page_turn(self, window: WindowInfo, direction: str) -> None:
            assert save_started.wait(3)
            page_turned.set()
            super().send_page_turn(window, direction)

    monkeypatch.setattr(engine, "_save_png", slow_save)
    controller = Controller()
    result = CaptureEngine(controller, log=lambda _message: None, countdown_seconds=0).run(
        WindowInfo(10, 20, "Kindle", "Book", 0, 0, 600, 900),
        CaptureRegion(),
        CaptureSettings(tmp_path, max_pages=3, direction="Right", render_settle_ms=0,
                        maximum_wait_ms=300, ocr_enabled=False, open_output=False),
    )
    assert len(result.image_paths) == 3
    assert all(path.exists() for path in result.image_paths)
    assert not list(result.output_directory.glob("*.partial"))


def test_png_writer_freezes_pixels_and_reports_only_finished_writes(tmp_path: Path, monkeypatch) -> None:
    release = threading.Event()
    started = threading.Event()
    completed = []
    real_save = engine._save_png

    def delayed_save(image: Image.Image, path: Path) -> None:
        started.set()
        assert release.wait(3)
        real_save(image, path)

    monkeypatch.setattr(engine, "_save_png", delayed_save)
    image = Image.new("RGB", (10, 10), "red")
    path = tmp_path / "page_00001.png"
    with engine._PngWriter(lambda path, _difference: completed.append(path)) as writer:
        writer.submit(image, path, 1.0)
        assert started.wait(3)
        assert completed == []
        image.paste("blue", (0, 0, 10, 10))
        release.set()
    assert completed == [path]
    with Image.open(path) as saved:
        assert saved.getpixel((0, 0)) == (255, 0, 0)


def test_png_write_failure_reaches_manifest_and_keeps_previous_pages(tmp_path: Path, monkeypatch) -> None:
    real_save = engine._save_png

    def failing_save(image: Image.Image, path: Path) -> None:
        if path.name == "page_00002.png":
            raise OSError("simulated disk full")
        real_save(image, path)

    monkeypatch.setattr(engine, "_save_png", failing_save)
    with pytest.raises(OSError, match="simulated disk full"):
        CaptureEngine(FakeController(), log=lambda _message: None, countdown_seconds=0).run(
            WindowInfo(10, 20, "Kindle", "Book", 0, 0, 600, 900), CaptureRegion(),
            CaptureSettings(tmp_path, max_pages=3, direction="Right", render_settle_ms=0,
                            maximum_wait_ms=300, ocr_enabled=False, open_output=False),
        )
    folder = next(tmp_path.glob("captures_*"))
    manifest = json.loads((folder / "capture-session.json").read_text(encoding="utf-8"))
    assert manifest["status"] == "Error"
    assert manifest["saved_pages"] == 1
    assert (folder / "page_00001.png").exists()
    assert not (folder / "page_00002.png").exists()
    assert "simulated disk full" in (folder / "capture-error.txt").read_text(encoding="utf-8")


@pytest.mark.parametrize("timed_out,clarity_timed_out,expected_captures", [
    (False, False, 2), (True, False, 3), (False, True, 3),
])
def test_only_verified_ready_frames_are_reused(
    tmp_path: Path, monkeypatch, timed_out: bool, clarity_timed_out: bool, expected_captures: int,
) -> None:
    def ready(capture_signature, _previous, *_args):
        signature = capture_signature()
        return PageReadyResult(True, timed_out, False, 1, signature, 1.0, 0, clarity_timed_out)

    monkeypatch.setattr(engine, "wait_for_page_ready", ready)
    controller = FakeController()
    result = CaptureEngine(controller, log=lambda _message: None, countdown_seconds=0).run(
        WindowInfo(10, 20, "Kindle", "Book", 0, 0, 600, 900), CaptureRegion(),
        CaptureSettings(tmp_path, max_pages=2, direction="Right", ocr_enabled=False, open_output=False),
    )
    assert len(result.image_paths) == 2
    assert controller.capture_calls == expected_captures


def test_stop_during_render_drains_pending_png_and_builds_pdf(tmp_path: Path, monkeypatch) -> None:
    stop_event = threading.Event()

    def stopped(capture_signature, _previous, *_args):
        stop_event.set()
        return PageReadyResult(True, False, True, 1, capture_signature(), 1.0, 0, False)

    monkeypatch.setattr(engine, "wait_for_page_ready", stopped)
    result = CaptureEngine(FakeController(), log=lambda _message: None, stop_event=stop_event, countdown_seconds=0).run(
        WindowInfo(10, 20, "Kindle", "Book", 0, 0, 600, 900), CaptureRegion(),
        CaptureSettings(tmp_path, max_pages=3, direction="Right", ocr_enabled=False, open_output=False),
    )
    assert result.stopped
    assert len(result.image_paths) == 1
    assert result.image_paths[0].exists()
    assert len(PdfReader(result.pdf_path).pages) == 1
    manifest = json.loads((result.output_directory / "capture-session.json").read_text(encoding="utf-8"))
    assert manifest["saved_pages"] == 1
    assert manifest["status"] == "Complete"
