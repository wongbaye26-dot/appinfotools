import '../container_structure.dart';
import '../models.dart';
import 'dex_library_scanner.dart';
import 'libchecker_rules.dart';

/// 命中方式。`action` 表示组件名没匹配上、靠 `<intent-filter>` 的 action 命中。
enum LibraryMatchSource { exact, regex, action }

/// 命中项的种类。三组分开输出与上游一致：原生库、组件、DEX 包名各自排序，
/// 最后按 `(label, iconId)` 合并出「识别到几个 SDK」。
enum LibraryHitKind { nativeLibrary, component, dexPackage }

/// 一个具体命中。
class LibraryHit {
  const LibraryHit({
    required this.kind,
    required this.name,
    required this.source,
    this.abis = const [],
    this.size = 0,
    this.componentType,
  });

  final LibraryHitKind kind;

  /// 原生库文件名、组件类名或 DEX 包名。
  final String name;
  final LibraryMatchSource source;

  /// 原生库出现的 ABI（同一 `.so` 常有多份）。
  final List<String> abis;

  /// 原生库未压缩大小之和（多 ABI 相加：占用空间才是用户关心的）。
  final int size;

  final ComponentType? componentType;
}

/// 同一 SDK（`label` + 图标相同）的命中集合。
class LibraryGroup {
  LibraryGroup({
    required this.label,
    required this.iconId,
    required this.simpleColorIcon,
    required this.rule,
  });

  final String label;
  final String? iconId;
  final bool simpleColorIcon;

  /// 组内第一条命中的规则：详情按它取（与上游一致，不做跨规则合并）。
  final LibCheckerRule rule;
  final List<LibraryHit> hits = [];

  int get count => hits.length;
}

/// 库识别结果。
class LibraryReport {
  LibraryReport({
    required this.dataVersion,
    required this.nativeGroups,
    required this.componentGroups,
    required this.dexGroups,
    required this.unmatchedNative,
    required this.dexPackages,
    required this.dexClasses,
    required this.dexTruncated,
    required this.kotlin,
    required this.compose,
  });

  final int dataVersion;

  /// 三组各自按命中数降序、label 升序。
  final List<LibraryGroup> nativeGroups;
  final List<LibraryGroup> componentGroups;
  final List<LibraryGroup> dexGroups;

  /// 没识别出 SDK 的原生库（按体积降序 —— 体积大的更可能是自研/私有库）。
  final List<NativeLibraryEntry> unmatchedNative;

  /// DEX 里出现过的全部包名（升序）。为空表示没扫到 DEX。
  final List<String> dexPackages;

  /// 扫到的类总数。0 表示**没扫到**，不是「没有类」。
  final int dexClasses;
  final bool dexTruncated;

  final bool kotlin;
  final bool compose;

  /// 去重后的 SDK 数：与上游一样按 `(label, iconId)` 计。
  int get sdkCount {
    final keys = <String>{
      for (final group in nativeGroups) '${group.label}\u0000${group.iconId}',
      for (final group in componentGroups) '${group.label}\u0000${group.iconId}',
      for (final group in dexGroups) '${group.label}\u0000${group.iconId}',
    };
    return keys.length;
  }

  bool get dexScanned => dexClasses > 0;
}

/// 对解析结果跑 LibChecker 规则。
///
/// 输入刻意只用「已经解析出来的结构」：原生库列表来自 ZIP 目录，组件来自
/// manifest，DEX 信号来自 [DexLibraryScanner]。这样识别结果可复现、可测试，
/// 也不需要在 UI 层再打开一次 APK。
class LibraryDetector {
  LibraryDetector._();

