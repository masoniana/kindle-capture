from __future__ import annotations

import queue
import threading
import tkinter as tk
import traceback
from pathlib import Path
from tkinter import filedialog, messagebox, ttk
from tkinter.scrolledtext import ScrolledText

from PIL import Image, ImageTk

from .controllers import create_controller, platform_label
from .engine import CaptureEngine, rebuild_pdf
from .models import SPEED_PROFILES, CaptureRegion, CaptureSettings, WindowInfo


class RegionDialog(tk.Toplevel):
    def __init__(self, parent: tk.Misc, image: Image.Image) -> None:
        super().__init__(parent)
        self.title("キャプチャ範囲をドラッグして選択")
        self.transient(parent)
        self.grab_set()
        self.original_size = image.size
        preview = image.copy()
        preview.thumbnail((1100, 720), Image.Resampling.LANCZOS)
        self.preview_size = preview.size
        self.photo = ImageTk.PhotoImage(preview)
        self.result: CaptureRegion | None = None
        self.start: tuple[int, int] | None = None
        self.rectangle: int | None = None

        ttk.Label(
            self,
            text="本文だけを囲むようにドラッグしてください。確定後もウィンドウサイズに追従します。",
            padding=(12, 10),
        ).pack(fill="x")
        self.canvas = tk.Canvas(
            self,
            width=preview.width,
            height=preview.height,
            highlightthickness=0,
            cursor="crosshair",
        )
        self.canvas.pack(padx=12)
        self.canvas.create_image(0, 0, image=self.photo, anchor="nw")
        self.canvas.bind("<ButtonPress-1>", self._press)
        self.canvas.bind("<B1-Motion>", self._drag)
        self.canvas.bind("<ButtonRelease-1>", self._release)

        buttons = ttk.Frame(self, padding=12)
        buttons.pack(fill="x")
        ttk.Button(buttons, text="キャンセル", command=self.destroy).pack(side="right")
        self.use_button = ttk.Button(buttons, text="この範囲を使う", command=self._accept, state="disabled")
        self.use_button.pack(side="right", padx=(0, 8))
        self.bind("<Escape>", lambda _event: self.destroy())
        self.protocol("WM_DELETE_WINDOW", self.destroy)

    def _clamp(self, x: int, y: int) -> tuple[int, int]:
        return max(0, min(self.preview_size[0], x)), max(0, min(self.preview_size[1], y))

    def _press(self, event: tk.Event) -> None:
        self.start = self._clamp(event.x, event.y)
        if self.rectangle is not None:
            self.canvas.delete(self.rectangle)
        self.rectangle = self.canvas.create_rectangle(
            self.start[0], self.start[1], self.start[0], self.start[1], outline="#28d17c", width=3
        )
        self.use_button.configure(state="disabled")

    def _drag(self, event: tk.Event) -> None:
        if self.start is None or self.rectangle is None:
            return
        x, y = self._clamp(event.x, event.y)
        self.canvas.coords(self.rectangle, self.start[0], self.start[1], x, y)

    def _release(self, event: tk.Event) -> None:
        if self.start is None or self.rectangle is None:
            return
        x, y = self._clamp(event.x, event.y)
        left, right = sorted((self.start[0], x))
        top, bottom = sorted((self.start[1], y))
        if right - left >= 40 and bottom - top >= 40:
            width, height = self.preview_size
            self.result = CaptureRegion(left / width, top / height, (right - left) / width, (bottom - top) / height)
            self.use_button.configure(state="normal")

    def _accept(self) -> None:
        if self.result is not None:
            self.destroy()


