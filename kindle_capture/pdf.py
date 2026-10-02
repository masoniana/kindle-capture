from __future__ import annotations

import io
import os
import zlib
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image

from .models import OcrLine


@dataclass(frozen=True)
class PdfBuildStats:
    pages: int
    ocr_pages: int
    ocr_lines: int
    searchable: bool


class PdfBuildCancelled(RuntimeError):
    pass


class _PdfWriter:
    def __init__(self, stream: io.BufferedWriter, object_count: int) -> None:
        self.stream = stream
        self.offsets = [0] * (object_count + 1)
        self.object_count = object_count

    def ascii(self, value: str) -> None:
        self.stream.write(value.encode("ascii"))

    def start_object(self, number: int) -> None:
        self.offsets[number] = self.stream.tell()
        self.ascii(f"{number} 0 obj\n")

    def finish(self, root_object: int, info_object: int) -> None:
        xref = self.stream.tell()
        self.ascii(f"xref\n0 {self.object_count + 1}\n")
        self.ascii("0000000000 65535 f \n")
        for number in range(1, self.object_count + 1):
            self.ascii(f"{self.offsets[number]:010d} 00000 n \n")
        self.ascii(
            f"trailer\n<< /Size {self.object_count + 1} /Root {root_object} 0 R "
            f"/Info {info_object} 0 R >>\nstartxref\n{xref}\n%%EOF\n"
        )


def _pdf_image_data(path: Path) -> tuple[bytes, int, int, str]:
    with Image.open(path) as image:
        width, height = image.size
        # Keep old RGB JPEG captures usable without an additional encode.
        if image.format == "JPEG" and image.mode == "RGB":
            return path.read_bytes(), width, height, "DCTDecode"
        # Screenshots are RGB PNGs: preserve every pixel without resizing or
        # quantization. FlateDecode is PDF's lossless zlib compression filter.
        if image.mode in ("RGBA", "LA") or "transparency" in image.info:
            rgba = image.convert("RGBA")
            rgb = Image.new("RGB", image.size, "white")
            rgb.paste(rgba, mask=rgba.getchannel("A"))
        else:
            rgb = image.convert("RGB")
        return zlib.compress(rgb.tobytes()), width, height, "FlateDecode"


def _unicode_hex(text: str) -> str:
    return text.encode("utf-16-be", errors="replace").hex().upper()


def _page_layout(image_width: int, image_height: int) -> tuple[float, float, float, float, float]:
    if image_width >= image_height:
        page_width, page_height = 842.0, 595.0
    else:
        page_width, page_height = 595.0, 842.0
    scale = min(page_width / image_width, page_height / image_height)
    draw_width = image_width * scale
    draw_height = image_height * scale
    return page_width, page_height, scale, (page_width - draw_width) / 2.0, (page_height - draw_height) / 2.0


def _content_stream(
    image_width: int,
    image_height: int,
    ocr_lines: Sequence[OcrLine],
) -> tuple[bytes, float, float]:
    page_width, page_height, scale, draw_x, draw_y = _page_layout(image_width, image_height)
    draw_width = image_width * scale
    draw_height = image_height * scale
    chunks = [f"q {draw_width:.3f} 0 0 {draw_height:.3f} {draw_x:.3f} {draw_y:.3f} cm /Im0 Do Q\n"]
    for line in ocr_lines:
        if not line.text.strip():
            continue
        text_hex = _unicode_hex(line.text)
        text_x = draw_x + line.x * scale
        text_y = draw_y + (image_height - line.y - line.height) * scale
        font_size = max(1.0, line.height * scale)
        character_count = max(1, len(line.text))
        estimated_width = max(1.0, character_count * font_size)
        horizontal_scale = min(1000.0, max(10.0, (line.width * scale / estimated_width) * 100.0))
        chunks.append(
            f"/Span << /ActualText <FEFF{text_hex}> >> BDC\n"
            f"BT /F0 {font_size:.3f} Tf 3 Tr {horizontal_scale:.3f} Tz "
            f"1 0 0 1 {text_x:.3f} {text_y:.3f} Tm <{text_hex}> Tj ET\nEMC\n"
        )
    return "".join(chunks).encode("ascii"), page_width, page_height


