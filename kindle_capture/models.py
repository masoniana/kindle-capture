from __future__ import annotations

from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Literal

Direction = Literal["Auto", "Right", "Left"]
SpeedMode = Literal["Turbo", "Balanced", "Safe"]


@dataclass(frozen=True)
class WindowInfo:
    window_id: int
    process_id: int
    owner_name: str
    title: str
    x: float
    y: float
    width: float
    height: float

    @property
    def display_name(self) -> str:
        title = self.title.strip() or "（タイトルなし）"
        return f"{self.owner_name} - {title}"


@dataclass(frozen=True)
class CaptureRegion:
    """A crop expressed as fractions of the captured window image."""

    x: float = 0.0
    y: float = 0.0
    width: float = 1.0
    height: float = 1.0

    def validate(self) -> CaptureRegion:
        values = (self.x, self.y, self.width, self.height)
        if not all(0.0 <= value <= 1.0 for value in values):
            raise ValueError("キャプチャ範囲は 0〜1 の比率で指定してください。")
        if self.width <= 0.0 or self.height <= 0.0:
            raise ValueError("キャプチャ範囲の幅と高さは 0 より大きくしてください。")
        if self.x + self.width > 1.000001 or self.y + self.height > 1.000001:
            raise ValueError("キャプチャ範囲がウィンドウ外にはみ出しています。")
        return self

    def pixel_box(self, image_width: int, image_height: int) -> tuple[int, int, int, int]:
        self.validate()
        left = max(0, min(image_width - 1, round(self.x * image_width)))
        top = max(0, min(image_height - 1, round(self.y * image_height)))
        right = max(left + 1, min(image_width, round((self.x + self.width) * image_width)))
        bottom = max(top + 1, min(image_height, round((self.y + self.height) * image_height)))
        return left, top, right, bottom


@dataclass(frozen=True)
class SpeedProfile:
    poll_interval_ms: int
    stable_samples: int
    default_render_settle_ms: int


SPEED_PROFILES: dict[str, SpeedProfile] = {
    "Turbo": SpeedProfile(45, 2, 350),
    "Balanced": SpeedProfile(75, 3, 550),
    "Safe": SpeedProfile(120, 4, 900),
}


@dataclass
class CaptureSettings:
    output_root: Path
    max_pages: int = 1500
    direction: Direction = "Auto"
    speed_mode: SpeedMode = "Turbo"
    render_settle_ms: int | None = None
    maximum_wait_ms: int = 1500
    duplicate_stop_count: int = 3
    similarity_threshold: float = 1.0
    ocr_enabled: bool = True
    ocr_language: str = "ja-JP"
    open_output: bool = True

    def validate(self) -> CaptureSettings:
        if self.max_pages < 0:
            raise ValueError("保存ページ数は 0 以上にしてください。")
        if self.direction not in ("Auto", "Right", "Left"):
            raise ValueError("ページ送り方向が不正です。")
        if self.speed_mode not in SPEED_PROFILES:
            raise ValueError("速度モードが不正です。")
        if self.render_settle_ms is not None and not 0 <= self.render_settle_ms <= 5000:
            raise ValueError("高解像度待ちは 0〜5000 ms にしてください。")
        if not 300 <= self.maximum_wait_ms <= 30000:
            raise ValueError("最大待ちは 300〜30000 ms にしてください。")
        if not 1 <= self.duplicate_stop_count <= 10:
            raise ValueError("重複停止回数は 1〜10 にしてください。")
        if not 0.1 <= self.similarity_threshold <= 50.0:
            raise ValueError("類似判定は 0.1〜50.0 にしてください。")
        if self.ocr_enabled and not self.ocr_language.strip():
            raise ValueError("OCR言語を指定してください。")
        return self

    @property
    def speed(self) -> SpeedProfile:
        return SPEED_PROFILES[self.speed_mode]

    @property
    def effective_render_settle_ms(self) -> int:
        if self.render_settle_ms is None:
            return self.speed.default_render_settle_ms
        return self.render_settle_ms

    def manifest_values(self) -> dict[str, object]:
        values = asdict(self)
        values["output_root"] = str(self.output_root)
        values["render_settle_ms"] = self.effective_render_settle_ms
        return values


@dataclass(frozen=True)
class OcrLine:
    text: str
    x: float
    y: float
    width: float
    height: float


@dataclass(frozen=True)
class PageReadyResult:
    changed: bool
    timed_out: bool
    aborted: bool
    elapsed_ms: int
    signature: object
    sharpness: float
    clarity_ms: int
    clarity_timed_out: bool


@dataclass(frozen=True)
class CaptureResult:
    output_directory: Path
    image_paths: tuple[Path, ...]
    pdf_path: Path | None
    stopped: bool
