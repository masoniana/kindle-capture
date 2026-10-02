from __future__ import annotations

from types import SimpleNamespace

import pytest
from PIL import Image

from kindle_capture.gui import RegionDialog
from kindle_capture.models import CaptureResult, WindowInfo
from kindle_capture.selection import ScreenRectangle, SelectionTargets


@pytest.fixture
def root(parent_root):
    parent_root.withdraw()
    yield parent_root
    for child in parent_root.winfo_children():
        child.destroy()
    parent_root.update()
    parent_root.withdraw()


def make_dialog(root, *, detectable=True, x=100) -> RegionDialog:
    window = WindowInfo(1, 2, "Kindle", "Test", x, 100, 600, 500)
    client = ScreenRectangle(x, 125, 600, 475)
    page = ScreenRectangle(x + 100, 150, 400, 400)
    dialog = RegionDialog(root, Image.new("RGB", (1200, 1000), "white"), window, SelectionTargets(client, [page] if detectable else []))
    root.update()
    return dialog


def test_hover_draws_green_pane_without_drag_then_one_click_confirms(root) -> None:
    dialog = make_dialog(root)
    # Call the Motion handler directly so the real desktop pointer cannot
    # race a synthetic Tk motion event during the test.
    dialog._hover(SimpleNamespace(x=200, y=200))
    assert dialog.canvas.coords(dialog.rectangle) == [102, 52, 498, 448]
    assert dialog.canvas.itemcget(dialog.rectangle, "outline") == "#00e676"
    assert dialog.result is None
    dialog.canvas.event_generate("<ButtonPress-1>", x=200, y=200)
    root.update()
    assert not dialog.winfo_exists()
    assert dialog.result.pixel_box(1200, 1000) == (200, 100, 1000, 900)


def test_click_without_motion_uses_its_position_and_negative_screen_origin(root) -> None:
    dialog = make_dialog(root, x=-500)
    dialog.canvas.event_generate("<ButtonPress-1>", x=200, y=200)
    root.update()
    assert dialog.result.pixel_box(600, 500) == (100, 50, 500, 450)


def test_fallback_can_be_confirmed_with_one_click(root) -> None:
    dialog = make_dialog(root, detectable=False)
    dialog.canvas.event_generate("<ButtonPress-1>", x=300, y=250)
    root.update()
    assert dialog.result.pixel_box(1200, 1000) == (0, 50, 1200, 1000)


def test_escape_cancels_and_title_bar_click_does_not_confirm(root) -> None:
    dialog = make_dialog(root)
    dialog.canvas.event_generate("<ButtonPress-1>", x=300, y=10)
    root.update()
    assert dialog.winfo_exists()
    assert dialog.result is None
    dialog.event_generate("<Escape>")
    root.update()
    assert not dialog.winfo_exists()
    assert dialog.result is None


def test_start_without_region_selects_then_passes_crop_to_engine(root, monkeypatch, tmp_path) -> None:
    from kindle_capture import gui

    window = WindowInfo(1, 2, "Kindle", "Test", 100, 100, 600, 500)
    client = ScreenRectangle.from_window(window)
    page = ScreenRectangle(200, 150, 400, 400)
    selected = []
    controller = SimpleNamespace(
        list_windows=lambda: [window],
        ensure_permissions=lambda request: None,
        activate=lambda window: None,
        current_window=lambda window: window,
        selection_targets=lambda window: SelectionTargets(client, [page]),
        capture_window=lambda window: Image.new("RGB", (1200, 1000), "white"),
    )

    class AutoClickDialog(RegionDialog):
        def __init__(self, *args):
            super().__init__(*args)
            self.after_idle(lambda: self._accept(SimpleNamespace(x=200, y=200)))

    class FakeEngine:
        def __init__(self, *args):
            pass

        def run(self, target, region, settings):
            selected.append((target, region))
            return CaptureResult(tmp_path, (), None, False)

    monkeypatch.setattr(gui, "RegionDialog", AutoClickDialog)
    monkeypatch.setattr(gui, "CaptureEngine", FakeEngine)
    monkeypatch.setattr(gui.messagebox, "showinfo", lambda *args: None)
    app = gui.CaptureApp(root, controller)
    app.output_var.set(str(tmp_path))
    app.start_capture()
    app.worker.join(timeout=2)
    assert selected[0][0] == window
    assert selected[0][1].pixel_box(600, 500) == (100, 50, 500, 450)
    assert app.region == selected[0][1]
    assert root.state() == "normal"
    app._poll_events()
    for timer in root.tk.call("after", "info"):
        root.after_cancel(timer)
