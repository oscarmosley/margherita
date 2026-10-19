#!/usr/bin/env python3
"""Regenerate original pizza artwork. Optional developer dependencies, not used by the Mac build."""
import json
from pathlib import Path
import cairosvg
from PIL import Image

root = Path(__file__).resolve().parents[1]
png = root / "Margherita-icon.png"
cairosvg.svg2png(url=str(root / "artwork/margherita-icon.svg"), write_to=str(png), output_width=1024, output_height=1024)
image = Image.open(png).convert("RGBA")
assets = root / "Margherita/Assets.xcassets"
folder = assets / "AppIcon.appiconset"
folder.mkdir(parents=True, exist_ok=True)
(assets / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
images = []
for points in [16, 32, 128, 256, 512]:
    for scale in [1, 2]:
        name = f"margherita-{points}@{scale}x.png"
        image.resize((points * scale, points * scale), Image.Resampling.LANCZOS).save(folder / name)
        images.append({"idiom": "mac", "size": f"{points}x{points}", "scale": f"{scale}x", "filename": name})
(folder / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
print("Generated original Margherita pizza icon assets.")
