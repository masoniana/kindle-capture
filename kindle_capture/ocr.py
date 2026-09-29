from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image

from .models import OcrLine

LANGUAGE_ALIASES = {
    "ja": "ja-JP",
    "en": "en-US",
    "zh": "zh-Hans",
    "ko": "ko-KR",
}


class VisionOcr:
    def __init__(self, language: str = "ja-JP") -> None:
        if sys.platform != "darwin":
            raise RuntimeError("Vision OCRはmacOS上でのみ利用できます。")
        import Foundation  # type: ignore[import-not-found]
        import objc  # type: ignore[import-not-found]
        import Vision  # type: ignore[import-not-found]

        self.Foundation = Foundation
        self.Vision = Vision
        self.objc = objc
        normalized = language.strip()
        self.language = LANGUAGE_ALIASES.get(normalized.lower(), normalized)

    def recognize(self, image_path: Path) -> list[OcrLine]:
        with self.objc.autorelease_pool():
            return self._recognize(image_path)

    def _recognize(self, image_path: Path) -> list[OcrLine]:
        with Image.open(image_path) as image:
            image_width, image_height = image.size

        request = self.Vision.VNRecognizeTextRequest.alloc().init()
        request.setRecognitionLevel_(self.Vision.VNRequestTextRecognitionLevelAccurate)
        supported, language_error = request.supportedRecognitionLanguagesAndReturnError_(None)
        if language_error is not None:
            raise RuntimeError(f"OCR言語一覧を取得できません: {language_error}")
        if self.language not in supported:
            available = ", ".join(str(item) for item in supported)
            raise RuntimeError(f"OCR言語 {self.language} は利用できません。利用可能: {available}")
        request.setRecognitionLanguages_([self.language])
        request.setUsesLanguageCorrection_(True)
        image_url = self.Foundation.NSURL.fileURLWithPath_(str(image_path.resolve()))
        handler = self.Vision.VNImageRequestHandler.alloc().initWithURL_options_(image_url, None)
        success, error = handler.performRequests_error_([request], None)
        if not success:
            raise RuntimeError(str(error) if error is not None else "Vision OCRに失敗しました。")

        lines: list[OcrLine] = []
        for observation in request.results() or []:
            candidates = observation.topCandidates_(1)
            if not candidates:
                continue
            candidate = candidates[0]
            text = str(candidate.string()).strip()
            if not text:
                continue
            rect = observation.boundingBox()
            x = float(rect.origin.x) * image_width
            width = float(rect.size.width) * image_width
            height = float(rect.size.height) * image_height
            # Vision coordinates start at the lower-left; image coordinates start at the upper-left.
            y = (1.0 - float(rect.origin.y) - float(rect.size.height)) * image_height
            lines.append(OcrLine(text, x, y, width, height))
        lines.sort(key=lambda line: (round(line.y / 8.0), line.x))
        return lines
