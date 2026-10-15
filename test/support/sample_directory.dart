// 真实样本目录的发现逻辑。
//
// 抽出来单独一个文件的原因：这段逻辑此前**散在两个测试文件里**，而且把五种
// 完全不同的情况（未配置 / 目录不存在 / 目录为空 / 有文件但没有受支持的样本 /
// 该类样本缺失）全都压成同一个 `const []`，于是「没有 APK 样本」被当成了
// 「样本目录没配」，`sample!` 直接崩在 null-check 上。
//
// 五种情况必须**分别**给出可理解的原因：前四种是环境问题，第五种只是
// 「这一类没有」。把它们混在一起，用户看到的就是「测试失败了」而不是
// 「你的样本目录里没有 APK」。
//
// 本文件不是测试文件（不以 `_test.dart` 结尾），`flutter test` 不会收集它；
// 它由 `test/sample_directory_test.dart` 覆盖。

import 'dart:io';

/// 样本类型。
///
/// Android 侧收的是应用**支持的容器格式全家族**，而不只是 `.apk` ——
/// 只认 `.apk` 会把一个只有 `.xapk` 的目录报成「没有受支持的样本」，
/// 而应用明明能解析它。
enum SampleKind {
  android,
  ios;

  /// 该类型认得的扩展名（小写、含点）。
  List<String> get extensions => switch (this) {
        SampleKind.android => const ['.apk', '.xapk', '.apkm', '.apks'],
        SampleKind.ios => const ['.ipa'],
      };

  /// 面向用户的类型描述。
  String get label => switch (this) {
        SampleKind.android => 'Android（.apk / .xapk / .apkm / .apks）',
        SampleKind.ios => 'iOS（.ipa）',
      };
}

/// 样本目录的整体状态。
enum SampleDirStatus {
  /// 未设置环境变量。
  notConfigured,

  /// 设置了，但路径不存在，或者不是一个目录。
  missing,

  /// 目录存在，但里面一个文件都没有。
  empty,

  /// 目录里有文件，但没有任何受支持的样本。
  noSupportedSamples,

  /// 至少有一类样本可用。
  ready,
}

/// 一次样本目录扫描的结果。
class SampleDirectory {
  /// 生效的目录路径；未配置时为 `null`。
  final String? path;

  final SampleDirStatus status;

  /// 目录里的普通文件数（不递归、不含子目录）。
  final int fileCount;

  /// 受支持的 Android 样本，按路径排序。
  final List<File> androidSamples;

  /// 受支持的 iOS 样本，按路径排序。
  final List<File> iosSamples;

  const SampleDirectory._({
    required this.path,
    required this.status,
    required this.fileCount,
    required this.androidSamples,
    required this.iosSamples,
  });

  /// 按类型取样本。
  List<File> samplesOf(SampleKind kind) => switch (kind) {
        SampleKind.android => androidSamples,
        SampleKind.ios => iosSamples,
      };

  /// 该类型是否**没有**样本 —— 没有时返回一句能读懂的原因，有则返回 `null`。
  ///
  /// 返回 `null` 表示「可以跑」。这正是 `group(..., skip: ...)` 需要的语义：
  /// `skip` 为 `null` 就执行，为字符串就跳过并把原因显示出来。
  String? skipReasonFor(SampleKind kind) {
    switch (status) {
      case SampleDirStatus.notConfigured:
        return '未设置 APPINFOTOOL_SAMPLES，外部真实样本测试未执行';
      case SampleDirStatus.missing:
        return 'APPINFOTOOL_SAMPLES 指向的路径不存在或不是目录：$path';
      case SampleDirStatus.empty:
        return 'APPINFOTOOL_SAMPLES 目录里没有任何文件：$path';
      case SampleDirStatus.noSupportedSamples:
        return 'APPINFOTOOL_SAMPLES 目录里有 $fileCount 个文件，但没有受支持的样本'
            '（Android 认 ${SampleKind.android.extensions.join(' / ')}；'
            'iOS 认 ${SampleKind.ios.extensions.join(' / ')}）';
      case SampleDirStatus.ready:
        if (samplesOf(kind).isNotEmpty) return null;
        final other =
            kind == SampleKind.android ? SampleKind.ios : SampleKind.android;
        return '样本目录里没有 ${kind.label} 样本'
            '（目录里有 $fileCount 个文件，其中 ${other.label} 有 '
            '${samplesOf(other).length} 个）';
    }
  }

  /// 一句话摘要，便于在日志里辨别「这次到底跑了什么」。
  String get summary {
    final where = switch (status) {
      SampleDirStatus.notConfigured => '未配置',
      SampleDirStatus.missing => '路径不存在',
      SampleDirStatus.empty => '目录为空',
      SampleDirStatus.noSupportedSamples => '无受支持样本',
      SampleDirStatus.ready => '可用',
    };
    return '样本目录[$where] path=${path ?? '-'} '
        'files=$fileCount android=${androidSamples.length} ios=${iosSamples.length}';
  }

  /// 扫描给定路径。**不做任何写入**。
  static SampleDirectory scan({String? path}) {
    if (path == null || path.isEmpty) {
      return const SampleDirectory._(
        path: null,
        status: SampleDirStatus.notConfigured,
        fileCount: 0,
        androidSamples: [],
        iosSamples: [],
      );
    }

    final directory = Directory(path);
    // `Directory` 没有 `isDirectorySync`；用 `typeSync` 判断，路径指向文件时
    // 也必须算「不存在目录」而不是硬着头皮 `listSync` 抛异常。
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.directory) {
      return SampleDirectory._(
        path: path,
        status: SampleDirStatus.missing,
        fileCount: 0,
        androidSamples: const [],
        iosSamples: const [],
      );
    }

    // 目录不可读（权限）时不能抛 —— 那会把「环境问题」变成「测试崩溃」。
    List<File> files;
    try {
      files = directory.listSync().whereType<File>().toList();
    } on FileSystemException {
      return SampleDirectory._(
        path: path,
        status: SampleDirStatus.missing,
        fileCount: 0,
        androidSamples: const [],
        iosSamples: const [],
      );
    }

    if (files.isEmpty) {
      return SampleDirectory._(
        path: path,
        status: SampleDirStatus.empty,
        fileCount: 0,
        androidSamples: const [],
        iosSamples: const [],
      );
    }

    List<File> of(SampleKind kind) {
      final matched = files
          .where((f) =>
              kind.extensions.any((e) => f.path.toLowerCase().endsWith(e)))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      return matched;
    }

    final android = of(SampleKind.android);
    final ios = of(SampleKind.ios);

    return SampleDirectory._(
      path: path,
      status: (android.isEmpty && ios.isEmpty)
          ? SampleDirStatus.noSupportedSamples
          : SampleDirStatus.ready,
      fileCount: files.length,
      androidSamples: android,
      iosSamples: ios,
    );
  }

  /// 从环境变量扫描（默认 `APPINFOTOOL_SAMPLES`）。
  factory SampleDirectory.fromEnvironment([
    String name = 'APPINFOTOOL_SAMPLES',
  ]) =>
      SampleDirectory.scan(path: Platform.environment[name]);
}
