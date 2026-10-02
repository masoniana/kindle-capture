from __future__ import annotations

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

from kindle_capture import analysis
from kindle_capture.analysis import (
    compare_signatures,
    image_signature,
    signature_sharpness,
    signature_statistics,
)


def page_image(text_marker: int) -> Image.Image:
    image = Image.new("RGB", (800, 1100), "white")
    draw = ImageDraw.Draw(image)
    for y in range(100, 1000, 38):
        draw.line((80, y, 720 - text_marker * 7, y), fill="black", width=3)
    draw.rectangle((100 + text_marker * 12, 500, 260 + text_marker * 12, 640), outline="black", width=5)
    return image


def test_signature_comparison_distinguishes_pages() -> None:
    first = image_signature(page_image(0))
    same = image_signature(page_image(0))
    second = image_signature(page_image(4))
    assert compare_signatures(first, same) == 0.0
    assert compare_signatures(first, second) > 1.0


def test_sharpness_and_statistics_are_finite() -> None:
    signature = image_signature(page_image(2))
    mean, standard_deviation = signature_statistics(signature)
    assert 0.0 < mean < 255.0
    assert standard_deviation > 0.0
    assert signature_sharpness(signature) > 0.0
    assert np.isfinite(signature_sharpness(signature))


class FakeClock:
    def __init__(self) -> None:
        self.now = 0.0

    def monotonic(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds


def test_readiness_keeps_high_resolution_wait_and_returns_sharp_frame(monkeypatch) -> None:
    clock = FakeClock()
    monkeypatch.setattr(analysis, "time", clock)
    initial = image_signature(page_image(0))
    sharp = image_signature(page_image(4))
    blurred = image_signature(page_image(4).filter(ImageFilter.GaussianBlur(10)))

    def capture():
        return blurred if clock.now < 0.35 else sharp

    result = analysis.wait_for_page_ready(capture, initial, 1500, 45, 2, 1.0, 350, lambda: False)
    assert result.changed
    assert not result.timed_out
    assert not result.clarity_timed_out
    assert result.clarity_ms >= 350
    assert np.array_equal(result.signature, sharp)


def test_readiness_still_requires_consecutive_stable_frames(monkeypatch) -> None:
    clock = FakeClock()
    monkeypatch.setattr(analysis, "time", clock)
    initial = image_signature(page_image(0))
    final = image_signature(page_image(4))
    frames = iter([final, initial, final, initial, final, final, final])
    result = analysis.wait_for_page_ready(lambda: next(frames), initial, 1500, 45, 2, 1.0, 0, lambda: False)
    assert result.elapsed_ms >= 315
    assert np.array_equal(result.signature, final)
