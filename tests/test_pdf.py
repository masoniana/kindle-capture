from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw
from pypdf import PdfReader

from kindle_capture.models import OcrLine
from kindle_capture.pdf import build_pdf


class FakeOcr:
    def recognize(self, _path: Path) -> list[OcrLine]:
        return [OcrLine("テスト本文", 50, 80, 200, 30)]


def test_builds_searchable_pdf(tmp_path: Path) -> None:
    images = []
    for page in range(2):
        path = tmp_path / f"page_{page + 1:05d}.jpg"
        image = Image.new("RGB", (600, 900), "white")
        ImageDraw.Draw(image).rectangle((50, 80, 250, 110), fill="black")
        image.save(path, "JPEG", quality=90)
        images.append(path)

    output = tmp_path / "book.pdf"
    stats = build_pdf(images, output, FakeOcr(), log=lambda _message: None)
    reader = PdfReader(output)
    assert len(reader.pages) == 2
    assert stats.pages == 2
    assert stats.ocr_pages == 2
    assert stats.searchable is True
    assert "テスト本文" in (reader.pages[0].extract_text() or "")
