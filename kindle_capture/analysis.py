from __future__ import annotations

import math
import time
from collections.abc import Callable

import numpy as np
from PIL import Image

from .models import PageReadyResult

SIGNATURE_WIDTH = 160
SIGNATURE_HEIGHT = 120


def image_signature(image: Image.Image) -> np.ndarray:
    gray = image.convert("L").resize((SIGNATURE_WIDTH, SIGNATURE_HEIGHT), Image.Resampling.BICUBIC)
    return np.asarray(gray, dtype=np.uint8)


def compare_signatures(first: np.ndarray, second: np.ndarray) -> float:
    if first.shape != second.shape or first.shape != (SIGNATURE_HEIGHT, SIGNATURE_WIDTH):
        raise ValueError("ページ特徴量のサイズが一致しません。")

    a = first.astype(np.int16, copy=False)
    b = second.astype(np.int16, copy=False)
    differences = np.abs(a - b)
    mean_absolute = float(differences.mean())
    root_mean_square = math.sqrt(float(np.square(differences.astype(np.float64)).mean()))
    material_percent = float(np.count_nonzero(differences >= 4)) * 100.0 / differences.size

    first_horizontal = np.sign(np.where(np.abs(np.diff(a, axis=1)) > 2, np.diff(a, axis=1), 0))
    second_horizontal = np.sign(np.where(np.abs(np.diff(b, axis=1)) > 2, np.diff(b, axis=1), 0))
    first_vertical = np.sign(np.where(np.abs(np.diff(a, axis=0)) > 2, np.diff(a, axis=0), 0))
    second_vertical = np.sign(np.where(np.abs(np.diff(b, axis=0)) > 2, np.diff(b, axis=0), 0))
    mismatch = np.count_nonzero(first_horizontal != second_horizontal)
    mismatch += np.count_nonzero(first_vertical != second_vertical)
    edge_count = first_horizontal.size + first_vertical.size
    edge_mismatch_percent = 100.0 * float(mismatch) / edge_count if edge_count else 0.0

    return mean_absolute + 0.35 * root_mean_square + 0.05 * material_percent + 0.03 * edge_mismatch_percent


def signature_sharpness(signature: np.ndarray) -> float:
    if signature.shape != (SIGNATURE_HEIGHT, SIGNATURE_WIDTH):
        raise ValueError("ページ特徴量のサイズが不正です。")
    values = signature.astype(np.int16, copy=False)
    center = values[1:-1, 1:-1]
    laplacian = (
        4 * center
        - values[1:-1, :-2]
        - values[1:-1, 2:]
        - values[:-2, 1:-1]
        - values[2:, 1:-1]
    )
    return math.sqrt(float(np.square(laplacian.astype(np.float64)).mean()))


def signature_statistics(signature: np.ndarray) -> tuple[float, float]:
    values = signature.astype(np.float64, copy=False)
    return float(values.mean()), float(values.std())


def _interruptible_wait(seconds: float, should_stop: Callable[[], bool]) -> bool:
    deadline = time.monotonic() + max(0.0, seconds)
    while True:
        if should_stop():
            return True
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        time.sleep(min(0.05, remaining))


