from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

from PIL import Image

from pipeline import DRIVER_INDEX, PALETTE, TARGET_H, TARGET_W, process_bytes


def main() -> int:
    parser = argparse.ArgumentParser(description="Run the e-ink pipeline on images")
    parser.add_argument("inputs", nargs="+", help="Image files to process")
    parser.add_argument("-o", "--out", default="output", help="Output directory")
    args = parser.parse_args()

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    sheets = []

    for input_path in args.inputs:
        source_path = Path(input_path)
        data = source_path.read_bytes()
        start = time.time()
        result = process_bytes(data)
        elapsed = time.time() - start

        stem = source_path.stem
        png_path = out_dir / f"{stem}.png"
        bin_path = out_dir / f"{stem}.bin"
        png_path.write_bytes(result.processed_png)
        bin_path.write_bytes(result.frame)

        original = Image.open(source_path).convert("RGB")
        original.thumbnail((TARGET_W, TARGET_H))
        processed = Image.open(png_path)
        sheet = Image.new("RGB", (TARGET_W * 2 + 12, TARGET_H + 8), (41, 41, 41))
        sheet.paste(original, (0, 4))
        sheet.paste(processed, (TARGET_W + 12, 4))
        sheet_path = out_dir / f"{stem}-compare.png"
        sheet.save(sheet_path)
        sheets.append(sheet_path)
        print(f"{source_path.name}: {elapsed:.2f}s -> {png_path}, {bin_path} ({len(result.frame)} bytes)")

    if len(sheets) > 1:
        combined = Image.new("RGB", (sheets and max(Image.open(p).width for p in sheets), sum(Image.open(p).height + 6 for p in sheets)), (20, 20, 20))
        y = 0
        for p in sheets:
            img = Image.open(p)
            combined.paste(img, (0, y))
            y += img.height + 6
        combined_path = out_dir / "all-compare.png"
        combined.save(combined_path)
        print(f"combined sheet: {combined_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
