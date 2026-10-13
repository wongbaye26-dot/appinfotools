#!/usr/bin/env python3
"""从一张源图生成各平台所需的应用图标。

为什么是一个脚本而不是手工跑几条命令：图标有 4 处、10 个尺寸，而且**格式各不相同**
（macOS 要 PNG、Windows 要 ICO、应用内和 README 各要一张 PNG）。手工做一次之后
没人记得住哪些文件要更新，下次换图标就会漏。

只依赖 macOS 自带的 `sips`（不引入 Pillow / ImageMagick）：

- 缩放与格式转换交给 `sips`；
- ICO 由本脚本自己组装 —— `sips` 不产出 ICO，而 ICO 的格式足够简单，
  自己拼比引入一个图像库更可控。

用法：
    tool/generate_icons.py <源图>
    tool/generate_icons.py <源图> --dry-run     # 只打印会改哪些文件
"""

from __future__ import annotations

import argparse
import os
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# macOS AppIcon.appiconset 需要的文件名 → 像素尺寸。
# 与 macos/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json 一一对应。
MACOS_ICONS: dict[str, int] = {
    "app_icon_16.png": 16,
    "app_icon_32.png": 32,
    "app_icon_64.png": 64,
    "app_icon_128.png": 128,
    "app_icon_256.png": 256,
    "app_icon_512.png": 512,
    "app_icon_1024.png": 1024,
}
MACOS_DIR = REPO_ROOT / "macos/Runner/Assets.xcassets/AppIcon.appiconset"

# Windows ICO 的条目。与仓库里原有 ICO 的结构保持一致：
# 小尺寸用 BMP（兼容性最好），256 用 PNG（BMP 会到 256 KB 以上）。
ICO_BMP_SIZES = (48, 64, 96, 128, 192)
ICO_PNG_SIZES = (256,)
ICO_PATH = REPO_ROOT / "windows/runner/resources/app_icon.ico"

# 应用内（关于对话框）与 README 用的图。
SIMPLE_ICONS: dict[Path, int] = {
    REPO_ROOT / "assets/image/icon.png": 256,
    REPO_ROOT / "docs/assets/icon_512.png": 512,
}