class CaptureApp:
    def __init__(self, root: tk.Tk, controller: object | None = None) -> None:
        self.root = root
        self.root.title(f"Kindle Capture for {platform_label()}")
        self.root.geometry("780x790")
        self.root.minsize(700, 690)
        self.controller = controller or create_controller()
        self.windows: list[WindowInfo] = []
        self.region: CaptureRegion | None = None
        self.worker: threading.Thread | None = None
        self.stop_event = threading.Event()
        self.events: queue.Queue[tuple[str, object]] = queue.Queue()
        self.close_after_stop = False

        self.window_var = tk.StringVar()
        self.output_var = tk.StringVar(value=str(Path.home() / "Documents" / "KindleCapture"))
        self.pages_var = tk.StringVar(value="1500")
        self.direction_var = tk.StringVar(value="Auto")
        self.area_var = tk.StringVar(value="選択範囲")
        self.speed_var = tk.StringVar(value="Turbo")
        self.settle_var = tk.StringVar(value="350")
        self.wait_var = tk.StringVar(value="1500")
        self.duplicates_var = tk.StringVar(value="3")
        self.similarity_var = tk.StringVar(value="1.0")
        self.ocr_var = tk.BooleanVar(value=True)
        self.language_var = tk.StringVar(value="ja-JP")
        self.status_var = tk.StringVar(value="準備完了")
        self.region_var = tk.StringVar(value="未指定")

        self._build_ui()
        self.refresh_windows()
        self.root.after(100, self._poll_events)
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)

    def _build_ui(self) -> None:
        main = ttk.Frame(self.root, padding=16)
        main.pack(fill="both", expand=True)
        ttk.Label(main, text="Kindle Capture", font=("TkDefaultFont", 20, "bold")).pack(anchor="w")
        ttk.Label(
            main,
            text="Kindleを自動でページ送りし、連番JPEGと検索可能なPDFを作成します。",
        ).pack(anchor="w", pady=(2, 12))

        target = ttk.LabelFrame(main, text="対象", padding=10)
        target.pack(fill="x")
        target.columnconfigure(1, weight=1)
        ttk.Label(target, text="Kindleウィンドウ").grid(row=0, column=0, sticky="w", padx=(0, 8))
        self.window_combo = ttk.Combobox(target, textvariable=self.window_var, state="readonly")
        self.window_combo.grid(row=0, column=1, sticky="ew")
        self.window_combo.bind("<<ComboboxSelected>>", self._window_changed)
        ttk.Button(target, text="更新", command=self.refresh_windows).grid(row=0, column=2, padx=(8, 0))

        ttk.Label(target, text="保存先").grid(row=1, column=0, sticky="w", pady=(8, 0))
        ttk.Entry(target, textvariable=self.output_var).grid(row=1, column=1, sticky="ew", pady=(8, 0))
        ttk.Button(target, text="参照…", command=self._choose_output).grid(row=1, column=2, padx=(8, 0), pady=(8, 0))

        settings = ttk.LabelFrame(main, text="設定", padding=10)
        settings.pack(fill="x", pady=(10, 0))
        for column in (1, 3):
            settings.columnconfigure(column, weight=1)
        self._field(settings, 0, 0, "保存ページ数 (0=最終まで)", ttk.Entry(settings, textvariable=self.pages_var, width=12))
        self._field(settings, 0, 2, "ページ送り", ttk.Combobox(settings, textvariable=self.direction_var, values=("Auto", "Right", "Left"), state="readonly", width=12))
        self._field(settings, 1, 0, "速度", ttk.Combobox(settings, textvariable=self.speed_var, values=("Turbo", "Balanced", "Safe"), state="readonly", width=12))
        self._field(settings, 1, 2, "高解像度待ち (ms)", ttk.Entry(settings, textvariable=self.settle_var, width=12))
        self._field(settings, 2, 0, "最大待ち (ms)", ttk.Entry(settings, textvariable=self.wait_var, width=12))
        self._field(settings, 2, 2, "重複停止回数", ttk.Entry(settings, textvariable=self.duplicates_var, width=12))
        self._field(settings, 3, 0, "類似判定", ttk.Entry(settings, textvariable=self.similarity_var, width=12))

        ttk.Label(settings, text="キャプチャ範囲").grid(row=4, column=0, sticky="w", pady=(9, 0))
        area_combo = ttk.Combobox(settings, textvariable=self.area_var, values=("選択範囲", "ウィンドウ全体"), state="readonly", width=14)
        area_combo.grid(row=4, column=1, sticky="w", pady=(9, 0))
        area_combo.bind("<<ComboboxSelected>>", self._area_changed)
        self.select_button = ttk.Button(settings, text="範囲を選択…", command=self.select_region)
        self.select_button.grid(row=4, column=2, sticky="w", pady=(9, 0))
        ttk.Label(settings, textvariable=self.region_var).grid(row=4, column=3, sticky="w", pady=(9, 0))

        ocr_frame = ttk.Frame(settings)
        ocr_frame.grid(row=5, column=0, columnspan=4, sticky="ew", pady=(10, 0))
        ttk.Checkbutton(ocr_frame, text="PDFに透明OCRテキストを付ける", variable=self.ocr_var).pack(side="left")
        ttk.Label(ocr_frame, text="言語").pack(side="left", padx=(18, 6))
        ttk.Entry(ocr_frame, textvariable=self.language_var, width=10).pack(side="left")
        self.speed_var.trace_add("write", self._speed_changed)

        actions = ttk.Frame(main)
        actions.pack(fill="x", pady=10)
        self.start_button = ttk.Button(actions, text="キャプチャ開始", command=self.start_capture)
        self.start_button.pack(side="left")
        self.stop_button = ttk.Button(actions, text="停止", command=self.stop_capture, state="disabled")
        self.stop_button.pack(side="left", padx=8)
        self.rebuild_button = ttk.Button(actions, text="画像からPDF再作成", command=self.start_rebuild)
        self.rebuild_button.pack(side="left")
        ttk.Label(actions, textvariable=self.status_var).pack(side="right")

        self.log_view = ScrolledText(main, height=15, wrap="word", state="disabled")
        self.log_view.pack(fill="both", expand=True)
        ttk.Label(
            main,
            text="停止: F12 または停止ボタン。実行中はKindle以外を操作しないでください。",
            foreground="#555555",
        ).pack(anchor="w", pady=(8, 0))

    @staticmethod
    def _field(parent: ttk.LabelFrame, row: int, column: int, label: str, widget: tk.Widget) -> None:
        ttk.Label(parent, text=label).grid(row=row, column=column, sticky="w", pady=4, padx=(0, 8))
        widget.grid(row=row, column=column + 1, sticky="w", pady=4, padx=(0, 14))

    def _choose_output(self) -> None:
        chosen = filedialog.askdirectory(initialdir=self.output_var.get() or str(Path.home()))
        if chosen:
            self.output_var.set(chosen)

    def _speed_changed(self, *_args: object) -> None:
        profile = SPEED_PROFILES.get(self.speed_var.get())
        if profile is not None:
            self.settle_var.set(str(profile.default_render_settle_ms))

    def _area_changed(self, _event: object = None) -> None:
        whole = self.area_var.get() == "ウィンドウ全体"
        self.select_button.configure(state="disabled" if whole else "normal")
        self.region_var.set("全体" if whole else ("指定済み" if self.region else "未指定"))

    def _window_changed(self, _event: object = None) -> None:
        self.region = None
        self._area_changed()

    def refresh_windows(self) -> None:
        try:
            selected_id = self._selected_window().window_id if self.windows and self.window_combo.current() >= 0 else None
        except Exception:
            selected_id = None
        try:
            self.windows = self.controller.list_windows()
            self.window_combo.configure(values=[window.display_name for window in self.windows])
            index = next((i for i, window in enumerate(self.windows) if window.window_id == selected_id), 0)
            if self.windows:
                self.window_combo.current(index)
            else:
                self.window_var.set("")
            self.region = None
            self._area_changed()
        except Exception as error:
            messagebox.showerror("Kindle Capture", str(error))

    def _selected_window(self) -> WindowInfo:
        index = self.window_combo.current()
        if index < 0 or index >= len(self.windows):
            raise ValueError("対象のKindleウィンドウを選択してください。")
        return self.windows[index]

    def select_region(self) -> None:
        try:
            window = self._selected_window()
            self.controller.ensure_permissions(request=True)
            image = self.controller.capture_window(window)
            dialog = RegionDialog(self.root, image)
            self.root.wait_window(dialog)
            if dialog.result is not None:
                self.region = dialog.result
                self.region_var.set("指定済み")
        except Exception as error:
            messagebox.showerror("範囲を選択できません", str(error))

    def _settings(self) -> CaptureSettings:
        return CaptureSettings(
            output_root=Path(self.output_var.get().strip()).expanduser(),
            max_pages=int(self.pages_var.get()),
            direction=self.direction_var.get(),  # type: ignore[arg-type]
            speed_mode=self.speed_var.get(),  # type: ignore[arg-type]
            render_settle_ms=int(self.settle_var.get()),
            maximum_wait_ms=int(self.wait_var.get()),
            duplicate_stop_count=int(self.duplicates_var.get()),
            similarity_threshold=float(self.similarity_var.get()),
            ocr_enabled=self.ocr_var.get(),
            ocr_language=self.language_var.get().strip(),
        ).validate()

    def _set_running(self, running: bool, status: str) -> None:
        state = "disabled" if running else "normal"
        self.start_button.configure(state=state)
        self.rebuild_button.configure(state=state)
        self.stop_button.configure(state="normal" if running else "disabled")
        self.status_var.set(status)

    def _log_from_worker(self, message: str) -> None:
        self.events.put(("log", message))

    def start_capture(self) -> None:
        try:
            window = self._selected_window()
            settings = self._settings()
            if self.area_var.get() == "ウィンドウ全体":
                region = CaptureRegion()
            elif self.region is not None:
                region = self.region
            else:
                raise ValueError("「範囲を選択…」でKindle本文を指定してください。")
        except Exception as error:
            messagebox.showwarning("設定を確認してください", str(error))
            return

        self.stop_event = threading.Event()
        self._set_running(True, "キャプチャ中 — Kindleを操作しないでください")

        def work() -> None:
            try:
                engine = CaptureEngine(self.controller, self._log_from_worker, self.stop_event)
                result = engine.run(window, region, settings)
                self.events.put(("done", result))
            except Exception:
                self.events.put(("error", traceback.format_exc()))

        self.worker = threading.Thread(target=work, name="kindle-capture", daemon=True)
        self.worker.start()

    def start_rebuild(self) -> None:
        folder = filedialog.askdirectory(title="page_*.jpg があるフォルダを選択")
        if not folder:
            return
        ocr_enabled = self.ocr_var.get()
        language = self.language_var.get().strip()
        self.stop_event = threading.Event()
        self._set_running(True, "PDF再作成中")

        def work() -> None:
            try:
                output = rebuild_pdf(
                    Path(folder),
                    ocr_enabled,
                    language,
                    self._log_from_worker,
                    self.stop_event.is_set,
                )
                self.events.put(("rebuilt", output))
            except Exception:
                self.events.put(("error", traceback.format_exc()))

        self.worker = threading.Thread(target=work, name="kindle-pdf", daemon=True)
        self.worker.start()

    def stop_capture(self) -> None:
        self.stop_event.set()
        self.status_var.set("停止要求を送信しました…")

    def _append_log(self, message: str) -> None:
        self.log_view.configure(state="normal")
        self.log_view.insert("end", message.rstrip() + "\n")
        self.log_view.see("end")
        self.log_view.configure(state="disabled")

    def _poll_events(self) -> None:
        try:
            while True:
                kind, value = self.events.get_nowait()
                if kind == "log":
                    self._append_log(str(value))
                elif kind == "done":
                    self._set_running(False, "完了")
                    result = value
                    messagebox.showinfo("完了", f"{len(result.image_paths)}ページを保存しました。\n{result.output_directory}")
                elif kind == "rebuilt":
                    self._set_running(False, "完了")
                    messagebox.showinfo("PDF再作成完了", str(value))
                elif kind == "error":
                    self._set_running(False, "エラー")
                    detail = str(value)
                    self._append_log(detail)
                    last_line = next((line for line in reversed(detail.splitlines()) if line.strip()), "不明なエラー")
                    messagebox.showerror("Kindle Capture", last_line)
        except queue.Empty:
            pass
        if self.close_after_stop and (self.worker is None or not self.worker.is_alive()):
            self.root.destroy()
            return
        self.root.after(100, self._poll_events)

    def _on_close(self) -> None:
        if self.worker is not None and self.worker.is_alive():
            if messagebox.askyesno("Kindle Capture", "実行を停止し、処理が終わってから閉じますか？"):
                self.close_after_stop = True
                self.stop_capture()
            return
        self.root.destroy()


def launch_gui() -> None:
    # Windows DPI awareness must be selected before Tk creates its first window.
    controller = create_controller()
    root = tk.Tk()
    try:
        ttk.Style(root).theme_use("aqua")
    except tk.TclError:
        pass
    CaptureApp(root, controller)
    root.mainloop()
