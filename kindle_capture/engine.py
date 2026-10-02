from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import traceback
from collections.abc import Callable
from datetime import datetime
from pathlib import Path
from typing import Protocol

import numpy as np
from PIL import Image

from . import __version__
from .analysis import (
    compare_signatures,
    image_signature,
    signature_statistics,
    wait_for_page_ready,
)
from .models import CaptureRegion, CaptureResult, CaptureSettings, WindowInfo
from .ocr_factory import create_ocr
from .pdf import PdfBuildStats, build_pdf


class CaptureController(Protocol):
    def ensure_permissions(self, request: bool = True) -> None: ...
    def current_window(self, expected: WindowInfo) -> WindowInfo: ...
    def activate(self, window: WindowInfo, click_page: bool = False, region: CaptureRegion | None = None) -> None: ...
    def send_page_turn(self, window: WindowInfo, direction: str) -> None: ...
    def capture_region(self, window: WindowInfo, region: CaptureRegion) -> Image.Image: ...
    def is_abort_key_down(self) -> bool: ...
    def prevent_sleep(self): ...


def _timestamp() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def _atomic_json(path: Path, value: object) -> None:
    temporary = path.with_name(path.name + ".partial")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(temporary, path)


def _unique_output_directory(root: Path) -> tuple[Path, str]:
    stamp = datetime.now().astimezone().strftime("%Y%m%d_%H%M%S")
    candidate = root / f"captures_{stamp}"
    suffix = 2
    while candidate.exists():
        candidate = root / f"captures_{stamp}_{suffix}"
        suffix += 1
    candidate.mkdir(parents=False)
    return candidate, stamp


def _save_png(image: Image.Image, path: Path) -> None:
    temporary = path.with_name(path.name + ".partial")
    temporary.unlink(missing_ok=True)
    image.convert("RGB").save(temporary, "PNG", compress_level=3, optimize=False)
    if path.exists():
        temporary.unlink(missing_ok=True)
        raise FileExistsError(f"出力画像が既に存在します: {path}")
    os.replace(temporary, path)


def list_capture_images(folder: Path) -> list[Path]:
    pattern = re.compile(r"^page_(\d+)\.(?:png|jpg|jpeg)$", re.IGNORECASE)
    numbered: list[tuple[int, Path]] = []
    for path in Path(folder).iterdir():
        if path.is_file() and (match := pattern.match(path.name)):
            numbered.append((int(match.group(1)), path))
    return [path for _, path in sorted(numbered, key=lambda item: (item[0], item[1].name.lower()))]