def run_sips(source: Path, size: int, out: Path, fmt: str) -> None:
    """用 sips 缩放并转换格式。"""
    subprocess.run(
        ["sips", "-s", "format", fmt, "-z", str(size), str(size),
         str(source), "--out", str(out)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )


def read_bmp_bgra(path: Path) -> tuple[int, int, bytes]:
    """读取 sips 输出的 BMP，返回 (宽, 高, BGRA 像素，自上而下)。

    只支持 sips 会产出的形态：BITMAPINFOHEADER + 24/32 位、可压缩为 0。
    遇到别的形态直接报错 —— 猜格式只会产出颜色错乱的图标，而且不容易发现。
    """
    data = path.read_bytes()
    if data[:2] != b"BM":
        raise ValueError(f"{path} 不是 BMP")

    pixel_offset = struct.unpack_from("<I", data, 10)[0]
    header_size = struct.unpack_from("<I", data, 14)[0]
    if header_size != 40:
        raise ValueError(f"{path} 的 DIB 头是 {header_size} 字节，只支持 40")

    width, height = struct.unpack_from("<ii", data, 18)
    planes, bpp = struct.unpack_from("<HH", data, 26)
    compression = struct.unpack_from("<I", data, 30)[0]
    if planes != 1 or compression != 0:
        raise ValueError(f"{path} planes={planes} compression={compression}，不支持")
    if bpp not in (24, 32):
        raise ValueError(f"{path} 是 {bpp} 位，只支持 24 / 32")

    top_down = height < 0
    height = abs(height)
    stride = ((width * bpp // 8) + 3) // 4 * 4

    rows: list[bytes] = []
    for row in range(height):
        start = pixel_offset + row * stride
        line = data[start:start + stride]
        out = bytearray(width * 4)
        for x in range(width):
            b, g, r = line[x * (bpp // 8)], line[x * (bpp // 8) + 1], line[x * (bpp // 8) + 2]
            alpha = line[x * 4 + 3] if bpp == 32 else 255
            out[x * 4:x * 4 + 4] = bytes((b, g, r, alpha))
        rows.append(bytes(out))
    if not top_down:
        rows.reverse()
    return width, height, b"".join(rows)


def bmp_icon_entry(bgra: bytes, width: int, height: int) -> bytes:
    """把一个 32 位 BGRA 图（自上而下）打包成 ICO 里的 BMP 条目。

    ICO 里的 BMP 与普通 BMP 有两点不同：
    - biHeight 是实际高度的**两倍**（XOR 位图 + AND 掩码）；
    - 像素是**自下而上**的。
    32 位条目靠 alpha 通道表达透明，AND 掩码仍然必须存在（全 0 表示「不透明」）。
    """
    header = struct.pack(
        "<IiiHHIIiiII",
        40,          # biSize
        width,
        height * 2,  # XOR + AND
        1,           # biPlanes
        32,          # biBitCount
        0,           # biCompression = BI_RGB
        len(bgra),   # biSizeImage
        0, 0, 0, 0,
    )

    # AND 掩码：每行按 4 字节对齐，每像素 1 位，全 0。
    mask_stride = ((width + 31) // 32) * 4
    mask = b"\x00" * (mask_stride * height)

    # 像素自下而上。
    row_bytes = width * 4
    flipped = b"".join(
        bgra[row * row_bytes:(row + 1) * row_bytes] for row in range(height - 1, -1, -1)
    )
    return header + flipped + mask


def write_ico(source: Path, out: Path) -> list[str]:
    """组装 ICO：小尺寸 BMP + 大尺寸 PNG。"""
    entries: list[tuple[int, bytes]] = []

    with tempfile.TemporaryDirectory() as tmp:
        tmp_dir = Path(tmp)
        for size in ICO_BMP_SIZES:
            bmp = tmp_dir / f"{size}.bmp"
            run_sips(source, size, bmp, "bmp")
            width, height, bgra = read_bmp_bgra(bmp)
            if (width, height) != (size, size):
                raise ValueError(f"sips 产出的是 {width}x{height}，期望 {size}x{size}")
            entries.append((size, bmp_icon_entry(bgra, width, height)))

        for size in ICO_PNG_SIZES:
            png = tmp_dir / f"{size}.png"
            run_sips(source, size, png, "png")
            entries.append((size, png.read_bytes()))

    entries.sort(key=lambda e: e[0])

    header = struct.pack("<HHH", 0, 1, len(entries))
    directory = b""
    payload = b""
    offset = 6 + 16 * len(entries)
    for size, blob in entries:
        directory += struct.pack(
            "<BBBBHHII",
            size if size < 256 else 0,   # 256 在目录里记作 0
            size if size < 256 else 0,
            0, 0, 1, 32,
            len(blob),
            offset + len(payload),
        )
        payload += blob

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(header + directory + payload)
    return [f"{size}x{size} ({len(blob)}B)" for size, blob in entries]


def main() -> int:
    parser = argparse.ArgumentParser(description="生成各平台应用图标")
    parser.add_argument("source", type=Path, help="源图（任意 sips 能读的格式）")
    parser.add_argument("--dry-run", action="store_true", help="只打印会改哪些文件")
    args = parser.parse_args()

    source: Path = args.source
    if not source.is_file():
        print(f"源图不存在：{source}", file=sys.stderr)
        return 1

    if args.dry_run:
        print("会更新：")
        for name in MACOS_ICONS:
            print(f"  {MACOS_DIR / name}")
        print(f"  {ICO_PATH}")
        for path in SIMPLE_ICONS:
            print(f"  {path}")
        return 0

    for name, size in MACOS_ICONS.items():
        run_sips(source, size, MACOS_DIR / name, "png")
        print(f"[✓] {MACOS_DIR / name}  {size}x{size}")

    sizes = write_ico(source, ICO_PATH)
    print(f"[✓] {ICO_PATH}  {', '.join(sizes)}")

    for path, size in SIMPLE_ICONS.items():
        run_sips(source, size, path, "png")
        print(f"[✓] {path}  {size}x{size}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