def wait_for_render_clarity(
    capture_signature: Callable[[], np.ndarray],
    initial_signature: np.ndarray,
    minimum_wait_ms: int,
    poll_interval_ms: int,
    stable_samples: int,
    should_stop: Callable[[], bool],
    stable_threshold: float = 0.35,
    sharpness_tolerance: float = 0.015,
) -> PageReadyResult:
    started = time.monotonic()
    current = initial_signature
    current_sharpness = signature_sharpness(current)
    if minimum_wait_ms <= 0:
        return PageReadyResult(True, False, False, 0, current, current_sharpness, 0, False)

    maximum_wait_ms = minimum_wait_ms + max(300, minimum_wait_ms)
    last = current
    last_sharpness = current_sharpness
    peak_sharpness = current_sharpness
    stable_count = 0

    while (time.monotonic() - started) * 1000.0 < maximum_wait_ms:
        if _interruptible_wait(poll_interval_ms / 1000.0, should_stop):
            elapsed = round((time.monotonic() - started) * 1000.0)
            return PageReadyResult(True, False, True, elapsed, current, current_sharpness, elapsed, False)
        current = capture_signature()
        current_sharpness = signature_sharpness(current)
        movement = compare_signatures(last, current)
        peak_sharpness = max(peak_sharpness, current_sharpness)
        scale = max(1.0, abs(last_sharpness), abs(peak_sharpness))
        sharpness_change = abs(current_sharpness - last_sharpness) / scale
        near_peak = current_sharpness >= peak_sharpness * (1.0 - sharpness_tolerance)
        elapsed = round((time.monotonic() - started) * 1000.0)
        if elapsed < minimum_wait_ms:
            stable_count = 0
        elif movement <= stable_threshold and sharpness_change <= sharpness_tolerance and near_peak:
            stable_count += 1
        else:
            stable_count = 0
        last = current
        last_sharpness = current_sharpness
        if elapsed >= minimum_wait_ms and stable_count >= stable_samples:
            return PageReadyResult(True, False, False, elapsed, current, current_sharpness, elapsed, False)

    elapsed = round((time.monotonic() - started) * 1000.0)
    return PageReadyResult(True, False, False, elapsed, current, current_sharpness, elapsed, True)


def wait_for_page_ready(
    capture_signature: Callable[[], np.ndarray],
    previous_signature: np.ndarray,
    maximum_wait_ms: int,
    poll_interval_ms: int,
    stable_samples: int,
    change_threshold: float,
    render_settle_ms: int,
    should_stop: Callable[[], bool],
    stable_threshold: float = 0.35,
) -> PageReadyResult:
    started = time.monotonic()
    changed = False
    stable_count = 0
    last = previous_signature
    current = previous_signature

    while (time.monotonic() - started) * 1000.0 < maximum_wait_ms:
        if _interruptible_wait(poll_interval_ms / 1000.0, should_stop):
            elapsed = round((time.monotonic() - started) * 1000.0)
            return PageReadyResult(changed, False, True, elapsed, current, signature_sharpness(current), 0, False)
        current = capture_signature()
        if not changed:
            if compare_signatures(previous_signature, current) >= change_threshold:
                changed = True
                stable_count = 0
                last = current
            continue
        movement = compare_signatures(last, current)
        stable_count = stable_count + 1 if movement <= stable_threshold else 0
        last = current
        if stable_count >= stable_samples:
            clarity = wait_for_render_clarity(
                capture_signature,
                current,
                render_settle_ms,
                poll_interval_ms,
                stable_samples,
                should_stop,
                stable_threshold,
            )
            elapsed = round((time.monotonic() - started) * 1000.0)
            return PageReadyResult(
                True,
                False,
                clarity.aborted,
                elapsed,
                clarity.signature,
                clarity.sharpness,
                clarity.elapsed_ms,
                clarity.clarity_timed_out,
            )

    clarity_ms = 0
    clarity_timed_out = False
    final_sharpness = signature_sharpness(current)
    if changed and render_settle_ms > 0:
        clarity = wait_for_render_clarity(
            capture_signature,
            current,
            render_settle_ms,
            poll_interval_ms,
            stable_samples,
            should_stop,
            stable_threshold,
        )
        current = clarity.signature
        final_sharpness = clarity.sharpness
        clarity_ms = clarity.elapsed_ms
        clarity_timed_out = clarity.clarity_timed_out
        if clarity.aborted:
            elapsed = round((time.monotonic() - started) * 1000.0)
            return PageReadyResult(True, False, True, elapsed, current, final_sharpness, clarity_ms, False)

    elapsed = round((time.monotonic() - started) * 1000.0)
    return PageReadyResult(changed, True, False, elapsed, current, final_sharpness, clarity_ms, clarity_timed_out)