class CaptureEngine:
    def __init__(
        self,
        controller: CaptureController,
        log: Callable[[str], None] = print,
        stop_event: threading.Event | None = None,
        countdown_seconds: int = 3,
    ) -> None:
        self.controller = controller
        self.log = log
        self.stop_event = stop_event or threading.Event()
        self.countdown_seconds = countdown_seconds

    def _should_stop(self) -> bool:
        return self.stop_event.is_set() or self.controller.is_abort_key_down()

    def _wait(self, seconds: float) -> bool:
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if self._should_stop():
                return False
            time.sleep(min(0.05, deadline - time.monotonic()))
        return True

    def _prepare_pdf_cancellation(self, capture_was_stopped: bool) -> None:
        # A stop during capture is graceful: consume it and build a PDF from the
        # pages already saved. A new stop request during PDF/OCR cancels that phase.
        if capture_was_stopped:
            self.stop_event.clear()
        deadline = time.monotonic() + 3.0
        while self.controller.is_abort_key_down() and time.monotonic() < deadline:
            time.sleep(0.05)

    def _signature(self, window: WindowInfo, region: CaptureRegion) -> np.ndarray:
        return image_signature(self.controller.capture_region(window, region))

    def _detect_direction(
        self,
        window: WindowInfo,
        region: CaptureRegion,
        settings: CaptureSettings,
    ) -> str:
        threshold = max(1.5, settings.similarity_threshold * 1.5)
        profile = settings.speed
        self.controller.activate(window, click_page=True, region=region)
        if not self._wait(0.8):
            raise RuntimeError("方向判定を停止しました。")
        initial = self._signature(window, region)

        self.log("右矢印をテストしています…")
        self.controller.send_page_turn(window, "Right")
        right_wait = wait_for_page_ready(
            lambda: self._signature(window, region),
            initial,
            settings.maximum_wait_ms,
            profile.poll_interval_ms,
            profile.stable_samples,
            threshold,
            settings.effective_render_settle_ms,
            self._should_stop,
        )
        if right_wait.aborted:
            raise RuntimeError("方向判定を停止しました。")
        right_difference = compare_signatures(initial, right_wait.signature)
        if right_difference >= threshold:
            self.log(f"右矢印でページが変わりました（差分 {right_difference:.1f}）。開始ページへ戻します…")
            self.controller.send_page_turn(window, "Left")
            restored = wait_for_page_ready(
                lambda: self._signature(window, region),
                right_wait.signature,
                settings.maximum_wait_ms,
                profile.poll_interval_ms,
                profile.stable_samples,
                threshold,
                settings.effective_render_settle_ms,
                self._should_stop,
            )
            restore_difference = compare_signatures(initial, restored.signature)
            if restored.aborted:
                raise RuntimeError("方向判定を停止しました。")
            if restore_difference >= threshold:
                raise RuntimeError(
                    "右矢印では進みましたが開始ページへ戻せませんでした。ページ欠落防止のため方向を手動指定してください。"
                )
            return "Right"

        self.log(f"右矢印ではページが変わりませんでした（差分 {right_difference:.1f}）。左矢印を試します…")
        self.controller.send_page_turn(window, "Left")
        left_wait = wait_for_page_ready(
            lambda: self._signature(window, region),
            initial,
            settings.maximum_wait_ms,
            profile.poll_interval_ms,
            profile.stable_samples,
            threshold,
            settings.effective_render_settle_ms,
            self._should_stop,
        )
        if left_wait.aborted:
            raise RuntimeError("方向判定を停止しました。")
        left_difference = compare_signatures(initial, left_wait.signature)
        if left_difference < threshold:
            raise RuntimeError(
                f"ページ送り方向を判定できませんでした（右={right_difference:.1f}, 左={left_difference:.1f}）。"
                "最初のページを開くか、方向を手動指定してください。"
            )
        self.log(f"左矢印でページが変わりました（差分 {left_difference:.1f}）。開始ページへ戻します…")
        self.controller.send_page_turn(window, "Right")
        restored = wait_for_page_ready(
            lambda: self._signature(window, region),
            left_wait.signature,
            settings.maximum_wait_ms,
            profile.poll_interval_ms,
            profile.stable_samples,
            threshold,
            settings.effective_render_settle_ms,
            self._should_stop,
        )
        restore_difference = compare_signatures(initial, restored.signature)
        if restored.aborted:
            raise RuntimeError("方向判定を停止しました。")
        if restore_difference >= threshold:
            raise RuntimeError(
                "左矢印では進みましたが開始ページへ戻せませんでした。ページ欠落防止のため方向を手動指定してください。"
            )
        return "Left"

    def run(
        self,
        window: WindowInfo,
        region: CaptureRegion,
        settings: CaptureSettings,
    ) -> CaptureResult:
        settings.validate()
        region.validate()
        self.controller.ensure_permissions(request=True)
        window = self.controller.current_window(window)
        root = settings.output_root.expanduser().resolve()
        root.mkdir(parents=True, exist_ok=True)
        if not root.is_dir():
            raise NotADirectoryError(f"保存先がフォルダではありません: {root}")
        estimated_pages = settings.max_pages or 1500
        required = estimated_pages * 2 * 1024 * 1024
        if shutil.disk_usage(root).free < required:
            raise OSError(f"空き容量が不足しています。約 {required / (1024 ** 3):.1f} GB を確保してください。")

        direction = settings.direction
        if direction == "Auto":
            self.log("ページ送り方向を自動判定します。最初のページから開始してください。")
            direction = self._detect_direction(window, region, settings)
        self.log(f"ページ送り方向: {direction}")

        output_directory, stamp = _unique_output_directory(root)
        manifest_path = output_directory / "capture-session.json"
        session: dict[str, object] = {
            "tool_version": __version__,
            "image_format": "PNG",
            "started_at": _timestamp(),
            "updated_at": _timestamp(),
            "status": "Capturing",
            "window": {
                "window_id": window.window_id,
                "process_id": window.process_id,
                "owner_name": window.owner_name,
                "title": window.title,
            },
            "direction": direction,
            "region": {
                "x": region.x,
                "y": region.y,
                "width": region.width,
                "height": region.height,
            },
            "settings": settings.manifest_values(),
            "saved_pages": 0,
            "ocr_pages": 0,
            "ocr_lines": 0,
            "pdf_path": None,
            "error": None,
        }
        _atomic_json(manifest_path, session)
        image_paths: list[Path] = []
        pdf_path: Path | None = None
        stopped = False

        try:
            with self.controller.prevent_sleep():
                self.controller.activate(window, click_page=True, region=region)
                for remaining in range(self.countdown_seconds, 0, -1):
                    self.log(f"{remaining}秒後に開始します…")
                    if not self._wait(1.0):
                        stopped = True
                        break

                previous_signature: np.ndarray | None = None
                duplicate_count = 0
                started = time.monotonic()
                profile = settings.speed

                while not stopped and (settings.max_pages == 0 or len(image_paths) < settings.max_pages):
                    if self._should_stop():
                        stopped = True
                        self.log("停止要求を受け付けました。保存済み画像からPDFを作成します。")
                        break
                    self.controller.activate(window)
                    image = self.controller.capture_region(window, region)
                    current_signature = image_signature(image)
                    difference = (
                        float("inf")
                        if previous_signature is None
                        else compare_signatures(previous_signature, current_signature)
                    )
                    if difference < settings.similarity_threshold:
                        duplicate_count += 1
                        self.log(
                            f"同じ画面を検出 ({duplicate_count}/{settings.duplicate_stop_count}, 差分 {difference:.1f})"
                        )
                        if duplicate_count >= settings.duplicate_stop_count:
                            self.log("ページが変化しないため最終ページとして停止します。")
                            break
                    else:
                        duplicate_count = 0
                        page_number = len(image_paths) + 1
                        path = output_directory / f"page_{page_number:05d}.png"
                        _save_png(image, path)
                        image_paths.append(path)
                        previous_signature = current_signature
                        self.log(f"保存: {path.name}（差分 {difference:.1f}）")
                        session["saved_pages"] = len(image_paths)
                        session["updated_at"] = _timestamp()
                        if page_number == 1 or page_number % 10 == 0:
                            _atomic_json(manifest_path, session)
                        if page_number == 1:
                            mean, contrast = signature_statistics(current_signature)
                            self.log(f"初回画像チェック: 明るさ {mean:.1f}, コントラスト {contrast:.1f}")
                            if contrast < 3.0 or mean < 3.0 or mean > 252.0:
                                self.log("警告: 最初の画像がほぼ単色です。選択範囲を確認してください。")

                    if settings.max_pages > 0 and len(image_paths) >= settings.max_pages:
                        self.log("指定した保存ページ数に達しました。")
                        break
                    if previous_signature is None:
                        continue
                    self.controller.send_page_turn(window, direction)
                    page_wait = wait_for_page_ready(
                        lambda: self._signature(window, region),
                        previous_signature,
                        settings.maximum_wait_ms,
                        profile.poll_interval_ms,
                        profile.stable_samples,
                        settings.similarity_threshold,
                        settings.effective_render_settle_ms,
                        self._should_stop,
                    )
                    if page_wait.aborted:
                        stopped = True
                        self.log("停止要求を受け付けました。保存済み画像からPDFを作成します。")
                        break
                    if page_wait.changed and not page_wait.timed_out:
                        self.log(
                            f"描画完了 {page_wait.elapsed_ms} ms "
                            f"(鮮明度待ち {page_wait.clarity_ms} ms, sharpness {page_wait.sharpness:.2f})"
                        )
                        if page_wait.clarity_timed_out:
                            self.log("警告: 鮮明度確認が上限に達しました。ぼやける場合は高解像度待ちを増やしてください。")

                elapsed = time.monotonic() - started
                self.log(f"キャプチャ完了: {len(image_paths)}ページ、{elapsed:.1f}秒")

            if image_paths:
                self._prepare_pdf_cancellation(stopped)
                session["status"] = "BuildingPdf"
                session["saved_pages"] = len(image_paths)
                session["updated_at"] = _timestamp()
                _atomic_json(manifest_path, session)
                ocr = None
                if settings.ocr_enabled:
                    try:
                        ocr = create_ocr(settings.ocr_language)
                        self.log(f"OCR: {ocr.language}")
                    except Exception as error:
                        self.log(f"警告: OCRを初期化できません。画像PDFを作成します: {error}")
                pdf_path = output_directory / f"KindleCapture_{stamp}.pdf"
                stats = build_pdf(
                    image_paths,
                    pdf_path,
                    ocr,
                    settings.ocr_language,
                    self.log,
                    self._should_stop,
                )
                self._finish_manifest(session, manifest_path, pdf_path, stats)
                self.log(f"PDF: {pdf_path}")
                if settings.open_output:
                    if sys.platform == "win32":
                        os.startfile(output_directory)  # type: ignore[attr-defined]
                    elif sys.platform == "darwin":
                        subprocess.Popen(["open", str(output_directory)])
            else:
                session["status"] = "NoPages"
                session["updated_at"] = _timestamp()
                _atomic_json(manifest_path, session)
            return CaptureResult(output_directory, tuple(image_paths), pdf_path, stopped)
        except Exception as error:
            (output_directory / "capture-error.txt").write_text(traceback.format_exc(), encoding="utf-8")
            session["status"] = "Error"
            session["error"] = str(error)
            session["updated_at"] = _timestamp()
            _atomic_json(manifest_path, session)
            raise

    @staticmethod
    def _finish_manifest(
        session: dict[str, object],
        manifest_path: Path,
        pdf_path: Path,
        stats: PdfBuildStats,
    ) -> None:
        session["status"] = "Complete"
        session["pdf_path"] = str(pdf_path)
        session["ocr_pages"] = stats.ocr_pages
        session["ocr_lines"] = stats.ocr_lines
        session["updated_at"] = _timestamp()
        _atomic_json(manifest_path, session)


def rebuild_pdf(
    folder: Path,
    ocr_enabled: bool = True,
    language: str = "ja-JP",
    log: Callable[[str], None] = print,
    should_cancel: Callable[[], bool] = lambda: False,
) -> Path:
    folder = folder.expanduser().resolve()
    images = list_capture_images(folder)
    if not images:
        raise ValueError("選択したフォルダに page_*.png がありません（旧版の jpg / jpeg も読み込めます）。")
    ocr = None
    if ocr_enabled:
        try:
            ocr = create_ocr(language)
            log(f"OCR: {ocr.language}")
        except Exception as error:
            log(f"警告: OCRを初期化できません。画像PDFを作成します: {error}")
    stamp = datetime.now().astimezone().strftime("%Y%m%d_%H%M%S")
    output = folder / f"KindleCapture_Rebuilt_{stamp}.pdf"
    build_pdf(images, output, ocr, language, log, should_cancel)
    return output
