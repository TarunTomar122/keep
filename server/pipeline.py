from __future__ import annotations

import io
from dataclasses import dataclass

import numpy as np
from PIL import Image, ImageEnhance, ImageFilter, ImageOps

TARGET_W = 600
TARGET_H = 400

PALETTE = {
    "black": (24, 24, 24),
    "white": (240, 236, 227),
    "green": (58, 120, 64),
    "blue": (46, 76, 156),
    "red": (198, 50, 44),
    "yellow": (230, 183, 58),
}

DRIVER_INDEX = {"black": 0, "white": 1, "green": 2, "blue": 3, "red": 4, "yellow": 5}

GAMMA = 0.88
SATURATION = 1.3
SHARPEN_PERCENT = 90


@dataclass
class ProcessedMoment:
    processed_png: bytes
    frame: bytes
    width: int
    height: int


def process_bytes(data: bytes) -> ProcessedMoment:
    source = _prepare(data)
    idx = _dither_serpentine(source)
    png = _encode_png(idx)
    return ProcessedMoment(
        processed_png=png,
        frame=_pack_raw(idx),
        width=source.width,
        height=source.height,
    )


def _prepare(data: bytes) -> Image.Image:
    decoded = Image.open(io.BytesIO(data))
    decoded = ImageOps.exif_transpose(decoded).convert("RGB")
    cropped = _center_crop(decoded, TARGET_W / TARGET_H)
    resized = cropped.resize((TARGET_W, TARGET_H), Image.LANCZOS)

    gamma_lut = [round(255.0 * ((i / 255.0) ** GAMMA)) for i in range(256)]
    lifted = resized.point(gamma_lut * 3)
    saturated = ImageEnhance.Color(lifted).enhance(SATURATION)
    sharpened = saturated.filter(
        ImageFilter.UnsharpMask(radius=2, percent=SHARPEN_PERCENT, threshold=2)
    )
    return sharpened


def _center_crop(image: Image.Image, target_ratio: float) -> Image.Image:
    width, height = image.size
    ratio = width / height
    if ratio > target_ratio:
        new_w = round(height * target_ratio)
        left = (width - new_w) // 2
        box = (left, 0, left + new_w, height)
    else:
        new_h = round(width / target_ratio)
        top = (height - new_h) // 2
        box = (0, top, width, top + new_h)
    return image.crop(box)


def _dither_serpentine(image: Image.Image) -> np.ndarray:
    names = list(DRIVER_INDEX.keys())
    pal = np.array([PALETTE[name] for name in names], dtype=np.float64)
    buf = np.asarray(image, dtype=np.float64)
    h, w, _ = buf.shape
    out = np.zeros((h, w), dtype=np.uint8)

    pr = pal[:, 0].tolist()
    pg = pal[:, 1].tolist()
    pb = pal[:, 2].tolist()
    n_colors = len(names)

    for y in range(h):
        row = buf[y]
        reverse = y % 2 == 1
        xs = range(w - 1, -1, -1) if reverse else range(w)
        step = -1 if reverse else 1
        for x in xs:
            r, g, b = row[x]
            best = 0
            best_d = 1e12
            for i in range(n_colors):
                dr = r - pr[i]
                dg = g - pg[i]
                db = b - pb[i]
                d = dr * dr + dg * dg + db * db
                if d < best_d:
                    best_d = d
                    best = i
            out[y, x] = best
            er = r - pr[best]
            eg = g - pg[best]
            eb = b - pb[best]
            xn = x + step
            if 0 <= xn < w:
                row[xn, 0] += er * (7.0 / 16.0)
                row[xn, 1] += eg * (7.0 / 16.0)
                row[xn, 2] += eb * (7.0 / 16.0)
            yb = y + 1
            if yb < h:
                if x > 0:
                    buf[yb, x - 1, 0] += er * (3.0 / 16.0)
                    buf[yb, x - 1, 1] += eg * (3.0 / 16.0)
                    buf[yb, x - 1, 2] += eb * (3.0 / 16.0)
                buf[yb, x, 0] += er * (5.0 / 16.0)
                buf[yb, x, 1] += eg * (5.0 / 16.0)
                buf[yb, x, 2] += eb * (5.0 / 16.0)
                if xn >= 0 and xn < w:
                    buf[yb, xn, 0] += er * (1.0 / 16.0)
                    buf[yb, xn, 1] += eg * (1.0 / 16.0)
                    buf[yb, xn, 2] += eb * (1.0 / 16.0)
    return out


def _encode_png(idx: np.ndarray) -> bytes:
    names = list(DRIVER_INDEX.keys())
    pal = [PALETTE[name] for name in names]
    flat = np.take(pal, idx, axis=0).astype(np.uint8)
    image = Image.fromarray(flat, mode="RGB")
    stream = io.BytesIO()
    image.save(stream, format="PNG", optimize=True)
    return stream.getvalue()


def _pack_raw(idx: np.ndarray) -> bytes:
    packed = (idx[:, 0::2].astype(np.uint8) << 4) | idx[:, 1::2].astype(np.uint8)
    return packed.tobytes()
