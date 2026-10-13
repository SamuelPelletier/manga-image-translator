import os
import numpy as np
from PIL import Image
from abc import abstractmethod
from .rendering.gimp_render import gimp_render

from .utils import Context


class FormatNotSupportedException(Exception):
    def __init__(self, fmt: str):
        super().__init__(f'Format {fmt} is not supported.')

OUTPUT_FORMATS = {}
def register_format(format_cls):
    for fmt in format_cls.SUPPORTED_FORMATS:
        if fmt in OUTPUT_FORMATS:
            raise Exception(f'Tried to register multiple ExportFormats for "{fmt}"')
        OUTPUT_FORMATS[fmt] = format_cls()
    return format_cls

class ExportFormat():
    SUPPORTED_FORMATS = []

    # Subclasses will be auto registered
    def __init_subclass__(cls, **kwargs):
        super().__init_subclass__(**kwargs)
        register_format(cls)

    def save(self, result: Image.Image, dest: str, ctx: Context):
        self._save(result, dest, ctx)

    @abstractmethod
    def _save(self, result: Image.Image, dest: str, ctx: Context):
        pass

def save_result(result: Image.Image, dest: str, ctx: Context):
    _, ext = os.path.splitext(dest)
    ext = ext[1:]
    if ext not in OUTPUT_FORMATS:
        raise FormatNotSupportedException(ext)

    format_handler: ExportFormat = OUTPUT_FORMATS[ext]
    format_handler.save(result, dest, ctx)


def is_grayscale(image: Image.Image, tolerance: int = 8) -> bool:
    """True when the RGB channels are (almost) identical everywhere."""
    pixels = np.asarray(image.convert('RGB'), dtype=np.int16)
    return bool(np.abs(pixels[..., 0] - pixels[..., 1]).max() <= tolerance
                and np.abs(pixels[..., 1] - pixels[..., 2]).max() <= tolerance)

# -- Format Implementations

class ImageFormat(ExportFormat):
    SUPPORTED_FORMATS = ['png', 'webp']

    def _save(self, result: Image.Image, dest: str, ctx: Context):
        result.save(dest)

class JPGFormat(ExportFormat):
    SUPPORTED_FORMATS = ['jpg', 'jpeg']

    def _save(self, result: Image.Image, dest: str, ctx: Context):
        result = result.convert('RGB')
        # Black and white pages (most mangas) are saved as grayscale: a third of the size
        if is_grayscale(result):
            result = result.convert('L')
        # Certain versions of PIL only support JPEG but not JPG
        result.save(dest, quality=ctx.save_quality, format='JPEG', optimize=True)

class GIMPFormat(ExportFormat):
    SUPPORTED_FORMATS = ['xcf', 'psd', 'pdf']

    def _save(self, result: Image.Image, dest: str, ctx: Context):
        gimp_render(dest, ctx)

# class KraFormat(ExportFormat):
#     SUPPORTED_FORMATS = ['kra']

#     def _save(self, result: Image.Image, dest: str, ctx: Context):
#         ...

# class SvgFormat(TranslationExportFormat):
#     SUPPORTED_FORMATS = ['svg']

