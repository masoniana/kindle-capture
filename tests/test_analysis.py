from __future__ import annotations

import numpy as np
from PIL import Image, ImageDraw

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
