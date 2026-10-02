from __future__ import annotations

from pathlib import Path

import pytest
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
        path = tmp_path / f"page_{page + 1:05d}.png"
        image = Image.new("RGB", (600, 900), "white")
        ImageDraw.Draw(image).rectangle((50, 80, 250, 110), fill="black")
        image.save(path, "PNG")
        images.append(path)

    output = tmp_path / "book.pdf"
    stats = build_pdf(images, output, FakeOcr(), log=lambda _message: None)
    reader = PdfReader(output)
    assert len(reader.pages) == 2
    assert stats.pages == 2
    assert stats.ocr_pages == 2
    assert stats.searchable is True
    assert "テスト本文" in (reader.pages[0].extract_text() or "")
    embedded = reader.pages[0]["/Resources"]["/XObject"]["/Im0"]
    assert embedded["/Filter"] == "/FlateDecode"
    with Image.open(images[0]) as original:
        assert embedded.get_data() == original.tobytes()


@pytest.mark.parametrize("mode", ["RGB", "L", "P", "RGBA"])
def test_png_pixels_survive_pdf_embedding_losslessly(tmp_path: Path, mode: str) -> None:
    width, height = 37, 23
    # High-frequency color data exposes any accidental JPEG conversion.
    pixels = bytes((index * 53 + index // 7) % 256 for index in range(width * height * 3))
    image = Image.frombytes("RGB", (width, height), pixels).convert(mode)
    if mode == "RGBA":
        image.putalpha(127)
        expected = Image.new("RGB", image.size, "white")
        expected.paste(image, mask=image.getchannel("A"))
    else:
        expected = image.convert("RGB")
    path = tmp_path / "page_00001.png"
    image.save(path, "PNG")
    output = tmp_path / "book.pdf"
    build_pdf([path], output, log=lambda _message: None)
    page = PdfReader(output).pages[0]
    embedded = page["/Resources"]["/XObject"]["/Im0"]
    assert embedded["/Filter"] == "/FlateDecode"
    assert (embedded["/Width"], embedded["/Height"]) == image.size
    assert embedded.get_data() == expected.tobytes()
    assert page.images[0].image.convert("RGB").tobytes() == expected.tobytes()


def test_old_jpeg_is_embedded_without_reencoding(tmp_path: Path) -> None:
    path = tmp_path / "page_00001.jpg"
    Image.new("RGB", (120, 180), "white").save(path, "JPEG", quality=89)
    output = tmp_path / "legacy.pdf"
    build_pdf([path], output, log=lambda _message: None)
    embedded = PdfReader(output).pages[0]["/Resources"]["/XObject"]["/Im0"]
    assert embedded["/Filter"] == "/DCTDecode"
    assert embedded.get_data() == path.read_bytes()
