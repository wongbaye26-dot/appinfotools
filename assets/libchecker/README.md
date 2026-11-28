# LibChecker 规则数据（库识别）

`libchecker_v5.json` 是 [LibChecker-Rules](https://github.com/LibChecker/LibChecker-Rules)
`portable-v5` 数据的紧凑重打包，供「库 (Libraries)」标签页识别第三方 SDK。

| 项 | 值 |
| --- | --- |
| 上游数据版本 | `dataVersion` 50（`schemaVersion` 5） |
| 规则数 | 3053（本应用参与匹配 3039，另有 14 条 `static` 保留但不使用） |
| 正则规则 | 123 |
| 详情 | 891 份（按内容去重；上游 2934 个文件） |
| 文件大小 | 约 756 KB |
| 许可 | Apache-2.0，全文见同目录 `LICENSE` |

## 字段

```jsonc
{
  "meta": { "dataVersion", "sourceRevision", "schemaVersion", "ruleCount", "source", "license" },
  "rules": [[id, name, label, type, iconId, isSimpleColorIcon, detailIndex, priority], ...],
  "regexIds": [id, ...],
  "details": [{ "zh-Hans": [label, dev_team, description, source_link, [contributors]], "en": [...] }, ...]
}
```

- `type`：0 原生库、1 service、2 activity、3 receiver、4 provider、5 DEX 包名、6 static、7 permission、8 metadata、9 intent action。
- `name`：原生库是 `.so` 文件名，组件是完整类名，DEX 是包名前缀，正则是正则源码。
- `detailIndex` 为 `-1` 表示该规则没有详情。

## 重新生成

```bash
curl -sL -o /tmp/libchecker/portable-v5.zip \
  https://raw.githubusercontent.com/LibChecker/LibChecker-Rules/rules-data/releases/50/portable-v5.zip
unzip -q /tmp/libchecker/portable-v5.zip -d /tmp/libchecker/extracted
python3 tool/sync_libchecker_rules.py /tmp/libchecker/extracted
```

脚本会校验并重打包，输出各结构的数量与 sha256。升级数据版本时同步修改
`assets/libchecker/README.md` 里的版本号与 `tool/sync_libchecker_rules.py`
文档中的 URL。

## 有意省略

- **图标**：上游有 198 个 SVG（约 574 KB）。本应用没有 SVG 渲染器，带进来
  也只能当装饰，界面改用按 SDK 名派生的字母色块。
- **在线更新**：参考实现支持从网络更新规则；本应用只在发版时更新资产，
  避免把「网络请求」引入一个本地分析工具。
