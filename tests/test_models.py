from __future__ import annotations

import pytest

from kindle_capture.models import CaptureRegion


def test_region_converts_to_pixel_box() -> None:
    region = CaptureRegion(0.1, 0.2, 0.5, 0.6)
    assert region.pixel_box(1000, 500) == (100, 100, 600, 400)


def test_region_rejects_overflow() -> None:
    with pytest.raises(ValueError):
        CaptureRegion(0.8, 0.0, 0.3, 1.0).validate()
