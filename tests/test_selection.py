from __future__ import annotations

import math

import pytest

from kindle_capture.models import CaptureRegion, WindowInfo
from kindle_capture.selection import ScreenRectangle, SelectionTargets


def test_pointer_snaps_to_smallest_large_pane_and_falls_back() -> None:
    client = ScreenRectangle(100, 50, 1000, 800)
    outer = ScreenRectangle(120, 100, 960, 720)
    page = ScreenRectangle(300, 150, 600, 600)
    button = ScreenRectangle(400, 200, 40, 30)
    targets = SelectionTargets(client, [outer, page, button])
    assert targets.at(410, 210) == page
    assert targets.at(150, 200) == outer
    assert targets.at(105, 55) == client
    assert targets.at(900, 300) == outer  # right edge is not part of page


@pytest.mark.parametrize("candidates", [[], [ScreenRectangle(0, 0, 40, 40)], [ScreenRectangle(5000, 0, 300, 300)]])
def test_undetectable_pane_uses_client(candidates: list[ScreenRectangle]) -> None:
    client = ScreenRectangle(0, 0, 800, 600)
    targets = SelectionTargets(client, candidates)
    assert targets.at(400, 300) == client


def test_candidates_are_clipped_deduplicated_and_invalid_values_ignored() -> None:
    client = ScreenRectangle(-1200, -100, 1000, 800)
    target = ScreenRectangle(-1200, 0, 700, 650)
    targets = SelectionTargets(client, [
        target, target, ScreenRectangle(-1300, 0, 800, 650),
        ScreenRectangle(0, 0, math.nan, 600), client,
    ])
    assert targets.candidates == (target,)
    assert targets.at(-900, 200) == target


def test_region_coordinates_preserve_retina_crop_and_resize_ratios() -> None:
    window = WindowInfo(1, 2, "Kindle", "Book", -1000, 80, 1000, 800)
    region = ScreenRectangle(-800, 180, 600, 600).relative_to(window)
    assert region == CaptureRegion(0.2, 0.125, 0.6, 0.75)
    assert region.pixel_box(2000, 1600) == (400, 200, 1600, 1400)
    assert region.pixel_box(500, 400) == (100, 50, 400, 350)


def test_client_fallback_excludes_macos_title_bar_in_captured_image() -> None:
    window = WindowInfo(1, 2, "Kindle", "Book", 0, 0, 800, 600)
    client = ScreenRectangle(0, 28, 800, 572)
    assert SelectionTargets(client, []).at(100, 100).relative_to(window).pixel_box(1600, 1200) == (0, 56, 1600, 1200)
