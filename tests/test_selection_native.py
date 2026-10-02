from __future__ import annotations

import contextlib
import sys
import tkinter as tk
from types import SimpleNamespace

import pytest

from kindle_capture.macos import MacOSController
from kindle_capture.models import WindowInfo
from kindle_capture.selection import ScreenRectangle


class FakeAX:
    kAXValueCGPointType = 1
    kAXValueCGSizeType = 2

    def __init__(self, nodes):
        self.nodes = nodes

    def AXUIElementCreateApplication(self, _pid):
        return "app"

    def AXUIElementSetMessagingTimeout(self, _element, _seconds):
        pass

    def AXUIElementCopyAttributeValue(self, element, name, _out):
        value = self.nodes[element].get(name)
        return (0, value) if value is not None else (1, None)

    def AXValueGetValue(self, value, _type, _out):
        return True, value


def node(x, y, width, height, **attributes):
    return {"AXPosition": (x, y), "AXSize": (width, height), **attributes}


def make_macos_controller(nodes):
    controller = object.__new__(MacOSController)
    controller.ApplicationServices = FakeAX(nodes)
    controller.objc = SimpleNamespace(autorelease_pool=contextlib.nullcontext)
    controller.current_window = lambda window: window
    controller._standard_client_rectangle = lambda window: ScreenRectangle(window.x, window.y + 28, window.width, window.height - 28)
    return controller


def test_macos_reads_only_the_selected_windows_ax_descendants() -> None:
    window = WindowInfo(1, 2, "Kindle", "Book", 100, 100, 800, 600)
    nodes = {
        "app": {"AXWindows": ["other", "selected"]},
        "other": node(1200, 100, 800, 600, AXTitle="Other", AXChildren=["other_page"]),
        "other_page": node(1200, 140, 800, 560, AXRole="AXWebArea"),
        "selected": node(100, 100, 800, 600, AXTitle="Book", AXChildren=["group", "button"]),
        "group": node(100, 128, 800, 572, AXRole="AXGroup", AXChildren=["page"]),
        "page": node(200, 180, 600, 450, AXRole="AXWebArea"),
        "button": node(100, 128, 400, 300, AXRole="AXButton"),
    }
    targets = make_macos_controller(nodes).selection_targets(window)
    assert targets.at(300, 300) == ScreenRectangle(200, 180, 600, 450)
    assert targets.at(110, 140) == targets.client
    assert ScreenRectangle(1200, 140, 800, 560) not in targets.candidates


def test_macos_missing_ax_window_uses_standard_client() -> None:
    window = WindowInfo(1, 2, "Kindle", "Book", 0, 0, 800, 600)
    targets = make_macos_controller({"app": {}}).selection_targets(window)
    assert targets.candidates == ()
    assert targets.at(400, 300) == ScreenRectangle(0, 28, 800, 572)


def test_macos_prefers_ax_content_rectangle_and_handles_fullscreen() -> None:
    window = WindowInfo(1, 2, "Kindle", "Book", 0, 0, 800, 600)
    nodes = {
        "app": {"AXWindows": ["selected"]},
        "selected": node(0, 0, 800, 600, AXTitle="Book", AXContents=["content"]),
        "content": node(0, 40, 800, 560),
    }
    controller = make_macos_controller(nodes)
    assert controller.selection_targets(window).client == ScreenRectangle(0, 40, 800, 560)
    nodes["selected"].pop("AXContents")
    nodes["selected"]["AXFullScreen"] = True
    assert controller.selection_targets(window).client == ScreenRectangle.from_window(window)


@pytest.mark.skipif(sys.platform != "win32", reason="Win32 child-window integration")
def test_windows_native_child_panes_are_detected(parent_root) -> None:
    from kindle_capture.windows import WindowsController

    controller = WindowsController()
    root = parent_root
    try:
        root.title("Kindle Capture native selection test")
        root.geometry("700x600+100+100")
        pane = tk.Frame(root)
        pane.place(x=80, y=60, width=500, height=450)
        nested = tk.Frame(pane)
        nested.place(x=50, y=40, width=400, height=350)
        root.deiconify()
        root.update()
        window = next(window for window in controller.list_windows() if window.title == root.title())
        targets = controller.selection_targets(window)
        expected = ScreenRectangle(window.x + 130, window.y + 100, 400, 350)
        assert targets.at(window.x + 200, window.y + 200) == expected
        assert targets.at(window.x + 5, window.y + 5) == targets.client
    finally:
        pane.destroy()
        root.withdraw()


@pytest.mark.skipif(sys.platform != "darwin", reason="PyObjC AXValue binding integration")
def test_macos_native_axvalue_and_standard_client_bindings() -> None:
    controller = MacOSController()
    ax = controller.ApplicationServices
    value = ax.AXValueCreate(ax.kAXValueCGPointType, (150, 250))
    ok, point = ax.AXValueGetValue(value, ax.kAXValueCGPointType, None)
    assert ok and tuple(point) == (150, 250)
    window = WindowInfo(1, 2, "Kindle", "Book", 100, 100, 800, 600)
    client = controller._standard_client_rectangle(window)
    assert client.x >= window.x and client.y > window.y
    assert client.width <= window.width and client.height < window.height
