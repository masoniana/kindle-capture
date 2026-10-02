from __future__ import annotations

import struct
import threading
import zlib
from pathlib import Path

import pytest
from PIL import Image, ImageDraw
from pypdf import PdfReader

from kindle_capture import pdf
from kindle_capture.models import OcrLine
from kindle_capture.pdf import PdfBuildCancelled, build_pdf


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


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)


def test_png_idat_reused_with_all_five_filters_and_multiple_chunks(tmp_path: Path, monkeypatch) -> None:
    width, height = 37, 10
    rows = [bytes((index * 53 + row * 29) % 256 for index in range(width * 3)) for row in range(height)]
    filtered = bytearray()
    for row_number, row in enumerate(rows):
        kind = row_number % 5
        filtered.append(kind)
        previous = rows[row_number - 1] if row_number else bytes(width * 3)
        for index, value in enumerate(row):
            left = row[index - 3] if index >= 3 else 0
            above = previous[index]
            upper_left = previous[index - 3] if index >= 3 else 0
            if kind == 4:
                estimate = left + above - upper_left
                distances = [abs(estimate - candidate) for candidate in (left, above, upper_left)]
                predictor = (left, above, upper_left)[distances.index(min(distances))]
            else:
                predictor = (0, left, above, (left + above) // 2)[kind]
            filtered.append((value - predictor) % 256)
    compressed = zlib.compress(filtered)
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    path = tmp_path / "page_00001.png"
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", header)
                     + b"".join(png_chunk(b"IDAT", compressed[index:index + 7]) for index in range(0, len(compressed), 7))
                     + png_chunk(b"IEND", b""))
    with Image.open(path) as original:
        assert original.tobytes() == b"".join(rows)

    def no_recompression(*_args, **_kwargs):
        raise AssertionError("RGB PNG must not be recompressed")

    monkeypatch.setattr(pdf.zlib, "compress", no_recompression)
    output = tmp_path / "book.pdf"
    build_pdf([path], output, log=lambda _message: None)
    embedded = PdfReader(output).pages[0]["/Resources"]["/XObject"]["/Im0"]
    assert embedded["/DecodeParms"]["/Predictor"] == 15
    assert embedded["/DecodeParms"]["/Columns"] == width
    assert embedded._data == compressed
    assert embedded.get_data() == b"".join(rows)


def test_interlaced_png_uses_lossless_fallback(tmp_path: Path) -> None:
    path = tmp_path / "page_00001.png"
    header = struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 1)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", header)
                     + png_chunk(b"IDAT", zlib.compress(b"\x00\x12\x34\x56")) + png_chunk(b"IEND", b""))
    output = tmp_path / "book.pdf"
    build_pdf([path], output, log=lambda _message: None)
    embedded = PdfReader(output).pages[0]["/Resources"]["/XObject"]["/Im0"]
    assert "/DecodeParms" not in embedded
    assert embedded.get_data() == b"\x12\x34\x56"


def test_rgb_png_transparency_is_composited_in_fallback(tmp_path: Path) -> None:
    path = tmp_path / "page_00001.png"
    Image.new("RGB", (2, 2), "red").save(path, "PNG", transparency=(255, 0, 0))
    output = tmp_path / "book.pdf"
    build_pdf([path], output, log=lambda _message: None)
    embedded = PdfReader(output).pages[0]["/Resources"]["/XObject"]["/Im0"]
    assert "/DecodeParms" not in embedded
    assert embedded.get_data() == b"\xff" * 12


@pytest.mark.parametrize("corruption", ["crc", "truncated"])
def test_invalid_png_aborts_pdf_and_removes_partial(tmp_path: Path, corruption: str) -> None:
    path = tmp_path / "page_00001.png"
    Image.new("RGB", (20, 20), "white").save(path, "PNG")
    data = bytearray(path.read_bytes())
    if corruption == "crc":
        data[data.index(b"IDAT") + 4] ^= 1
    else:
        data = data[:-12]  # Remove IEND, not the valid pixel data.
    path.write_bytes(data)
    output = tmp_path / "book.pdf"
    with pytest.raises(ValueError, match="PNG"):
        build_pdf([path], output, log=lambda _message: None)
    assert path.exists()
    assert not output.exists()
    assert not output.with_name("book.pdf.partial").exists()


def test_next_image_preparation_overlaps_ocr_without_moving_ocr_thread(tmp_path: Path, monkeypatch) -> None:
    paths = [tmp_path / f"page_{number:05d}.png" for number in range(1, 4)]
    for path in paths:
        Image.new("RGB", (20, 20), "white").save(path, "PNG")
    next_prepared = threading.Event()
    prepared = []
    original = pdf._pdf_image_data
    main_thread = threading.get_ident()

    def prepare(path: Path):
        prepared.append(path)
        if path == paths[1]:
            next_prepared.set()
        return original(path)

    class ThreadCheckedOcr(FakeOcr):
        def recognize(self, path: Path) -> list[OcrLine]:
            assert threading.get_ident() == main_thread
            if path == paths[0]:
                assert next_prepared.wait(3)
                assert paths[2] not in prepared  # Lookahead is bounded to one page.
            return super().recognize(path)

    monkeypatch.setattr(pdf, "_pdf_image_data", prepare)
    stats = build_pdf(paths, tmp_path / "book.pdf", ThreadCheckedOcr(), log=lambda _message: None)
    assert stats.ocr_pages == 3
    assert prepared == paths


def test_pdf_cancellation_preserves_pngs_and_existing_pdf(tmp_path: Path) -> None:
    path = tmp_path / "page_00001.png"
    Image.new("RGB", (20, 20), "white").save(path, "PNG")
    output = tmp_path / "book.pdf"
    original_bytes = b"keep previous PDF"
    output.write_bytes(original_bytes)
    cancelled = threading.Event()

    class CancellingOcr(FakeOcr):
        def recognize(self, path: Path) -> list[OcrLine]:
            cancelled.set()
            return super().recognize(path)

    with pytest.raises(PdfBuildCancelled):
        build_pdf([path, path], output, CancellingOcr(), log=lambda _message: None, should_cancel=cancelled.is_set)
    assert path.exists()
    assert output.read_bytes() == original_bytes
    assert not output.with_name("book.pdf.partial").exists()
