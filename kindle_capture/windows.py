from __future__ import annotations

import contextlib
import ctypes
import sys
import time
from collections.abc import Iterator
from ctypes import wintypes
from pathlib import Path

from PIL import Image, ImageGrab

from .models import CaptureRegion, WindowInfo


class RECT(ctypes.Structure):
    _fields_ = [
        ("left", wintypes.LONG),
        ("top", wintypes.LONG),
        ("right", wintypes.LONG),
        ("bottom", wintypes.LONG),
    ]


class POINT(ctypes.Structure):
    _fields_ = [("x", wintypes.LONG), ("y", wintypes.LONG)]


ULONG_PTR = wintypes.WPARAM


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [
        ("wVk", wintypes.WORD),
        ("wScan", wintypes.WORD),
        ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ULONG_PTR),
    ]


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [
        ("dx", wintypes.LONG),
        ("dy", wintypes.LONG),
        ("mouseData", wintypes.DWORD),
        ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ULONG_PTR),
    ]


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [
        ("uMsg", wintypes.DWORD),
        ("wParamL", wintypes.WORD),
        ("wParamH", wintypes.WORD),
    ]


class INPUTUNION(ctypes.Union):
    _fields_ = [("ki", KEYBDINPUT), ("mi", MOUSEINPUT), ("hi", HARDWAREINPUT)]


class INPUT(ctypes.Structure):
    _anonymous_ = ("value",)
    _fields_ = [("type", wintypes.DWORD), ("value", INPUTUNION)]