  static LibraryReport detect({
    required LibCheckerRules rules,
    required String packageName,
    required List<NativeLibraryEntry> nativeLibraries,
    required List<AndroidComponent> components,
    required DexLibrarySignals dex,
    Set<String> archiveEntries = const {},
  }) {
    final libNames = {for (final lib in nativeLibraries) lib.name};

    final nativeByKey = <(String, String?), List<LibraryHit>>{};
    final nativeGroups = <LibraryGroup>[];
    final nativeGroupByKey = <(String, String?), LibraryGroup>{};
    final matchedNames = <String>{};

    for (final lib in nativeLibraries) {
      final rule = rules.find(LibCheckerRuleType.native, lib.name);
      if (rule == null || !_passesNativeValidation(lib.name, libNames, dex)) {
        continue;
      }
      matchedNames.add(lib.name);
      final key = (rule.label, rule.iconId);
      final group = nativeGroupByKey.putIfAbsent(
        key,
        () => LibraryGroup(
          label: rule.label,
          iconId: rule.iconId,
          simpleColorIcon: rule.simpleColorIcon,
          rule: rule,
        ),
      );
      if (!nativeGroups.contains(group)) nativeGroups.add(group);
      // 同一个 .so 在多个 ABI 目录各有一份：归到同一条命中里，而不是让
      // 「命中数」被 ABI 数量放大。
      final existing = nativeByKey[key]?.where((h) => h.name == lib.name).firstOrNull;
      if (existing == null) {
        final hit = LibraryHit(
          kind: LibraryHitKind.nativeLibrary,
          name: lib.name,
          source: rule.name == lib.name
              ? LibraryMatchSource.exact
              : LibraryMatchSource.regex,
        );
        nativeByKey.putIfAbsent(key, () => []).add(hit);
        group.hits.add(hit);
      }
      final index = group.hits.indexWhere((h) => h.name == lib.name);
      final merged = group.hits[index];
      group.hits[index] = LibraryHit(
        kind: merged.kind,
        name: merged.name,
        source: merged.source,
        abis: [...merged.abis, lib.abi],
        size: merged.size + lib.size,
      );
    }

    final unmatchedNative = [
      for (final lib in nativeLibraries)
        if (!matchedNames.contains(lib.name)) lib,
    ]..sort((a, b) => b.size.compareTo(a.size));

    final componentGroups = <LibraryGroup>[];
    final componentGroupByKey = <(String, String?), LibraryGroup>{};
    for (final component in components) {
      final name = _componentName(component.name, packageName);
      if (name == null) continue;
      final match = _matchComponent(rules, component, name);
      if (match == null) continue;
      final (rule, source) = match;
      final key = (rule.label, rule.iconId);
      final group = componentGroupByKey.putIfAbsent(
        key,
        () => LibraryGroup(
          label: rule.label,
          iconId: rule.iconId,
          simpleColorIcon: rule.simpleColorIcon,
          rule: rule,
        ),
      );
      if (!componentGroups.contains(group)) componentGroups.add(group);
      group.hits.add(LibraryHit(
        kind: LibraryHitKind.component,
        name: name,
        source: source,
        componentType: component.type,
      ));
    }

    final sortedPackages = dex.packages.toList()..sort();
    final dexGroups = <LibraryGroup>[];
    final dexGroupByKey = <(String, String?), LibraryGroup>{};
    for (final package in sortedPackages) {
      final match = _matchPackage(rules, package);
      if (match == null) continue;
      final (rule, source) = match;
      final key = (rule.label, rule.iconId);
      final group = dexGroupByKey.putIfAbsent(
        key,
        () => LibraryGroup(
          label: rule.label,
          iconId: rule.iconId,
          simpleColorIcon: rule.simpleColorIcon,
          rule: rule,
        ),
      );
      if (!dexGroups.contains(group)) dexGroups.add(group);
      group.hits.add(LibraryHit(
        kind: LibraryHitKind.dexPackage,
        name: package,
        source: source,
      ));
    }

    return LibraryReport(
      dataVersion: rules.dataVersion,
      nativeGroups: _sortGroups(nativeGroups),
      componentGroups: _sortGroups(componentGroups),
      dexGroups: _sortGroups(dexGroups),
      unmatchedNative: unmatchedNative,
      dexPackages: sortedPackages,
      dexClasses: dex.classCount,
      dexTruncated: dex.truncated,
      kotlin: _hasKotlinMarker(dex, archiveEntries),
      compose: _hasComposeMarker(dex, archiveEntries),
    );
  }

  /// Kotlin 的三类标记：`Lkotlin/Metadata;`、`kotlin.*` 类，以及打包元数据
  /// （`kotlin-tooling-metadata.json` / `META-INF/*.kotlin_module`）。前两类
  /// 来自 DEX，最后一类只有看过 ZIP 目录才知道 —— 有些库把元数据当唯一痕迹。
  static bool _hasKotlinMarker(DexLibrarySignals dex, Set<String> entries) {
    if (dex.kotlinMetadata || dex.kotlinClasses) return true;
    for (final entry in entries) {
      if (entry.endsWith('/kotlin-tooling-metadata.json') ||
          entry == 'kotlin-tooling-metadata.json') {
        return true;
      }
      if (entry.startsWith('META-INF/') && entry.endsWith('.kotlin_module')) {
        return true;
      }
    }
    return false;
  }

