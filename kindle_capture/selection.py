from __future__ import annotations

import math
from collections.abc import Iterable
from dataclasses import dataclass

from .models import CaptureRegion, WindowInfo


@dataclass(frozen=True)
class ScreenRectangle:
    """Screen coordinates in the same units as WindowInfo (points on macOS)."""

    x: float
    y: float
    width: float
    height: float

    @classmethod
    def from_window(cls, window: WindowInfo) -> ScreenRectangle:
        return cls(window.x, window.y, window.width, window.height)

    @property
    def area(self) -> float:
        return self.width * self.height

    @property
    def valid(self) -> bool:
        return (
            all(math.isfinite(value) for value in (self.x, self.y, self.width, self.height))
            and self.width > 0
            and self.height > 0
        )

    def contains(self, x: float, y: float) -> bool:
        return self.x <= x < self.x + self.width and self.y <= y < self.y + self.height

    def intersection(self, other: ScreenRectangle) -> ScreenRectangle | None:
        if not self.valid or not other.valid:
            return None
        left, top = max(self.x, other.x), max(self.y, other.y)
        right = min(self.x + self.width, other.x + other.width)
        bottom = min(self.y + self.height, other.y + other.height)
        if right <= left or bottom <= top:
            return None
        return ScreenRectangle(left, top, right - left, bottom - top)

    def relative_to(self, window: WindowInfo) -> CaptureRegion:
        bounds = ScreenRectangle.from_window(window)
        clipped = self.intersection(bounds)
        if clipped is None:
            raise ValueError("キャプチャ範囲がKindleウィンドウ内にありません。")
        return CaptureRegion(
            (clipped.x - bounds.x) / bounds.width,
            (clipped.y - bounds.y) / bounds.height,
            clipped.width / bounds.width,
            clipped.height / bounds.height,
        ).validate()


class SelectionTargets:
    """Choose the smallest large native component containing the pointer."""

    def __init__(self, client: ScreenRectangle, candidates: Iterable[ScreenRectangle]) -> None:
        if not client.valid:
            raise ValueError("Kindleのクライアント領域を取得できませんでした。")
        self.client = client
        minimum_width = min(client.width, max(160, client.width * 0.20))
        minimum_height = min(client.height, max(160, client.height * 0.25))
        usable = set()
        for candidate in candidates:
            clipped = candidate.intersection(client)
            if (
                clipped is not None
                and clipped != client
                and clipped.width >= minimum_width
                and clipped.height >= minimum_height
            ):
                usable.add(clipped)
        self.candidates = tuple(sorted(usable, key=lambda rect: (rect.area, rect.width, rect.height, rect.x, rect.y)))

    def at(self, x: float, y: float) -> ScreenRectangle:
        for candidate in self.candidates:
            if candidate.contains(x, y):
                return candidate
        return self.client
