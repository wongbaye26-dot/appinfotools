import 'package:apk_info_tool/apkparser/analysis_builder.dart';
import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/file_hash.dart';
import 'package:apk_info_tool/utils/signature_analyzer.dart';
import 'package:apk_parser/apk_parser.dart' show ApkParseStage;
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'info_page_provider.g.dart';

@Riverpod(keepAlive: true)
class CurrentApkInfo extends _$CurrentApkInfo {
  @override
  ApkInfo? build() {
    return null;
  }

  void update(ApkInfo? apkInfo) {
    state?.dispose();
    state = apkInfo;
  }

  void reset() {
    state?.dispose();
    state = null;
  }
}

@Riverpod(keepAlive: true)
class SelectedIconIndex extends _$SelectedIconIndex {
  @override
  int build() => 0;

  void select(int index) => state = index;
  void reset() => state = 0;
}

/// 用户选择的应用名称语言，null 表示使用默认名称
@Riverpod(keepAlive: true)
class SelectedLabelLocale extends _$SelectedLabelLocale {
  @override
  String? build() => null;

  void select(String? locale) => state = locale;
  void reset() => state = null;
}

@Riverpod(keepAlive: true)
class IsParsing extends _$IsParsing {
  @override
  bool build() {
    return false;
  }

  void update(bool isParsing) {
    state = isParsing;
  }
}

/// 当前解析所处的阶段。
///
/// `null` 表示尚未收到任何阶段回报（解析刚开始，或已结束）。UI 据此显示
/// **真实**进度文案 —— 阶段由解析器在真正推进到该步时上报，不是定时器编出来的。
@Riverpod(keepAlive: true)
class ParseStage extends _$ParseStage {
  @override
  ApkParseStage? build() => null;

  void update(ApkParseStage? stage) => state = stage;
}

class FileState {
  final String? filePath;
  final int? fileSize;
  final ApkInfo? apkInfo;
  final String? md5Hash;
  final String? sha1Hash;

  /// 文件 SHA-256。规范 4.1 要求提供。
  final String? sha256Hash;

  final bool isComputingHash;

  /// 签名分析结果。`null` 表示尚未完成，或本次未启用签名检查。
  ///
  /// 存结构化结果而不是一个字符串：验证通过 / 验证失败 / 工具不可用 /
  /// 结果未知这四态对用户的含义完全不同，压成一个字符串就没法区分了。
  final SignatureAnalysis? signature;
  final bool isComputingSignature;

  FileState({
    this.filePath,
    this.fileSize,
    this.apkInfo,
    this.md5Hash,
    this.sha1Hash,
    this.sha256Hash,
    this.isComputingHash = false,
    this.signature,
    this.isComputingSignature = false,
  });

  /// 由当前已到位的各来源结果**派生**的统一分析结果。
  ///
  /// 刻意做成派生而不是单独维护一份状态：哈希、签名、解析是三条并行的异步
  /// 线，任何一条先到都只更新自己那一项，分析结果随之自动反映最新情况 ——
  /// 不需要额外同步，也不会出现「汇总结果与明细不一致」。
  PackageAnalysisResult? get analysis {
    final info = apkInfo;
    if (info == null) return null;

    final sha256 = sha256Hash;
    return AnalysisBuilder.buildAndroid(
      filePath: filePath ?? '',
      fileSize: fileSize ?? 0,
      manifestSource: info.manifestSource,
      hashes: sha256 == null
          ? null
          : FileHashes(
              md5: md5Hash ?? '', sha1: sha1Hash ?? '', sha256: sha256),
      appName: info.label,
      packageId: info.packageName,
      version: info.versionName,
      buildNumber: info.versionCode?.toString(),
      minSdkVersion: info.sdkVersion,
      targetSdkVersion: info.targetSdkVersion,
      maxSdkVersion: info.maxSdkVersion,
      debuggable: info.applicationDebuggable,
      permissions: info.usesPermissions,
      components: info.components,
      hardeningObservations: info.hardeningObservations,
      signature: signature,
    );
  }

  FileState copyWith({
    String? filePath,
    int? fileSize,
    ApkInfo? apkInfo,
    String? md5Hash,
    String? sha1Hash,
    String? sha256Hash,
    bool? isComputingHash,
    SignatureAnalysis? signature,
    bool? isComputingSignature,
  }) {
    return FileState(
      filePath: filePath ?? this.filePath,
      fileSize: fileSize ?? this.fileSize,
      apkInfo: apkInfo ?? this.apkInfo,
      md5Hash: md5Hash ?? this.md5Hash,
      sha1Hash: sha1Hash ?? this.sha1Hash,
      sha256Hash: sha256Hash ?? this.sha256Hash,
      isComputingHash: isComputingHash ?? this.isComputingHash,
      signature: signature ?? this.signature,
      isComputingSignature: isComputingSignature ?? this.isComputingSignature,
    );
  }
}

@Riverpod(keepAlive: true)
class CurrentFileState extends _$CurrentFileState {
  @override
  FileState build() {
    return FileState();
  }

  void update(FileState fileState) {
    state = fileState;
  }

  void updateFilePath(String? filePath) {
    state = state.copyWith(filePath: filePath);
  }

  void updateFileSize(int? fileSize) {
    state = state.copyWith(fileSize: fileSize);
  }
}