  static bool _hasComposeMarker(DexLibrarySignals dex, Set<String> entries) {
    if (dex.composeClasses) return true;
    for (final entry in entries) {
      if (entry.startsWith('META-INF/androidx.compose') &&
          entry.endsWith('.version')) {
        return true;
      }
    }
    return false;
  }

  /// 命中数降序、label 升序。插入顺序作为最后一级，保证同分时输出稳定。
  static List<LibraryGroup> _sortGroups(List<LibraryGroup> groups) {
    final indexed = [for (var i = 0; i < groups.length; i++) (i, groups[i])];
    indexed.sort((a, b) {
      final byCount = b.$2.count.compareTo(a.$2.count);
      if (byCount != 0) return byCount;
      final byLabel = a.$2.label.compareTo(b.$2.label);
      if (byLabel != 0) return byLabel;
      return a.$1.compareTo(b.$1);
    });
    return [for (final entry in indexed) entry.$2];
  }

  /// 组件名补全：`.Foo` → `pkg.Foo`；`Foo`（不含点）→ `pkg.Foo`；
  /// 其余原样返回。补全规则来自 AOSP 的组件名解析语义。
  static String? _componentName(String? name, String packageName) {
    if (name == null || name.isEmpty) return null;
    if (name.startsWith('.')) return '$packageName$name';
    if (!name.contains('.')) return '$packageName.$name';
    return name;
  }

  static (LibCheckerRule, LibraryMatchSource)? _matchComponent(
    LibCheckerRules rules,
    AndroidComponent component,
    String name,
  ) {
    final type = switch (component.type) {
      ComponentType.activity || ComponentType.activityAlias => LibCheckerRuleType.activity,
      ComponentType.service => LibCheckerRuleType.service,
      ComponentType.receiver => LibCheckerRuleType.receiver,
      ComponentType.provider => LibCheckerRuleType.provider,
    };
    final rule = rules.find(type, name);
    if (rule != null) {
      return (
        rule,
        rule.name == name ? LibraryMatchSource.exact : LibraryMatchSource.regex,
      );
    }
    for (final filter in component.intentFilters) {
      for (final action in filter.actions) {
        // action 只做精确匹配：正则化 action 名会命中一批公共系统 action，
        // 把「声明了标准 action」误算成「集成了某 SDK」。
        final actionRule = rules.find(
          LibCheckerRuleType.action,
          action,
          useRegex: false,
        );
        if (actionRule != null) return (actionRule, LibraryMatchSource.action);
      }
    }
    return null;
  }

  /// DEX 规则名是包名前缀：包本身或任一上级包精确命中（取最长的），
  /// 都不中再拿完整包名试正则（上游有 `okhttp3\.(.*)` 这类写法）。
  static (LibCheckerRule, LibraryMatchSource)? _matchPackage(
    LibCheckerRules rules,
    String package,
  ) {
    var current = package;
    while (true) {
      final rule = rules.find(
        LibCheckerRuleType.dex,
        current,
        useRegex: false,
      );
      if (rule != null) return (rule, LibraryMatchSource.exact);
      final dot = current.lastIndexOf('.');
      if (dot <= 0) break;
      current = current.substring(0, dot);
    }
    final rule = rules.find(LibCheckerRuleType.dex, package);
    if (rule != null) return (rule, LibraryMatchSource.regex);
    return null;
  }

  /// 几个过于常见的库名需要旁证：加固库要在 DEX 里找到壳类，`libapp.so`
  /// 要有 `libflutter.so` 或 `FlutterInjector`，`libmain.so` 要有 `libunity.so`。
  /// 只按文件名认 SDK 会把「随便一个自研 `libapp.so`」说成 Flutter。
  static bool _passesNativeValidation(
    String name,
    Set<String> allLibNames,
    DexLibrarySignals dex,
  ) {
    return switch (name) {
      'libjiagu.so' ||
      'libjiagu_a64.so' ||
      'libjiagu_x86.so' ||
      'libjiagu_x64.so' =>
        dex.qihooShell,
      'libDexHelper.so' || 'libDexHelper-x86.so' || 'libdexjni.so' => dex.secneoShell,
      'libapp.so' => allLibNames.contains('libflutter.so') || dex.flutterInjector,
      'libmain.so' => allLibNames.contains('libunity.so'),
      _ => true,
    };
  }
}
