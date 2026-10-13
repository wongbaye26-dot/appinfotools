import 'package:apk_info_tool/apkparser/apk_info.dart';
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
    this.isComputingHash = false,
    this.signature,
    this.isComputingSignature = false,
  });

  FileState copyWith({
    String? filePath,
    int? fileSize,
    ApkInfo? apkInfo,
    String? md5Hash,
    String? sha1Hash,
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