def build_pdf(
    image_paths: Sequence[Path],
    output_path: Path,
    ocr: object | None = None,
    language: str = "ja-JP",
    log: Callable[[str], None] = print,
    should_cancel: Callable[[], bool] = lambda: False,
) -> PdfBuildStats:
    if not image_paths:
        raise ValueError("PDFに追加する画像がありません。")

    paths = [Path(path) for path in image_paths]
    use_ocr = ocr is not None
    base_object_count = 2 + len(paths) * 3
    if use_ocr:
        font_object = base_object_count + 1
        cid_font_object = base_object_count + 2
        to_unicode_object = base_object_count + 3
        info_object = base_object_count + 4
        object_count = base_object_count + 4
    else:
        font_object = cid_font_object = to_unicode_object = 0
        info_object = base_object_count + 1
        object_count = base_object_count + 1

    output_path = output_path.resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    partial = output_path.with_name(output_path.name + ".partial")
    partial.unlink(missing_ok=True)
    ocr_pages = 0
    ocr_line_count = 0

    try:
        with partial.open("xb") as stream:
            writer = _PdfWriter(stream, object_count)
            writer.ascii("%PDF-1.4\n")
            stream.write(b"%\xE2\xE3\xCF\xD3\n")

            writer.start_object(1)
            safe_language = "".join(ch for ch in language if ch.isalnum() or ch == "-")
            language_entry = f" /Lang ({safe_language})" if use_ocr and safe_language else ""
            writer.ascii(f"<< /Type /Catalog /Pages 2 0 R{language_entry} >>\nendobj\n")

            page_refs = " ".join(f"{3 + index * 3} 0 R" for index in range(len(paths)))
            writer.start_object(2)
            writer.ascii(f"<< /Type /Pages /Count {len(paths)} /Kids [{page_refs}] >>\nendobj\n")

            for index, image_path in enumerate(paths):
                if should_cancel():
                    raise PdfBuildCancelled("PDF作成を停止しました。キャプチャ画像は残っています。")
                image_data, image_width, image_height, image_filter = _pdf_image_data(image_path)
                ocr_lines: list[OcrLine] = []
                if ocr is not None:
                    try:
                        ocr_lines = list(ocr.recognize(image_path))
                        if ocr_lines:
                            ocr_pages += 1
                            ocr_line_count += len(ocr_lines)
                    except Exception as error:
                        log(f"警告: {index + 1}ページ目のOCRに失敗しました: {error}")

                content, page_width, page_height = _content_stream(
                    image_width, image_height, ocr_lines
                )
                page_object = 3 + index * 3
                image_object = page_object + 1
                content_object = page_object + 2

                writer.start_object(page_object)
                font_resource = f" /Font << /F0 {font_object} 0 R >>" if use_ocr else ""
                writer.ascii(
                    f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {page_width:.2f} {page_height:.2f}] "
                    f"/Resources << /XObject << /Im0 {image_object} 0 R >>{font_resource} >> "
                    f"/Contents {content_object} 0 R >>\nendobj\n"
                )

                writer.start_object(image_object)
                writer.ascii(
                    f"<< /Type /XObject /Subtype /Image /Width {image_width} /Height {image_height} "
                    f"/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /{image_filter} /Length {len(image_data)} >>\nstream\n"
                )
                stream.write(image_data)
                writer.ascii("\nendstream\nendobj\n")

                writer.start_object(content_object)
                writer.ascii(f"<< /Length {len(content)} >>\nstream\n")
                stream.write(content)
                writer.ascii("endstream\nendobj\n")

                interval = 10 if use_ocr else 50
                if (index + 1) % interval == 0 or index + 1 == len(paths):
                    label = "PDF/OCR" if use_ocr else "PDF"
                    log(f"{label}: {index + 1}/{len(paths)} ページを追加")

            if use_ocr:
                writer.start_object(font_object)
                writer.ascii(
                    f"<< /Type /Font /Subtype /Type0 /BaseFont /KindleOCR /Encoding /Identity-H "
                    f"/DescendantFonts [{cid_font_object} 0 R] /ToUnicode {to_unicode_object} 0 R >>\nendobj\n"
                )
                writer.start_object(cid_font_object)
                writer.ascii(
                    "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /KindleOCR "
                    "/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> "
                    "/DW 1000 /CIDToGIDMap /Identity /FontDescriptor << /Type /FontDescriptor "
                    "/FontName /KindleOCR /Flags 4 /FontBBox [0 -250 1000 1000] /ItalicAngle 0 "
                    "/Ascent 880 /Descent -120 /CapHeight 700 /StemV 80 >> >>\nendobj\n"
                )
                cmap = (
                    "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n"
                    "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n"
                    "/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n"
                    "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n"
                    "1 beginbfrange\n<0000> <FFFF> <0000>\nendbfrange\n"
                    "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
                ).encode("ascii")
                writer.start_object(to_unicode_object)
                writer.ascii(f"<< /Length {len(cmap)} >>\nstream\n")
                stream.write(cmap)
                writer.ascii("endstream\nendobj\n")
                log(f"OCR: {ocr_pages}/{len(paths)} ページ、{ocr_line_count} 行の透明テキストを追加")

            writer.start_object(info_object)
            created = datetime.now(timezone.utc).strftime("D:%Y%m%d%H%M%SZ")
            writer.ascii(
                f"<< /Producer (Kindle Capture) /Creator (Kindle Capture) "
                f"/CreationDate ({created}) >>\nendobj\n"
            )
            writer.finish(1, info_object)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(partial, output_path)
    except Exception:
        partial.unlink(missing_ok=True)
        raise

    return PdfBuildStats(len(paths), ocr_pages, ocr_line_count, use_ocr and ocr_pages > 0)
