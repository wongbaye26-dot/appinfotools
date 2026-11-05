/// 平台中立的**中文话术**词表。
///
/// 中文界面文案在 Android（DEX 的 MUTF-8）与 iOS（UTF-8 / UTF-16）里是同一批
/// 词，两个解析器各存一份必然漂移，所以表放在这里，由两侧共用。
/// 这里只放**词表**，判级与证据组装仍留在各平台 —— 两个平台的证据来源、
/// 覆盖率口径与发现项 id 都不同。
///
/// ## 为什么单独一张表（而不是塞进 ASCII 标记表）
///
/// `AsciiStrings` 只认 0x20–0x7E；DEX 侧 `codeMarkers` 的字面量因此必须全是
/// ASCII，写「助记词」进去就是一条永远命不中的死规则。中文词只能由 Unicode
/// 提取器（`Utf8Strings` / `Utf16Strings` / DEX `string_ids` 的 MUTF-8 解码）
/// 产出后再匹配。
///
/// ## 口径
///
/// 命中只是**话术/能力线索**，不是恶意判决：正规钱包也包含「助记词」「收款地址」。
/// 两侧统一由各自的元发现项承载（`info` + `isMeta`），不单独把等级推到 P2。
///
/// ## 字面量约束
///
/// 全部非 ASCII、长度 ≥2、id/字面量不重复、**任意两条互不嵌套** —— 嵌套会让
/// 同一句原文一次命中多个 id，证据看起来像「发现了更多东西」。
library;

/// 话术类别。
enum UnicodePhraseKind {
  /// 钱包密钥材料相关（正规钱包也常见）。
  seed,

  /// 社工/钓鱼话术：这一组才是仿冒包相对正规钱包最有区分度的部分。
  social,

  /// 链上资金操作相关（正规钱包也常见）。
  transfer;

  String get id => switch (this) {
        UnicodePhraseKind.seed => 'seed',
        UnicodePhraseKind.social => 'social',
        UnicodePhraseKind.transfer => 'transfer',
      };
}

/// 一条中文话术标记。
class UnicodePhraseMarker {
  /// 稳定标识（给报告消费，不随文案变化）。
  final String id;

  /// 中文原文；大小写无关（中文没有大小写）。
  final String literal;

  final UnicodePhraseKind kind;

  const UnicodePhraseMarker(this.id, this.literal, this.kind);
}

/// 29 条高区分度话术。挑选原则：**具体词组**，不收「验证」「授权」「转账」
/// 这种几乎每个 App 都有的单字/通用词。
const List<UnicodePhraseMarker> unicodePhraseMarkers = [
  // ---- 钱包密钥材料 ----
  UnicodePhraseMarker('phrase.mnemonic', '助记词', UnicodePhraseKind.seed),
  UnicodePhraseMarker('phrase.seed_phrase', '种子短语', UnicodePhraseKind.seed),
  UnicodePhraseMarker('phrase.private_key', '私钥', UnicodePhraseKind.seed),
  UnicodePhraseMarker('phrase.import_wallet', '导入钱包', UnicodePhraseKind.seed),
  UnicodePhraseMarker('phrase.backup_wallet', '备份钱包', UnicodePhraseKind.seed),
  UnicodePhraseMarker('phrase.wallet_password', '钱包密码', UnicodePhraseKind.seed),
  // ---- 社工 / 钓鱼话术 ----
  UnicodePhraseMarker('phrase.unfreeze', '解冻', UnicodePhraseKind.social),
  UnicodePhraseMarker(
      'phrase.frozen_account', '账户冻结', UnicodePhraseKind.social),
  UnicodePhraseMarker('phrase.frozen_funds', '资金冻结', UnicodePhraseKind.social),
  UnicodePhraseMarker(
      'phrase.account_abnormal', '账户异常', UnicodePhraseKind.social),
  UnicodePhraseMarker(
      'phrase.manual_support', '人工客服', UnicodePhraseKind.social),
  UnicodePhraseMarker(
      'phrase.deposit_required', '保证金', UnicodePhraseKind.social),
  UnicodePhraseMarker('phrase.rebate_scam', '刷单返利', UnicodePhraseKind.social),
  UnicodePhraseMarker(
      'phrase.part_time_rebate', '兼职返利', UnicodePhraseKind.social),
  UnicodePhraseMarker('phrase.airdrop_claim', '领取空投', UnicodePhraseKind.social),
  UnicodePhraseMarker('phrase.limited_claim', '限时领取', UnicodePhraseKind.social),
  UnicodePhraseMarker(
      'phrase.wallet_upgrade', '钱包升级', UnicodePhraseKind.social),
  UnicodePhraseMarker(
      'phrase.asset_abnormal', '资产异常', UnicodePhraseKind.social),
  UnicodePhraseMarker(
      'phrase.topup_missing', '充值未到账', UnicodePhraseKind.social),
  UnicodePhraseMarker(
      'phrase.withdraw_failed', '提现失败', UnicodePhraseKind.social),
  UnicodePhraseMarker('phrase.risk_review', '风控审核', UnicodePhraseKind.social),
  // ---- 链上资金操作 ----
  UnicodePhraseMarker(
      'phrase.receiving_address', '收款地址', UnicodePhraseKind.transfer),
  UnicodePhraseMarker(
      'phrase.withdraw_address', '提币地址', UnicodePhraseKind.transfer),
  UnicodePhraseMarker('phrase.fund_sweep', '资金归集', UnicodePhraseKind.transfer),
  UnicodePhraseMarker(
      'phrase.sweep_address', '归集地址', UnicodePhraseKind.transfer),
  UnicodePhraseMarker(
      'phrase.energy_lease', '能量租赁', UnicodePhraseKind.transfer),
  UnicodePhraseMarker(
      'phrase.bandwidth_lease', '带宽租赁', UnicodePhraseKind.transfer),
  UnicodePhraseMarker(
      'phrase.unlimited_approval', '无限授权', UnicodePhraseKind.transfer),
  UnicodePhraseMarker(
      'phrase.miner_fee_shortage', '矿工费不足', UnicodePhraseKind.transfer),
];

/// 命中「社工/钓鱼话术」的标记 id —— 两侧共用的「有区分度」判据。
/// 从表推导，不另写一份清单（否则加词时必然漏改）。
final Set<String> socialPhraseIds = {
  for (final marker in unicodePhraseMarkers)
    if (marker.kind == UnicodePhraseKind.social) marker.id,
};

/// 命中「钱包密钥材料」的标记 id —— 用于 `seedInput` 这类「有输入界面」的线索。
final Set<String> seedPhraseIds = {
  for (final marker in unicodePhraseMarkers)
    if (marker.kind == UnicodePhraseKind.seed) marker.id,
};
