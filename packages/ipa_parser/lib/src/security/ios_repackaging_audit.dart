import 'package:analysis_model/analysis_model.dart';

import '../ipa_layout.dart';

/// iOS 侧的**重打包 / 注入**识别。
///
/// ## 为什么需要它
///
/// 签名验证能说「这个包的签名对不上」，但说不清**为什么**对不上 —— 砸壳、
/// 改二进制、被注入，在 `codesign` 的输出上是同一句话。而注入有一个静态可见
/// 的痕迹：**多出来一个文件**。
///
/// 实测 10 个真实 IPA（`/Users/wangbaye/Projects/ipa`）：
///
/// | 样本 | `.app` 根目录 dylib |
/// |---|---|
/// | `Ptv_signed.ipa` | `axexUb.dylib` |
/// | `Ptv_signed_v3.ipa` | `kKipwwl.dylib` |
/// | `jincaizb_signed.ipa` | `utwcuovruy.dylib` |
/// | `sun_signed.ipa` | `fkeBhb.dylib` |
/// | `wnsr_signed.ipa` | `muyOzaxpu.dylib` |
/// | `月光_signed_v3.ipa` | `zkEkwazt.dylib` |
/// | `77-v8.5.5.ipa` | `libQuannengLock.dylib` |
/// | 其余 3 个干净样本 | 无 |
///
/// 分离度是 7/7 与 0/3 —— 干净样本里唯一的 dylib 都在
/// `Frameworks/libswift_Concurrency.dylib`，属于正常布局。
///
/// ## 判据
///
/// **直接位于 `.app` 根目录的 `.dylib`**。正常应用把动态库放在
/// `Frameworks/` 下；注入工具则把 tweak 直接扔进 bundle 根。
///
/// ## 被否掉的判据
///
/// 用户最初提的三条里还有一条「bundle 目录名与 `CFBundleName` 不一致」。
/// **实测在全部 10 个样本上都成立，包括干净的**（`33-v8.5.5.ipa` 目录是
/// `Runner.app`、`CFBundleName` 是 `33`；`hongjun` 目录 `TUIKitDemo.app`、
/// 名称「宏润文化」）。用它等于 100% 误报，已弃用。
///
/// 改名但**没有**注入 dylib 的重打包（如 `皇冠-v6.9.63.ipa`，`.app` 名是
/// `SjYTiEFUyV` 但 dylib 全在 `Frameworks/` 下）看不到 —— 写进局限。
class IosRepackagingAudit {
  IosRepackagingAudit._();

  /// 产出发现项。没有命中时返回空列表。
  static List<SecurityFinding> audit({required IpaLayoutFacts layout}) {
    if (!layout.hasDylibInjection) return const [];

    final dylibs = layout.dylibsAtBundleRoot;
    return [
      SecurityFinding(
        ruleId: 'IOS-REPACKAGED',
        platform: SecurityPlatform.ios,
        category: SecurityCategory.other,
        // P2：注入的库**确实**存在于包里，这是事实；它做了什么需要逆向才知道。
        // 不给 P1 是因为「被重打包」本身不等于恶意 —— 用户自己注入的插件、
        // 企业内部工具都会出现同样的布局。
        severity: SecuritySeverity.p2,
        // 文件存在是确定的。**「被注入」这个解释是推断**，所以措辞必须把
        // 两者分开：正文先陈述布局事实，再说明这个布局通常意味着什么。
        confidence: SecurityConfidence.confirmed,
        finding: 'This bundle was modified after it was built: '
            '${dylibs.length} dynamic librar'
            '${dylibs.length == 1 ? 'y sits' : 'ies sit'} directly in the '
            '.app root, outside Frameworks/: ${dylibs.join(', ')}. '
            'Apps built normally keep their dylibs under Frameworks/; a '
            'library at the bundle root is the standard footprint of an '
            'injected tweak or a re-signed repack.',
        messageCode: 'ios.repackaged',
        messageArgs: {
          'count': dylibs.length,
          'dylibs': dylibs,
        },
        evidence: [
          for (final path in dylibs)
            SecurityEvidence(
              source: SecurityEvidenceSource.zipEntry,
              location: path,
              detail: 'dylib outside Frameworks/',
            ),
        ],
        limitation: 'Only dylibs sitting **directly** at the .app root are '
            'counted. A repack that merely renames the bundle, or one that '
            'patches the main binary in place, leaves no extra file and is '
            'not visible here — for those, the signature verdict is the only '
            'signal. Nor can static analysis tell what the injected library '
            'does; it runs with the app\'s own privileges.',
        limitationCode: 'ios.repackaged.limitation',
        recommendation: 'If you did not inject this library yourself, treat '
            'it as untrusted code running inside the app\'s sandbox: it can '
            'read everything the app can read (including credentials and '
            'clipboard contents) and talk to the network on its own. '
            'Cross-check with the signature verdict — a re-signed or '
            'decrypted bundle usually fails verification as well.',
        recommendationCode: 'ios.repackaged.review',
      ),
    ];
  }
}
