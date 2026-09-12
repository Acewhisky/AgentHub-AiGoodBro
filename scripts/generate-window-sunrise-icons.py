#!/usr/bin/env python3
"""Build the 0912v1 open-window sunrise icon family.

The source of truth is ``design/icons-0912v1/svg/app-icon-master.svg``.  The
master contains one geometry and CSS custom properties for its palette.  This
script materializes five self-contained SVGs, rasterizes those SVGs with
ImageMagick's built-in SVG renderer, and deterministically packages a complete
ICNS container for every palette.  macOS ``iconutil`` then round-trips each
ICNS as the system-recognition check.

The script deliberately does not touch ``Resources/AiGoodBro-icon.png``.  That
PNG is a separate runtime brand asset; the app icon resources are the five
icns files handled here.

Usage:
    python3 scripts/generate-window-sunrise-icons.py
    python3 scripts/generate-window-sunrise-icons.py --verify-only
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
ICON_ROOT = ROOT / "design" / "icons-0912v1"
SVG_ROOT = ICON_ROOT / "svg"
MASTER = SVG_ROOT / "app-icon-master.svg"
ICONSETS_ROOT = ICON_ROOT / "iconsets"
RESOURCES_ROOT = ROOT / "Resources"
SRGB_PROFILE = Path(
    os.environ.get("SRGB_PROFILE", "/System/Library/ColorSync/Profiles/sRGB Profile.icc")
)

PALETTES: tuple[tuple[str, str, str, dict[str, str]], ...] = (
    (
        "01-warm-white",
        "暖白",
        "AiGoodBro-warm-white.icns",
        {
            "shadow": "#1a1a1a",
            "tile-top": "#f7f4ed",
            "tile-edge": "#ffffff",
            "tile-edge-dark": "#bdb4a6",
            "shutter-top": "#fffdf7",
            "shutter-bottom": "#ede8dc",
            "shutter-side": "#c6bbaa",
            "shutter-shadow": "#51483e",
            "sky-top": "#55b7f4",
            "sky-bottom": "#f9d8b2",
            "sun-top": "#ff795b",
            "sill-top": "#fff0d5",
            "sill-bottom": "#f6cca1",
            "window-edge": "#ffffff",
        },
    ),
    (
        "02-deep-plum",
        "深梅紫",
        "AiGoodBro-02-deep-plum.icns",
        {
            "shadow": "#17121b",
            "tile-top": "#67516f",
            "tile-edge": "#c8b8cb",
            "tile-edge-dark": "#24192b",
            "shutter-top": "#8b7490",
            "shutter-bottom": "#59435f",
            "shutter-side": "#3b2b43",
            "shutter-shadow": "#1e1524",
            "sky-top": "#55b7f4",
            "sky-bottom": "#f9d8b2",
            "sun-top": "#ff795b",
            "sill-top": "#fff0d5",
            "sill-bottom": "#f6cca1",
            "window-edge": "#fff9ff",
        },
    ),
    (
        "03-sage-green",
        "鼠尾草绿",
        "AiGoodBro-03-sage-green.icns",
        {
            "shadow": "#1d2b25",
            "tile-top": "#a6bdaf",
            "tile-edge": "#e7f2eb",
            "tile-edge-dark": "#4e6d5e",
            "shutter-top": "#d3e2d9",
            "shutter-bottom": "#a7c0b1",
            "shutter-side": "#789987",
            "shutter-shadow": "#334e40",
            "sky-top": "#55b7f4",
            "sky-bottom": "#f9d8b2",
            "sun-top": "#ff795b",
            "sill-top": "#fff0d5",
            "sill-bottom": "#f6cca1",
            "window-edge": "#fbfffc",
        },
    ),
    (
        "04-graphite",
        "石墨灰",
        "AiGoodBro-04-graphite.icns",
        {
            "shadow": "#10151a",
            "tile-top": "#4d5965",
            "tile-edge": "#aebbc7",
            "tile-edge-dark": "#18212a",
            "shutter-top": "#84909d",
            "shutter-bottom": "#56626e",
            "shutter-side": "#303b46",
            "shutter-shadow": "#101820",
            "sky-top": "#55b7f4",
            "sky-bottom": "#f9d8b2",
            "sun-top": "#ff795b",
            "sill-top": "#fff0d5",
            "sill-bottom": "#f6cca1",
            "window-edge": "#f8fbff",
        },
    ),
    (
        "05-champagne",
        "浅香槟",
        "AiGoodBro-05-champagne.icns",
        {
            "shadow": "#3a2a1a",
            "tile-top": "#e7d4b5",
            "tile-edge": "#fff4dc",
            "tile-edge-dark": "#a88a63",
            "shutter-top": "#fff3dd",
            "shutter-bottom": "#e6cba5",
            "shutter-side": "#b5956d",
            "shutter-shadow": "#60462b",
            "sky-top": "#55b7f4",
            "sky-bottom": "#f9d8b2",
            "sun-top": "#ff795b",
            "sill-top": "#fff0d5",
            "sill-bottom": "#f6cca1",
            "window-edge": "#fffaf0",
        },
    ),
)

PNG_NAMES = {key: f"{key}-512.png" for key, _, _, _ in PALETTES}
SVG_NAMES = {key: f"{key}.svg" for key, _, _, _ in PALETTES}

ICONSET_ENTRIES: tuple[tuple[str, int], ...] = (
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
)
ICONSET_NAMES = {name for name, _ in ICONSET_ENTRIES}

# Modern ICNS files may carry PNG payloads directly.  The paired Retina chunk
# types are intentionally explicit so iconutil reconstructs all ten canonical
# iconset filenames on round-trip.
ICNS_CHUNKS: tuple[tuple[str, str], ...] = (
    ("icp4", "icon_16x16.png"),
    ("ic11", "icon_16x16@2x.png"),
    ("icp5", "icon_32x32.png"),
    ("ic12", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic13", "icon_128x128@2x.png"),
    ("ic08", "icon_256x256.png"),
    ("ic14", "icon_256x256@2x.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
)

COLOR_ATTRS = {
    "fill",
    "stroke",
    "color",
    "stop-color",
    "flood-color",
    "lighting-color",
    "style",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--verify-only",
        action="store_true",
        help="validate existing SVG, PNG, iconset, icns, and resource mappings",
    )
    parser.add_argument(
        "--magick",
        default=os.environ.get("MAGICK", "magick"),
        help="ImageMagick executable (default: MAGICK environment or magick)",
    )
    parser.add_argument(
        "--iconutil",
        default=os.environ.get("ICONUTIL", "/usr/bin/iconutil"),
        help="macOS iconutil executable (default: /usr/bin/iconutil)",
    )
    return parser.parse_args()


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def geometry_tree(element: ET.Element) -> object:
    """Return XML content with palette declarations removed.

    Paths, coordinates, clip paths, and opacity values remain in the tree;
    color-bearing attributes and CSS text do not.  The resulting digest is a
    useful guard against accidentally changing one palette's silhouette.
    """

    tag = local_name(element.tag)
    if tag in {"style", "title", "desc"}:
        return None
    attrs: list[tuple[str, str]] = []
    for raw_key, value in sorted(element.attrib.items()):
        key = local_name(raw_key)
        if key in COLOR_ATTRS:
            continue
        attrs.append((key, value))
    children = [tree for child in list(element) if (tree := geometry_tree(child)) is not None]
    return (tag, tuple(attrs), tuple(children))


def geometry_signature(svg_path: Path) -> str:
    root = ET.parse(svg_path).getroot()
    tree = geometry_tree(root)
    encoded = json.dumps(tree, ensure_ascii=True, separators=(",", ":"))
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def read_svg(path: Path) -> str:
    if not path.is_file():
        raise RuntimeError(f"missing SVG: {path}")
    text = path.read_text(encoding="utf-8")
    root = ET.fromstring(text)
    if local_name(root.tag) != "svg":
        raise RuntimeError(f"not an SVG root: {path}")
    if root.get("viewBox") != "0 0 512 512":
        raise RuntimeError(f"unexpected viewBox in {path}: {root.get('viewBox')!r}")
    return text


def materialize_svg(master_text: str, palette: dict[str, str]) -> str:
    rendered = master_text
    for name, color in palette.items():
        rendered = rendered.replace(f"var(--{name})", color)
    if re.search(r"var\(--[a-z0-9-]+\)", rendered):
        raise RuntimeError("unresolved CSS palette token in generated SVG")
    # Ensure every output remains a standalone SVG, rather than depending on
    # an adjacent stylesheet or an external image.
    if "href=\"http" in rendered or "xlink:href=\"http" in rendered:
        raise RuntimeError("external SVG reference is not allowed")
    return rendered


def png_info(path: Path) -> tuple[int, int, int]:
    data = path.read_bytes()
    if len(data) < 33 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise RuntimeError(f"not a PNG: {path}")
    width = int.from_bytes(data[16:20], "big")
    height = int.from_bytes(data[20:24], "big")
    bit_depth = data[24]
    color_type = data[25]
    if bit_depth != 8 or color_type != 6:
        raise RuntimeError(
            f"PNG must be 8-bit RGBA (got bit depth {bit_depth}, color type {color_type}): {path}"
        )
    return width, height, color_type


def run(command: list[str]) -> None:
    try:
        subprocess.run(command, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or error.stdout or "").strip()
        suffix = f": {detail}" if detail else ""
        raise RuntimeError(f"command failed ({error.returncode}): {' '.join(command)}{suffix}") from error


def render_png(magick: str, svg_path: Path, output_path: Path, size: int) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    run(
        [
            magick,
            "-background",
            "none",
            "-density",
            "256",
            str(svg_path),
            "-resize",
            f"{size}x{size}!",
            "-alpha",
            "on",
            "-depth",
            "8",
            "-define",
            "png:color-type=6",
            "-profile",
            str(SRGB_PROFILE),
            "-strip",
            f"PNG32:{output_path}",
        ]
    )
    width, height, color_type = png_info(output_path)
    if (width, height, color_type) != (size, size, 6):
        raise RuntimeError(f"unexpected raster output for {svg_path}: {width}x{height}, type {color_type}")


def resize_png(magick: str, source_path: Path, output_path: Path, size: int) -> None:
    """Downsample one SVG raster for an iconset entry.

    Rendering each SVG once at 1024px and deriving the ten iconset entries
    keeps the build fast while retaining one exact geometry/raster pipeline for
    every scale.
    """

    output_path.parent.mkdir(parents=True, exist_ok=True)
    run(
        [
            magick,
            str(source_path),
            "-resize",
            f"{size}x{size}!",
            "-alpha",
            "on",
            "-depth",
            "8",
            "-define",
            "png:color-type=6",
            "-profile",
            str(SRGB_PROFILE),
            "-strip",
            f"PNG32:{output_path}",
        ]
    )
    width, height, color_type = png_info(output_path)
    if (width, height, color_type) != (size, size, 6):
        raise RuntimeError(f"unexpected resized output: {output_path} ({width}x{height}, type {color_type})")


def package_icns(iconset: Path, output_path: Path) -> None:
    """Write a deterministic PNG-backed ICNS container.

    Some macOS/CommandLineTools combinations can decode ICNS with iconutil but
    reject even an immediately unpacked, canonical iconset when repacking it.
    Writing the simple documented chunk container avoids that host-specific
    encoder failure; validate_iconset still requires the system decoder to
    recognize and recover every entry.
    """

    output_path.parent.mkdir(parents=True, exist_ok=True)
    chunks: list[bytes] = []
    for chunk_type, filename in ICNS_CHUNKS:
        payload = (iconset / filename).read_bytes()
        chunks.append(chunk_type.encode("ascii") + struct.pack(">I", len(payload) + 8) + payload)
    body = b"".join(chunks)
    output_path.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
    if not output_path.is_file() or output_path.stat().st_size == 0:
        raise RuntimeError(f"ICNS packer did not create {output_path}")


def validate_iconset(iconutil: str, icns_path: Path, expected_dir: Path) -> None:
    if not icns_path.is_file() or icns_path.stat().st_size == 0:
        raise RuntimeError(f"missing icns: {icns_path}")
    with tempfile.TemporaryDirectory(prefix="aigoodbro-iconset-check-") as tmp:
        unpacked = Path(tmp) / "unpacked.iconset"
        run([iconutil, "-c", "iconset", str(icns_path), "-o", str(unpacked)])
        for name, size in ICONSET_ENTRIES:
            path = unpacked / name
            if not path.is_file():
                raise RuntimeError(f"{icns_path.name} is missing {name}")
            if png_info(path)[:2] != (size, size):
                raise RuntimeError(f"{icns_path.name}/{name} has wrong dimensions")
    # The expected directory is checked separately so a stale or hand-edited
    # iconset cannot hide a failed icns round-trip.  Exact membership matters:
    # an older AppIcon.iconset used to retain nonstandard 64/1024 entries.
    actual_names = {path.name for path in expected_dir.glob("*.png")}
    if actual_names != ICONSET_NAMES:
        raise RuntimeError(
            f"iconset has stale or missing PNG entries: {expected_dir} ({sorted(actual_names)})"
        )
    for name, size in ICONSET_ENTRIES:
        path = expected_dir / name
        if not path.is_file() or png_info(path)[:2] != (size, size):
            raise RuntimeError(f"missing or invalid iconset output: {path}")


def destination_iconset(key: str) -> Path:
    if key == "01-warm-white":
        # Keep the pre-existing canonical name for compatibility with design
        # tooling that already previews the default iconset.
        return ICON_ROOT / "AppIcon.iconset"
    return ICONSETS_ROOT / f"{key}.iconset"


def resource_name_for(key: str, icns_name: str) -> str:
    if key == "01-warm-white":
        return "AiGoodBro.icns"
    return icns_name


def verify_existing(magick: str, iconutil: str) -> None:
    master_text = read_svg(MASTER)
    master_signature = geometry_signature(MASTER)
    signatures = {"master": master_signature}
    for key, _, icns_name, palette in PALETTES:
        svg = SVG_ROOT / SVG_NAMES[key]
        text = read_svg(svg)
        if re.search(r"var\(--[a-z0-9-]+\)", text):
            raise RuntimeError(f"palette SVG still has unresolved CSS variables: {svg}")
        signatures[key] = geometry_signature(svg)
        if signatures[key] != master_signature:
            raise RuntimeError(f"geometry differs from master: {svg}")
        for color in palette.values():
            if color not in text:
                raise RuntimeError(f"palette color {color} is absent from {svg}")
        png = ICON_ROOT / PNG_NAMES[key]
        if png_info(png)[:2] != (512, 512):
            raise RuntimeError(f"PNG is not 512x512: {png}")
        iconset = destination_iconset(key)
        icns = ICON_ROOT / icns_name
        validate_iconset(iconutil, icns, iconset)
        resource = RESOURCES_ROOT / resource_name_for(key, icns_name)
        if resource.read_bytes() != icns.read_bytes():
            raise RuntimeError(f"resource mapping differs: {resource} != {icns}")
    if len(set(signatures.values())) != 1:
        raise RuntimeError("not all SVG geometries share one signature")
    # Parsing master_text above is intentional: it also catches XML edits even
    # when a generated variant happens to be unchanged.
    if "window-clip" not in master_text:
        raise RuntimeError("master lost its window clip path")
    print("verified 5 SVG palettes, 5 RGBA PNGs, 5 iconsets, 5 icns mappings")
    print(f"geometry-sha256={master_signature}")


def build(magick: str, iconutil: str) -> None:
    if not SRGB_PROFILE.is_file():
        raise RuntimeError(f"macOS sRGB profile is required for raster export: {SRGB_PROFILE}")
    master_text = read_svg(MASTER)
    master_signature = geometry_signature(MASTER)
    ICON_ROOT.mkdir(parents=True, exist_ok=True)
    SVG_ROOT.mkdir(parents=True, exist_ok=True)
    ICONSETS_ROOT.mkdir(parents=True, exist_ok=True)
    RESOURCES_ROOT.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="aigoodbro-window-icons-") as tmp:
        staging = Path(tmp)
        staged_svgs = staging / "svg"
        staged_pngs = staging / "png"
        staged_iconsets = staging / "iconsets"
        staged_icns = staging / "icns"

        for key, _, icns_name, palette in PALETTES:
            concrete = materialize_svg(master_text, palette)
            staged_svg = staged_svgs / SVG_NAMES[key]
            staged_svg.parent.mkdir(parents=True, exist_ok=True)
            with staged_svg.open("w", encoding="utf-8", newline="\n") as handle:
                handle.write(concrete)
            read_svg(staged_svg)
            if geometry_signature(staged_svg) != master_signature:
                raise RuntimeError(f"generated geometry differs from master: {staged_svg}")

            # One high-resolution render is the source for the canonical PNG
            # and every iconset size.  This is deterministic and avoids
            # slight geometry differences between separate low-res renders.
            staged_raster = staging / "raster" / f"{key}-1024.png"
            render_png(magick, staged_svg, staged_raster, 1024)

            staged_png = staged_pngs / PNG_NAMES[key]
            resize_png(magick, staged_raster, staged_png, 512)

            staged_iconset = staged_iconsets / f"{key}.iconset"
            staged_iconset.mkdir(parents=True, exist_ok=True)
            for name, size in ICONSET_ENTRIES:
                resize_png(magick, staged_raster, staged_iconset / name, size)

            staged_icns_path = staged_icns / icns_name
            package_icns(staged_iconset, staged_icns_path)
            validate_iconset(iconutil, staged_icns_path, staged_iconset)

        # All rasterization and iconutil work succeeded in the private staging
        # directory.  Only now replace the explicitly scoped icon artifacts.
        for key, _, icns_name, _ in PALETTES:
            shutil.copyfile(staged_svgs / SVG_NAMES[key], SVG_ROOT / SVG_NAMES[key])
            shutil.copyfile(staged_pngs / PNG_NAMES[key], ICON_ROOT / PNG_NAMES[key])
            target_iconset = destination_iconset(key)
            target_iconset.mkdir(parents=True, exist_ok=True)
            for stale_png in target_iconset.glob("*.png"):
                stale_png.unlink()
            for name, _ in ICONSET_ENTRIES:
                shutil.copyfile(staged_iconsets / f"{key}.iconset" / name, target_iconset / name)
            design_icns = ICON_ROOT / icns_name
            resource_icns = RESOURCES_ROOT / resource_name_for(key, icns_name)
            shutil.copyfile(staged_icns / icns_name, design_icns)
            shutil.copyfile(staged_icns / icns_name, resource_icns)

    verify_existing(magick, iconutil)
    print("generated 5 standalone SVGs, 5 RGBA 512px PNGs, 5 complete iconsets, and 5 icns files")


def main() -> int:
    args = parse_args()
    if args.verify_only:
        verify_existing(args.magick, args.iconutil)
    else:
        build(args.magick, args.iconutil)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
