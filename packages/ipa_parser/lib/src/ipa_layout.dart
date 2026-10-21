import 'package:archive/archive.dart';

import 'ipa_container.dart';

/// 主应用 bundle 的**目录布局事实** —— 重打包判据的输入。
///
/// ## 为什么单独抽出来
///
/// 「这个包被改过吗」只能从**条目布局**回答：内容分析（字符串、符号）看到的是
/// 代码里有什么，而注入的 dylib 是一个**多出来的文件**，不是某段可疑字节。
///
/// 布局事实在 `IpaAnalysisReader.analyze` 里算好（那里才有 `Archive`），
/// 再交给 `IosPrivacyAudit` 变成发现项 —— 审计层拿不到归档，也不该为了一条
/// 规则重新打开它。
class IpaLayoutFacts {
  const IpaLayoutFacts({
    this.bundlePath,
    this.dylibsAtBundleRoot = const [],
  });

  /// 主应用的 bundle 路径，例如 `Payload/Foo.app`。
  final String? bundlePath;

  /// 直接躺在 `.app` **根目录**下的 `.dylib` 条目（完整路径）。
  ///
  /// 这是「注入」最干净的证据：正常应用把动态库放在 `Frameworks/` 里
  /// （`Frameworks/libswift_Concurrency.dylib`、`Frameworks/Foo.framework/Foo`），
  /// 打包工具（ sideload 注入 / 重签名工具）则把 tweak 直接扔进 bundle 根。
  ///
  /// 实测 10 个真实 IPA：7 个重打包样本全部命中（`kKipwwl.dylib`、
  /// `fkeBhb.dylib`、`libQuannengLock.dylib`…），3 个干净样本零命中。
  final List<String> dylibsAtBundleRoot;

  bool get hasDylibInjection => dylibsAtBundleRoot.isNotEmpty;

  static const IpaLayoutFacts empty = IpaLayoutFacts();
}

/// 从归档条目名计算 [IpaLayoutFacts]。
///
/// **只读条目名，不解压任何内容**：这条规则要回答的是「有没有这个文件」，
/// 不是「这个文件里写了什么」。
class IpaLayoutReader {
  IpaLayoutReader._();

  static IpaLayoutFacts read(Archive archive, IosBundle mainApp) {
    final bundlePath = _normalize(mainApp.path);
    if (bundlePath.isEmpty) return IpaLayoutFacts.empty;

    final prefix = '$bundlePath/';
    final atRoot = <String>[];
    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      final name = _normalize(entry.name);
      if (!name.startsWith(prefix)) continue;
      if (!name.toLowerCase().endsWith('.dylib')) continue;
      // 只看**直接**位于 bundle 根下的：`Frameworks/…` 与嵌套 bundle 里的
      // 动态库都是正常的，把它们算进来等于让这条规则恒亮。
      final rest = name.substring(prefix.length);
      if (rest.isEmpty || rest.contains('/')) continue;
      atRoot.add(name);
    }
    atRoot.sort();

    return IpaLayoutFacts(bundlePath: bundlePath, dylibsAtBundleRoot: atRoot);
  }

  /// ZIP 规范要求 `/`，但现实里存在用反斜杠的包 —— 与容器解析同一口径。
  static String _normalize(String value) {
    var out = value.replaceAll('\\', '/');
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }
}
