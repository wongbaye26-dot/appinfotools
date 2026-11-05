# 两个企业签 iOS 样本的静态审计

> 日期：2026-11-05
> 样本来源：用户提供的两个下载页（已解析到真实 IPA；样本不进版本库）
> 性质：**静态证据，不是恶意判决**

## 样本

| | 巴黎人 | 33 |
|---|---|---|
| 文件 | `bali_6.9.99.ipa` | `33_8.5.5.ipa` |
| SHA-256 | `689a1a…25d2` | `83447e…a214` |
| 大小 | 81,003,042 B | 59,184,059 B |
| bundle | `com.fpcg.w2273.krolig` | `awc.WenChun168wc.app` |
| 版本 | 6.9.99 / 11 | 8.5.5 / 8.5.5 |
| 描述文件分发类型 | enterprise | enterprise |
| Team ID | `BR2XA724F8` | `5X7QULHX5J` |

## 关键结果

### 巴黎人

- `IOS-REPACKAGED` P2：根目录有 `Payload/creatorMainProj.app/slqtFqpyy.dylib`，不在 Frameworks/ 下；
- `IOS-RULE-C` P1：相册/相机 + OCR + 网络能力共现；
- `IOS-RULE-D-ESCALATED` P1：`NSAllowsArbitraryLoads=true`；
- `IOS-RULE-A/B/G` P2；
- 5 个运行时权限请求：ATT、麦克风、相机、定位、通知；
- 根目录 `slqtFqpyy.dylib` 现在也进入安全扫描目标（Mach-O/字符串/选择子），不再只报布局异常；
- 盗 U 链：capability/source/injection 有证据，payload/family 缺失；
- 评估：`capabilityOnly / P3 / score 50`；
- 密封：`verified 64/1479`，`entry_limit`（部分）。

### 33

- `IOS-REPACKAGED` P2：根目录 `Payload/Runner.app/aabyfp.dylib`；
- `IOS-RULE-D-ESCALATED` P1：ATS 任意明文；
- `IOS-RULE-A/E/G` P2；
- 联系人/相册/相机/IDFA/运动/后台能力并存；
- 根目录 `aabyfp.dylib` 现在也进入安全扫描目标；
- 盗 U 链：capability/source/injection/payload 有证据，family 缺失；
- 评估：`suspicious / P2 / score 71`；
- 密封：`verified 64/1789`，`entry_limit`（部分）。

## 发现并修复的检测 bug

两个包的 CodeResources 都超过 64 条。旧逻辑只要 `checks.length >= 64`
就把 `notChecked` 置位，最终把**已验过 64 条**的结果整体标成
`SealState.notChecked` —— 界面/报告会显示“未检查”，而实际上已经验了一部分。

修复：

- `checked` 只在摘要函数成功返回后递增；
- 只有 `checked == 0` 才是 `notChecked`；
- `checked > 0` 且无 mismatch/missing → `verified`，用
  `entriesChecked/entriesTotal + seal.entry_limit` 表达部分覆盖；
- `seal.digest_unavailable` 只在摘要函数不可用时追加，不再常驻。

新增测试：65 条 CodeResources → `verified` + `entriesChecked=64` +
`entry_limit`；摘要函数不可用仍为 `notChecked`。

## 仍未覆盖

- 两个样本都是 enterprise 重签名包，且 iOS 官方基线为 0 条，`baseline=unavailable`；
- CodeResources 只验 64 条 / 64 MiB，其余 `entry_limit`；
- 不做密码学验签；
- 不执行、不联网，不能证明注入 dylib 的实际行为。
