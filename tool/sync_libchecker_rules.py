#!/usr/bin/env python3
"""把 LibChecker-Rules 的 portable-v5 数据打包成本应用使用的紧凑 JSON。

用法：

    # 1) 下载并解开 portable-v5.zip（见文档）
    curl -sL -o /tmp/libchecker/portable-v5.zip \
        https://raw.githubusercontent.com/LibChecker/LibChecker-Rules/rules-data/releases/50/portable-v5.zip
    unzip -q /tmp/libchecker/portable-v5.zip -d /tmp/libchecker/extracted

    # 2) 生成 assets/libchecker/libchecker_v5.json 与 icons.json
    python3 tool/sync_libchecker_rules.py /tmp/libchecker/extracted

为什么不直接解析 zip：运行时只读一个 `jsonDecode` 能吃的文件，避免引第二个
ZIP 读取路径；图标（197 个 SVG）另存为 icons.json，由 flutter_svg 渲染，
用来在库识别里显示 SDK 的真实 LOGO。

数据许可：LibChecker-Rules 为 Apache-2.0；许可全文由本脚本写入
`assets/libchecker/LICENSE`（下载失败时保留已有文件）。
"""

from __future__ import annotations

import hashlib
import json
import pathlib
import shutil
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "assets" / "libchecker"
LICENSE_URL = "https://www.apache.org/licenses/LICENSE-2.0.txt"

# 只保留应用会参与匹配的类型 + 上游有但暂不使用的 static(6)，其余丢弃。
KEEP_TYPES = {0, 1, 2, 3, 4, 5, 6, 9}


def load_json(path: pathlib.Path):
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def detail_payload(details_dir: pathlib.Path, path: str, cache: dict[str, int], rows: list[dict]):
    """把一条规则的详情压成 {locale: [label, dev, desc, source, [contributors]]}。

    上游每个详情是单独文件、且大量重复（2934 个文件 → 891 份内容），按内容
    去重后 `rules[].detailIndex` 指向同一份。
    """
    if not path:
        return -1
    payload = load_json(details_dir.parent / path)
    locales = {}
    for entry in payload.get("data", []):
        locale = entry.get("locale")
        data = entry.get("data", {})
        if not locale:
            continue
        locales[locale] = [
            data.get("label"),
            data.get("dev_team"),
            data.get("description"),
            data.get("source_link"),
            data.get("rule_contributors") or [],
        ]
    key = json.dumps(locales, sort_keys=True, ensure_ascii=False)
    if key in cache:
        return cache[key]
    index = len(rows)
    rows.append(locales)
    cache[key] = index
    return index


def main(source: str) -> int:
    src = pathlib.Path(source)
    metadata = load_json(src / "metadata.json")
    core = load_json(src / "core.json")
    rules = core.get("rules", [])
    if not rules:
        print("core.json 里没有 rules", file=sys.stderr)
        return 1

    details: list[dict] = []
    cache: dict[str, int] = {}
    compact_rules = []
    regex_ids = []
    for rule in rules:
        kind = rule.get("type")
        if kind not in KEEP_TYPES:
            continue
        detail_index = detail_payload(src / "details", rule.get("detailPath") or "", cache, details)
        compact_rules.append(
            [
                rule.get("id"),
                rule.get("name"),
                rule.get("label"),
                kind,
                rule.get("iconId"),
                1 if rule.get("isSimpleColorIcon") else 0,
                detail_index,
                rule.get("priority", rule.get("id")),
            ]
        )
        if rule.get("isRegexRule"):
            regex_ids.append(rule.get("id"))

    bundle = {
        "meta": {
            "dataVersion": metadata.get("dataVersion"),
            "sourceRevision": metadata.get("sourceRevision"),
            "schemaVersion": core.get("schemaVersion"),
            "ruleCount": len(compact_rules),
            "source": "https://github.com/LibChecker/LibChecker-Rules",
            "license": "Apache-2.0",
        },
        "rules": compact_rules,
        "regexIds": regex_ids,
        "details": details,
    }

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    target = OUT_DIR / "libchecker_v5.json"
    encoded = json.dumps(bundle, ensure_ascii=False, separators=(",", ":"))
    target.write_text(encoded, encoding="utf-8")
    print(f"写入 {target.relative_to(ROOT)}：{len(encoded)} B，"
          f"{len(compact_rules)} 条规则，{len(regex_ids)} 条正则，{len(details)} 份详情")
    print(f"sha256 {hashlib.sha256(encoded.encode()).hexdigest()}")

    # 图标单独打成一个 JSON：一次 asset 加载即可，避免 197 个文件条目。
    icons_dir = pathlib.Path(source) / "icons"
    icons: dict[str, str] = {}
    if icons_dir.is_dir():
        for icon_path in sorted(icons_dir.glob("*.svg")):
            icons[icon_path.stem] = icon_path.read_text(encoding="utf-8")
    if icons:
        icons_target = OUT_DIR / "icons.json"
        icons_encoded = json.dumps(icons, ensure_ascii=False, separators=(",", ":"))
        icons_target.write_text(icons_encoded, encoding="utf-8")
        print(f"写入 {icons_target.relative_to(ROOT)}：{len(icons)} 个图标，"
              f"{len(icons_encoded)} B")

    license_path = OUT_DIR / "LICENSE"
    if not license_path.exists():
        try:
            with urllib.request.urlopen(LICENSE_URL, timeout=15) as response:
                license_path.write_bytes(response.read())
            print(f"写入 {license_path.relative_to(ROOT)}")
        except Exception as error:  # noqa: BLE001 - 网络失败不该覆盖已有文件
            print(f"警告：下载 Apache-2.0 许可失败（{error}），请手动放置 LICENSE", file=sys.stderr)
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1]))
