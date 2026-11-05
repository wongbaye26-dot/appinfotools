# P2-4：iOS 分发类型分类

> 日期：2026-11-05｜状态：已实现

## 改动

`IosProvisioningProfile` 新增：

- `ProvisionsAllDevices`（企业/内部分发）；
- `ProvisionedDevices` 数量；
- `Entitlements.get-task-allow`（开发分发）；
- `IosDistributionType`：`appStore / adHoc / enterprise / development / unknown`。

判定顺序：

1. `ProvisionsAllDevices == true` → enterprise；
2. `get-task-allow == true` → development；
3. `ProvisionedDevices > 0` → adHoc；
4. `ProvisionedDevices == 0` → appStore；
5. 字段缺失 → unknown，不猜成 App Store。

展示：`DetailRenderer` 在描述文件段落输出“分发类型”，6 语言文案已补。

## 注意

- App Store 分发的 IPA 通常**没有** `embedded.mobileprovision`，因此不会显示分类；
  这是未知，不是 App Store。
- 分类只来自描述文件静态字段，不验证 CMS 签名。

## 门禁

| 项 | 结果 |
|---|---|
| 根项目 `flutter test` | 1,772 通过 |
| `ipa_parser` | 244 通过 |
| 根项目 / 包 analyze | 0 问题 |
| `dart format` | 407 files，0 changed |
