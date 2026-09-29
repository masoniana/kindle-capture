from __future__ import annotations

import asyncio
import io
import sys
from pathlib import Path

from PIL import Image

from .models import OcrLine
from .ocr import LANGUAGE_ALIASES


class WindowsOcr:
    def __init__(self, language: str = "ja-JP") -> None:
        if sys.platform != "win32":
            raise RuntimeError("Windows OCRはWindows上でのみ利用できます。")
        from winrt.windows.globalization import Language
        from winrt.windows.media.ocr import OcrEngine

        normalized = language.strip()
        self.language = LANGUAGE_ALIASES.get(normalized.lower(), normalized)
        self._language = Language(self.language)
        if not OcrEngine.is_language_supported(self._language):
            available = ", ".join(item.language_tag for item in OcrEngine.available_recognizer_languages)
            raise RuntimeError(
                f"OCR言語 {self.language} がWindowsにありません。利用可能: {available}"
            )
        self._engine = OcrEngine.try_create_from_language(self._language)
        if self._engine is None:
            raise RuntimeError(f"Windows OCRを初期化できません: {self.language}")
        self._maximum_dimension = int(OcrEngine.max_image_dimension)

    def recognize(self, image_path: Path) -> list[OcrLine]:
        with Image.open(image_path) as image:
            source_width, source_height = image.size
            ocr_width, ocr_height = source_width, source_height
            if max(source_width, source_height) > self._maximum_dimension:
                scale = self._maximum_dimension / max(source_width, source_height)
                ocr_width = max(1, round(source_width * scale))
                ocr_height = max(1, round(source_height * scale))
                resized = image.convert("RGB").resize((ocr_width, ocr_height), Image.Resampling.LANCZOS)
                buffer = io.BytesIO()
                resized.save(buffer, "PNG")
                image_bytes = buffer.getvalue()
            else:
                image_bytes = image_path.read_bytes()
        scale_x = source_width / ocr_width
        scale_y = source_height / ocr_height
        return asyncio.run(self._recognize_bytes(image_bytes, scale_x, scale_y))

    async def _recognize_bytes(
        self,
        image_bytes: bytes,
        scale_x: float,
        scale_y: float,
    ) -> list[OcrLine]:
        from winrt.windows.graphics.imaging import BitmapDecoder
        from winrt.windows.storage.streams import DataWriter, InMemoryRandomAccessStream

        stream = InMemoryRandomAccessStream()
        writer = DataWriter(stream)
        bitmap = None
        try:
            writer.write_bytes(image_bytes)
            await writer.store_async()
            writer.detach_stream()
            writer.close()
            stream.seek(0)
            decoder = await BitmapDecoder.create_async(stream)
            bitmap = await decoder.get_software_bitmap_async()
            result = await self._engine.recognize_async(bitmap)
            lines: list[OcrLine] = []
            for line in result.lines:
                words = list(line.words)
                if not words or not line.text.strip():
                    continue
                left = min(float(word.bounding_rect.x) for word in words)
                top = min(float(word.bounding_rect.y) for word in words)
                right = max(float(word.bounding_rect.x + word.bounding_rect.width) for word in words)
                bottom = max(float(word.bounding_rect.y + word.bounding_rect.height) for word in words)
                lines.append(
                    OcrLine(
                        line.text.strip(),
                        left * scale_x,
                        top * scale_y,
                        (right - left) * scale_x,
                        (bottom - top) * scale_y,
                    )
                )
            return lines
        finally:
            if bitmap is not None:
                bitmap.close()
            stream.close()
