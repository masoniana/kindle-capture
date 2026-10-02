from __future__ import annotations

import tkinter as tk

import pytest

from kindle_capture.controllers import create_controller


@pytest.fixture(scope="session")
def parent_root():
    create_controller()  # Windows DPI mode must be set before the first Tk.
    try:
        parent = tk.Tk()
    except tk.TclError as error:
        if "display" in str(error).lower():
            pytest.skip(f"Tk display is unavailable: {error}")
        raise
    parent.withdraw()
    yield parent
    parent.destroy()
