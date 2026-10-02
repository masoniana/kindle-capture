from __future__ import annotations

import contextlib
import io
import os
import subprocess
import sys
import time
from collections.abc import Iterator

from PIL import Image

from .models import CaptureRegion, WindowInfo
from .selection import ScreenRectangle, SelectionTargets


class MacPermissionError(RuntimeError):
    pass


def _require_macos() -> None:
    if sys.platform != "darwin":
        raise RuntimeError("この機能は macOS 上でのみ利用できます。")


class MacOSController:
    """Thin wrapper around AppKit/Core Graphics so the capture engine stays testable."""

    def __init__(self) -> None:
        _require_macos()
        import AppKit  # type: ignore[import-not-found]
        import ApplicationServices  # type: ignore[import-not-found]
        import objc  # type: ignore[import-not-found]
        import Quartz  # type: ignore[import-not-found]

        self.ApplicationServices = ApplicationServices
        self.AppKit = AppKit
        self.Quartz = Quartz
        self.objc = objc

    def list_windows(self) -> list[WindowInfo]:
        with self.objc.autorelease_pool():
            q = self.Quartz
            options = q.kCGWindowListOptionOnScreenOnly | q.kCGWindowListExcludeDesktopElements
            raw_windows = q.CGWindowListCopyWindowInfo(options, q.kCGNullWindowID) or []
            windows: list[WindowInfo] = []
            for item in raw_windows:
                layer = int(item.get(q.kCGWindowLayer, 0))
                alpha = float(item.get(q.kCGWindowAlpha, 1.0))
                bounds = item.get(q.kCGWindowBounds) or {}
                width = float(bounds.get("Width", 0.0))
                height = float(bounds.get("Height", 0.0))
                owner = str(item.get(q.kCGWindowOwnerName, ""))
                if layer != 0 or alpha <= 0.0 or width < 300 or height < 300 or not owner:
                    continue
                windows.append(
                    WindowInfo(
                        window_id=int(item[q.kCGWindowNumber]),
                        process_id=int(item[q.kCGWindowOwnerPID]),
                        owner_name=owner,
                        title=str(item.get(q.kCGWindowName, "")),
                        x=float(bounds.get("X", 0.0)),
                        y=float(bounds.get("Y", 0.0)),
                        width=width,
                        height=height,
                    )
                )
        windows.sort(key=lambda window: (not self._looks_like_kindle(window), window.owner_name.lower(), window.title.lower()))
        return windows

    @staticmethod
    def _looks_like_kindle(window: WindowInfo) -> bool:
        combined = f"{window.owner_name} {window.title}".lower()
        return "kindle" in combined or "com.amazon.kindle" in combined

    def current_window(self, expected: WindowInfo) -> WindowInfo:
        for window in self.list_windows():
            if window.window_id == expected.window_id:
                if window.process_id != expected.process_id:
                    raise RuntimeError("選択したウィンドウIDが別のプロセスに再利用されました。")
                return window
        raise RuntimeError("選択したKindleウィンドウが見つかりません。")

    def ensure_permissions(self, request: bool = True) -> None:
        q = self.Quartz
        if hasattr(q, "CGPreflightScreenCaptureAccess") and not q.CGPreflightScreenCaptureAccess():
            if request and hasattr(q, "CGRequestScreenCaptureAccess"):
                q.CGRequestScreenCaptureAccess()
            raise MacPermissionError(
                "画面収録が許可されていません。システム設定 > プライバシーとセキュリティ > "
                "画面収録で、使用中のターミナルまたはKindle Captureを許可してから再起動してください。"
            )

        accessibility = self.ApplicationServices
        trusted = bool(accessibility.AXIsProcessTrusted())
        if not trusted:
            if request and hasattr(accessibility, "AXIsProcessTrustedWithOptions"):
                option_key = getattr(
                    accessibility,
                    "kAXTrustedCheckOptionPrompt",
                    "AXTrustedCheckOptionPrompt",
                )
                accessibility.AXIsProcessTrustedWithOptions({option_key: True})
            raise MacPermissionError(
                "アクセシビリティが許可されていません。システム設定 > プライバシーとセキュリティ > "
                "アクセシビリティで、使用中のターミナルまたはKindle Captureを許可してから再実行してください。"
            )

    def activate(self, window: WindowInfo, click_page: bool = False, region: CaptureRegion | None = None) -> None:
        with self.objc.autorelease_pool():
            current = self.current_window(window)
            app = self.AppKit.NSRunningApplication.runningApplicationWithProcessIdentifier_(current.process_id)
            if app is None:
                raise RuntimeError("Kindleプロセスを前面にできませんでした。")
            options = self.AppKit.NSApplicationActivateIgnoringOtherApps
            app.activateWithOptions_(options)
            deadline = time.monotonic() + 1.5
            while time.monotonic() < deadline:
                frontmost = self.AppKit.NSWorkspace.sharedWorkspace().frontmostApplication()
                if frontmost is not None and int(frontmost.processIdentifier()) == current.process_id:
                    break
                time.sleep(0.05)
                app.activateWithOptions_(options)
            else:
                raise RuntimeError("Kindleを前面にできなかったため、誤キャプチャ防止のため停止しました。")

            if click_page:
                selected = (region or CaptureRegion()).validate()
                point = self.Quartz.CGPointMake(
                    current.x + (selected.x + selected.width * 0.5) * current.width,
                    current.y + (selected.y + selected.height * 0.70) * current.height,
                )
                self._post_mouse(self.Quartz.kCGEventMouseMoved, point)
                self._post_mouse(self.Quartz.kCGEventLeftMouseDown, point)
                self._post_mouse(self.Quartz.kCGEventLeftMouseUp, point)
                time.sleep(0.25)

    def _ax_attribute(self, element: object, name: str) -> object | None:
        error, value = self.ApplicationServices.AXUIElementCopyAttributeValue(element, name, None)
        return value if error == 0 else None

    def _ax_rectangle(self, element: object) -> ScreenRectangle | None:
        ax = self.ApplicationServices
        position = self._ax_attribute(element, "AXPosition")
        size = self._ax_attribute(element, "AXSize")
        if position is None or size is None:
            return None
        position_ok, point = ax.AXValueGetValue(position, ax.kAXValueCGPointType, None)
        size_ok, dimensions = ax.AXValueGetValue(size, ax.kAXValueCGSizeType, None)
        if not position_ok or not size_ok:
            return None
        rect = ScreenRectangle(float(point[0]), float(point[1]), float(dimensions[0]), float(dimensions[1]))
        return rect if rect.valid else None

    def _ax_window(self, window: WindowInfo) -> object | None:
        ax = self.ApplicationServices
        app = ax.AXUIElementCreateApplication(window.process_id)
        ax.AXUIElementSetMessagingTimeout(app, 0.15)
        bounds = ScreenRectangle.from_window(window)
        matches = []
        for element in self._ax_attribute(app, "AXWindows") or ():
            rect = self._ax_rectangle(element)
            if rect is not None and all(abs(a - b) <= 4 for a, b in zip(
                (rect.x, rect.y, rect.width, rect.height),
                (bounds.x, bounds.y, bounds.width, bounds.height),
            )):
                if self._ax_attribute(element, "AXTitle") == window.title:
                    return element
                matches.append(element)
        return matches[0] if len(matches) == 1 else None

    def _standard_client_rectangle(self, window: WindowInfo) -> ScreenRectangle:
        bounds = ScreenRectangle.from_window(window)
        # Full-screen windows have no title-bar inset. NSScreen is in bottom-up
        # Cocoa coordinates; CGWindow/AX coordinates start at the primary top.
        screens = self.AppKit.NSScreen.screens()
        if screens:
            primary_height = screens[0].frame().size.height
            for screen in screens:
                frame = screen.frame()
                display = ScreenRectangle(
                    frame.origin.x, primary_height - frame.origin.y - frame.size.height,
                    frame.size.width, frame.size.height,
                )
                if all(abs(a - b) <= 2 for a, b in zip(
                    (bounds.x, bounds.y, bounds.width, bounds.height),
                    (display.x, display.y, display.width, display.height),
                )):
                    return bounds
        frame = self.AppKit.NSMakeRect(0, 0, bounds.width, bounds.height)
        content = self.AppKit.NSWindow.contentRectForFrameRect_styleMask_(
            frame, self.AppKit.NSWindowStyleMaskTitled,
        )
        return ScreenRectangle(
            bounds.x + content.origin.x,
            bounds.y + bounds.height - content.origin.y - content.size.height,
            content.size.width, content.size.height,
        )

    def selection_targets(self, window: WindowInfo) -> SelectionTargets:
        current = self.current_window(window)
        bounds = ScreenRectangle.from_window(current)
        client = self._standard_client_rectangle(current)
        candidates: list[ScreenRectangle] = []
        with self.objc.autorelease_pool():
            try:
                element = self._ax_window(current)
                if element is not None:
                    if self._ax_attribute(element, "AXFullScreen"):
                        client = bounds
                    # Prefer the content bounds exposed by the target app.
                    contents = self._ax_attribute(element, "AXContents") or ()
                    content_rects = [self._ax_rectangle(child) for child in contents]
                    content_rects = [rect for rect in content_rects if rect is not None]
                    if content_rects:
                        left = min(rect.x for rect in content_rects)
                        top = min(rect.y for rect in content_rects)
                        right = max(rect.x + rect.width for rect in content_rects)
                        bottom = max(rect.y + rect.height for rect in content_rects)
                        client = ScreenRectangle(left, top, right - left, bottom - top).intersection(bounds) or client
                    roles = {"AXGroup", "AXScrollArea", "AXSplitGroup", "AXWebArea", "AXLayoutArea", "AXTextArea", "AXImage", "AXUnknown"}
                    pending = [(child, 0) for child in self._ax_attribute(element, "AXChildren") or ()]
                    visited = 0
                    deadline = time.monotonic() + 1.5
                    while pending and visited < 512 and time.monotonic() < deadline:
                        child, depth = pending.pop()
                        visited += 1
                        if self._ax_attribute(child, "AXRole") in roles:
                            rect = self._ax_rectangle(child)
                            if rect is not None:
                                candidates.append(rect)
                        if depth < 12:
                            pending.extend((descendant, depth + 1) for descendant in self._ax_attribute(child, "AXChildren") or ())
            except Exception:
                # Some Kindle versions expose no AX reading panes. Keep the
                # independently computed client fallback available to click.
                candidates = []
        return SelectionTargets(client, candidates)

    def _post_mouse(self, event_type: int, point: object) -> None:
        q = self.Quartz
        event = q.CGEventCreateMouseEvent(None, event_type, point, q.kCGMouseButtonLeft)
        if event is None:
            raise RuntimeError("マウスイベントを作成できませんでした。")
        q.CGEventPost(q.kCGHIDEventTap, event)

    def send_page_turn(self, window: WindowInfo, direction: str) -> None:
        self.activate(window)
        key_code = 123 if direction == "Left" else 124
        down = self.Quartz.CGEventCreateKeyboardEvent(None, key_code, True)
        up = self.Quartz.CGEventCreateKeyboardEvent(None, key_code, False)
        if down is None or up is None:
            raise RuntimeError("ページ送りキーを作成できませんでした。")
        self.Quartz.CGEventPost(self.Quartz.kCGHIDEventTap, down)
        self.Quartz.CGEventPost(self.Quartz.kCGHIDEventTap, up)

    def capture_window(self, window: WindowInfo) -> Image.Image:
        with self.objc.autorelease_pool():
            q = self.Quartz
            image_options = q.kCGWindowImageBoundsIgnoreFraming
            if hasattr(q, "kCGWindowImageBestResolution"):
                image_options |= q.kCGWindowImageBestResolution
            cg_image = q.CGWindowListCreateImage(
                q.CGRectNull,
                q.kCGWindowListOptionIncludingWindow,
                window.window_id,
                image_options,
            )
            if cg_image is None:
                raise MacPermissionError(
                    "ウィンドウ画像を取得できませんでした。画面収録の許可とKindleの表示状態を確認してください。"
                )
            return self._cg_image_to_pillow(cg_image)

    def _cg_image_to_pillow(self, cg_image: object) -> Image.Image:
        q = self.Quartz
        try:
            width = int(q.CGImageGetWidth(cg_image))
            height = int(q.CGImageGetHeight(cg_image))
            row_bytes = int(q.CGImageGetBytesPerRow(cg_image))
            provider = q.CGImageGetDataProvider(cg_image)
            raw = bytes(q.CGDataProviderCopyData(provider))
            return Image.frombuffer("RGBA", (width, height), raw, "raw", "BGRA", row_bytes, 1).convert("RGB")
        except Exception:
            # NSBitmapImageRep is slower, but safely handles unusual pixel layouts.
            rep = self.AppKit.NSBitmapImageRep.alloc().initWithCGImage_(cg_image)
            png_type = getattr(
                self.AppKit,
                "NSBitmapImageFileTypePNG",
                getattr(self.AppKit, "NSPNGFileType", 4),
            )
            data = rep.representationUsingType_properties_(png_type, {})
            return Image.open(io.BytesIO(bytes(data))).convert("RGB")

    def capture_region(self, window: WindowInfo, region: CaptureRegion) -> Image.Image:
        image = self.capture_window(window)
        return image.crop(region.pixel_box(image.width, image.height))

    def is_abort_key_down(self) -> bool:
        # F12 is virtual key code 111. If global key-state access is unavailable,
        # the GUI Stop button and Ctrl+C remain available.
        try:
            return bool(
                self.Quartz.CGEventSourceKeyState(
                    self.Quartz.kCGEventSourceStateCombinedSessionState,
                    111,
                )
            )
        except Exception:
            return False

    @contextlib.contextmanager
    def prevent_sleep(self) -> Iterator[None]:
        process: subprocess.Popen[bytes] | None = None
        try:
            process = subprocess.Popen(
                ["/usr/bin/caffeinate", "-dims", "-w", str(os.getpid())],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            yield
        finally:
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