class WindowsController:
    def __init__(self) -> None:
        if sys.platform != "win32":
            raise RuntimeError("この機能はWindows上でのみ利用できます。")
        self.user32 = ctypes.WinDLL("user32", use_last_error=True)
        self.kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        self._configure_functions()
        self._enable_dpi_awareness()

    def _configure_functions(self) -> None:
        self.WNDENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
        self.user32.EnumWindows.argtypes = [self.WNDENUMPROC, wintypes.LPARAM]
        self.user32.EnumWindows.restype = wintypes.BOOL
        self.user32.IsWindow.argtypes = [wintypes.HWND]
        self.user32.IsWindow.restype = wintypes.BOOL
        self.user32.IsWindowVisible.argtypes = [wintypes.HWND]
        self.user32.IsWindowVisible.restype = wintypes.BOOL
        self.user32.GetWindowTextLengthW.argtypes = [wintypes.HWND]
        self.user32.GetWindowTextLengthW.restype = ctypes.c_int
        self.user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
        self.user32.GetWindowTextW.restype = ctypes.c_int
        self.user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
        self.user32.GetWindowThreadProcessId.restype = wintypes.DWORD
        self.user32.GetClientRect.argtypes = [wintypes.HWND, ctypes.POINTER(RECT)]
        self.user32.GetClientRect.restype = wintypes.BOOL
        self.user32.ClientToScreen.argtypes = [wintypes.HWND, ctypes.POINTER(POINT)]
        self.user32.ClientToScreen.restype = wintypes.BOOL
        self.user32.SetForegroundWindow.argtypes = [wintypes.HWND]
        self.user32.SetForegroundWindow.restype = wintypes.BOOL
        self.user32.GetForegroundWindow.restype = wintypes.HWND
        self.user32.IsIconic.argtypes = [wintypes.HWND]
        self.user32.IsIconic.restype = wintypes.BOOL
        self.user32.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]
        self.user32.SetCursorPos.argtypes = [ctypes.c_int, ctypes.c_int]
        self.user32.SetCursorPos.restype = wintypes.BOOL
        self.user32.SendInput.argtypes = [wintypes.UINT, ctypes.POINTER(INPUT), ctypes.c_int]
        self.user32.SendInput.restype = wintypes.UINT
        self.user32.GetAsyncKeyState.argtypes = [ctypes.c_int]
        self.user32.GetAsyncKeyState.restype = wintypes.SHORT
        self.kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        self.kernel32.OpenProcess.restype = wintypes.HANDLE
        self.kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
        self.kernel32.QueryFullProcessImageNameW.argtypes = [
            wintypes.HANDLE,
            wintypes.DWORD,
            wintypes.LPWSTR,
            ctypes.POINTER(wintypes.DWORD),
        ]
        self.kernel32.QueryFullProcessImageNameW.restype = wintypes.BOOL
        self.kernel32.SetThreadExecutionState.argtypes = [wintypes.DWORD]
        self.kernel32.SetThreadExecutionState.restype = wintypes.DWORD

    def _enable_dpi_awareness(self) -> None:
        try:
            setter = self.user32.SetProcessDpiAwarenessContext
            setter.argtypes = [wintypes.HANDLE]
            setter.restype = wintypes.BOOL
            if setter(ctypes.c_void_p(-4)):
                return
        except (AttributeError, OSError):
            pass
        try:
            self.user32.SetProcessDPIAware()
        except AttributeError:
            pass

    def _window_text(self, handle: int) -> str:
        length = self.user32.GetWindowTextLengthW(handle)
        if length <= 0:
            return ""
        buffer = ctypes.create_unicode_buffer(length + 1)
        self.user32.GetWindowTextW(handle, buffer, len(buffer))
        return buffer.value

    def _process_name(self, process_id: int) -> str:
        process_query_limited_information = 0x1000
        handle = self.kernel32.OpenProcess(process_query_limited_information, False, process_id)
        if not handle:
            return f"PID {process_id}"
        try:
            size = wintypes.DWORD(32768)
            buffer = ctypes.create_unicode_buffer(size.value)
            if self.kernel32.QueryFullProcessImageNameW(handle, 0, buffer, ctypes.byref(size)):
                return Path(buffer.value).stem
            return f"PID {process_id}"
        finally:
            self.kernel32.CloseHandle(handle)

    def _client_bounds(self, handle: int) -> tuple[int, int, int, int]:
        rect = RECT()
        if not self.user32.GetClientRect(handle, ctypes.byref(rect)):
            raise ctypes.WinError(ctypes.get_last_error())
        origin = POINT(rect.left, rect.top)
        if not self.user32.ClientToScreen(handle, ctypes.byref(origin)):
            raise ctypes.WinError(ctypes.get_last_error())
        return origin.x, origin.y, rect.right - rect.left, rect.bottom - rect.top

    def list_windows(self) -> list[WindowInfo]:
        windows: list[WindowInfo] = []

        @self.WNDENUMPROC
        def callback(handle: int, _parameter: int) -> bool:
            if not self.user32.IsWindowVisible(handle):
                return True
            title = self._window_text(handle).strip()
            if not title:
                return True
            try:
                x, y, width, height = self._client_bounds(handle)
            except OSError:
                return True
            if width < 300 or height < 300:
                return True
            process_id = wintypes.DWORD()
            self.user32.GetWindowThreadProcessId(handle, ctypes.byref(process_id))
            windows.append(
                WindowInfo(
                    window_id=int(handle),
                    process_id=int(process_id.value),
                    owner_name=self._process_name(process_id.value),
                    title=title,
                    x=float(x),
                    y=float(y),
                    width=float(width),
                    height=float(height),
                )
            )
            return True

        if not self.user32.EnumWindows(callback, 0):
            raise ctypes.WinError(ctypes.get_last_error())
        windows.sort(
            key=lambda window: (
                not self._looks_like_kindle(window),
                window.owner_name.lower(),
                window.title.lower(),
            )
        )
        return windows

    @staticmethod
    def _looks_like_kindle(window: WindowInfo) -> bool:
        return "kindle" in f"{window.owner_name} {window.title}".lower()

    def current_window(self, expected: WindowInfo) -> WindowInfo:
        if not self.user32.IsWindow(expected.window_id):
            raise RuntimeError("選択したKindleウィンドウが閉じられました。")
        process_id = wintypes.DWORD()
        self.user32.GetWindowThreadProcessId(expected.window_id, ctypes.byref(process_id))
        if int(process_id.value) != expected.process_id:
            raise RuntimeError("選択したウィンドウIDが別のプロセスに再利用されました。")
        if not self.user32.IsWindowVisible(expected.window_id):
            raise RuntimeError("選択したKindleウィンドウが表示されていません。")
        x, y, width, height = self._client_bounds(expected.window_id)
        return WindowInfo(
            expected.window_id,
            expected.process_id,
            expected.owner_name,
            self._window_text(expected.window_id),
            float(x),
            float(y),
            float(width),
            float(height),
        )

    def ensure_permissions(self, request: bool = True) -> None:
        return None

    def activate(
        self,
        window: WindowInfo,
        click_page: bool = False,
        region: CaptureRegion | None = None,
    ) -> None:
        current = self.current_window(window)
        if self.user32.IsIconic(current.window_id):
            self.user32.ShowWindow(current.window_id, 9)  # SW_RESTORE
            time.sleep(0.2)
        deadline = time.monotonic() + 1.2
        while self.user32.GetForegroundWindow() != current.window_id and time.monotonic() < deadline:
            self.user32.SetForegroundWindow(current.window_id)
            time.sleep(0.05)
        if self.user32.GetForegroundWindow() != current.window_id:
            raise RuntimeError("Kindleを前面にできなかったため、誤キャプチャ防止のため停止しました。")
        if click_page:
            selected = (region or CaptureRegion()).validate()
            click_x = round(current.x + (selected.x + selected.width * 0.5) * current.width)
            click_y = round(current.y + (selected.y + selected.height * 0.70) * current.height)
            if not self.user32.SetCursorPos(click_x, click_y):
                raise ctypes.WinError(ctypes.get_last_error())
            inputs = (INPUT * 2)()
            inputs[0].type = 0
            inputs[0].mi.dwFlags = 0x0002  # MOUSEEVENTF_LEFTDOWN
            inputs[1].type = 0
            inputs[1].mi.dwFlags = 0x0004  # MOUSEEVENTF_LEFTUP
            if self.user32.SendInput(2, inputs, ctypes.sizeof(INPUT)) != 2:
                raise RuntimeError("WindowsがKindleへのクリックを受け付けませんでした。")
            time.sleep(0.25)

    def send_page_turn(self, window: WindowInfo, direction: str) -> None:
        self.activate(window)
        for virtual_key in (0x10, 0x11, 0x12, 0x5B, 0x5C):
            if self.user32.GetAsyncKeyState(virtual_key) & 0x8000:
                raise RuntimeError("修飾キーを離してから実行してください。")
        key = 0x25 if direction == "Left" else 0x27
        inputs = (INPUT * 2)()
        inputs[0].type = 1
        inputs[0].ki.wVk = key
        inputs[0].ki.dwFlags = 0x0001  # KEYEVENTF_EXTENDEDKEY
        inputs[1].type = 1
        inputs[1].ki.wVk = key
        inputs[1].ki.dwFlags = 0x0001 | 0x0002  # KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP
        if self.user32.SendInput(2, inputs, ctypes.sizeof(INPUT)) != 2:
            raise RuntimeError("Windowsがページ送りキーを受け付けませんでした。")

    def capture_window(self, window: WindowInfo) -> Image.Image:
        current = self.current_window(window)
        box = (
            round(current.x),
            round(current.y),
            round(current.x + current.width),
            round(current.y + current.height),
        )
        return ImageGrab.grab(bbox=box, all_screens=True).convert("RGB")

    def capture_region(self, window: WindowInfo, region: CaptureRegion) -> Image.Image:
        image = self.capture_window(window)
        return image.crop(region.pixel_box(image.width, image.height))

    def is_abort_key_down(self) -> bool:
        return bool(self.user32.GetAsyncKeyState(0x7B) & 0x8000)  # F12

    @contextlib.contextmanager
    def prevent_sleep(self) -> Iterator[None]:
        es_continuous = 0x80000000
        es_system_required = 0x00000001
        es_display_required = 0x00000002
        enabled = self.kernel32.SetThreadExecutionState(
            es_continuous | es_system_required | es_display_required
        )
        try:
            yield
        finally:
            if enabled:
                self.kernel32.SetThreadExecutionState(es_continuous)
