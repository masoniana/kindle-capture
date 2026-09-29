from __future__ import annotations

import argparse
import signal
import sys
import threading
from pathlib import Path

from .controllers import create_controller
from .engine import CaptureEngine, rebuild_pdf
from .models import CaptureRegion, CaptureSettings


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Kindle Capture for Windows / macOS")
    subparsers = parser.add_subparsers(dest="command")

    subparsers.add_parser("gui", help="設定画面を開く")
    subparsers.add_parser("list-windows", help="キャプチャ可能なウィンドウを一覧表示")

    capture = subparsers.add_parser("capture", help="コマンドラインからキャプチャ")
    capture.add_argument("--window-id", type=int, required=True)
    capture.add_argument("--output", type=Path, default=Path.home() / "Documents" / "KindleCapture")
    capture.add_argument("--pages", type=int, default=1500, help="0なら最終ページまで")
    capture.add_argument("--direction", choices=("Auto", "Right", "Left"), default="Auto")
    capture.add_argument("--speed", choices=("Turbo", "Balanced", "Safe"), default="Turbo")
    capture.add_argument("--settle-ms", type=int)
    capture.add_argument("--maximum-wait-ms", type=int, default=1500)
    capture.add_argument("--duplicate-stop-count", type=int, default=3)
    capture.add_argument("--similarity", type=float, default=1.0)
    capture.add_argument("--region", nargs=4, type=float, metavar=("X", "Y", "WIDTH", "HEIGHT"), default=(0, 0, 1, 1))
    capture.add_argument("--no-ocr", action="store_true")
    capture.add_argument("--ocr-language", default="ja-JP")
    capture.add_argument("--no-open", action="store_true")

    rebuild = subparsers.add_parser("rebuild", help="保存画像からPDFを再作成")
    rebuild.add_argument("folder", type=Path)
    rebuild.add_argument("--no-ocr", action="store_true")
    rebuild.add_argument("--ocr-language", default="ja-JP")
    return parser


def main(argv: list[str] | None = None) -> int:
    if sys.platform == "win32" and hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    args = _parser().parse_args(argv)
    if args.command in (None, "gui"):
        from .gui import launch_gui

        launch_gui()
        return 0

    if args.command == "rebuild":
        output = rebuild_pdf(args.folder, not args.no_ocr, args.ocr_language)
        print(output)
        return 0

    controller = create_controller()
    windows = controller.list_windows()
    if args.command == "list-windows":
        for window in windows:
            print(f"{window.window_id}\tPID {window.process_id}\t{window.display_name}")
        return 0

    window = next((item for item in windows if item.window_id == args.window_id), None)
    if window is None:
        raise SystemExit(f"window-id {args.window_id} が見つかりません。list-windows で確認してください。")
    region = CaptureRegion(*args.region).validate()
    settings = CaptureSettings(
        output_root=args.output,
        max_pages=args.pages,
        direction=args.direction,
        speed_mode=args.speed,
        render_settle_ms=args.settle_ms,
        maximum_wait_ms=args.maximum_wait_ms,
        duplicate_stop_count=args.duplicate_stop_count,
        similarity_threshold=args.similarity,
        ocr_enabled=not args.no_ocr,
        ocr_language=args.ocr_language,
        open_output=not args.no_open,
    ).validate()
    stop_event = threading.Event()

    def request_stop(_signum: int, _frame: object) -> None:
        print("\n停止要求を受け付けました。保存済み画像からPDFを作成します。")
        stop_event.set()

    signal.signal(signal.SIGINT, request_stop)
    result = CaptureEngine(controller, stop_event=stop_event).run(window, region, settings)
    print(result.output_directory)
    return 0
