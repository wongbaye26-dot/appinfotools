import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/apkparser/analysis_builder.dart';
import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/ipaparser/ipa_analysis.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/file_hash.dart';
import 'package:apk_info_tool/utils/ios_codesign_analyzer.dart';
import 'package:apk_info_tool/utils/recent_files.dart';
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

/// IPA 解析当前所处的阶段。
///
/// 与 Android 侧分开成两个 provider，而不是塞进一个「平台 + 阶段」的联合
/// 类型：两条解析流水线的阶段名没有对应关系，硬合并只会让 UI 多写一层
/// 平台分支去还原原本的语义。
@Riverpod(keepAlive: true)
class IosParseStage extends _$IosParseStage {
  @override
  IpaParseStage? build() => null;

  void update(IpaParseStage? stage) => state = stage;
}

/// [FileState.copyWith] 的哨兵值。
///
/// 用来区分「调用方没传这个参数」与「调用方显式传了 null」—— 这是 Dart 里
/// 实现「可置空 copyWith」的标准做法（freezed 生成的代码用的是同一个套路）。
///
/// 代价是参数类型退化成 `Object?`，传错类型会在运行时抛错而不是编译期。
/// 换来的是 `copyWith(filePath: null)` 能真正清空字段，而不是被 `??` 静默忽略。
const Object _unset = Object();

class FileState {
  final String? filePath;
  final int? fileSize;
  final ApkInfo? apkInfo;

  /// iOS 侧的结构化解析结果。`null` 表示本次不是 IPA，或尚未完成。
  final IpaAnalysis? ipaAnalysis;

  /// iOS 侧的 `codesign` 验证结果。
  ///
  /// `null` 表示**没有做**这项检查（非 macOS、设置里关掉了、或解包失败）——
  /// 与「工具不可用」含义不同。UI 必须把这两件事分开显示，否则用户会把
  /// 「我们没查」读成「查不出」。
  final IosCodeSignResult? iosCodeSign;

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

  /// 安全检测分析结果（V1.1）。
  ///
  /// `null` 表示未启用安全检测，或分析尚未完成。
  final SecurityAnalysisResult? securityResult;

  const FileState({
    this.filePath,
    this.fileSize,
    this.apkInfo,
    this.ipaAnalysis,
    this.iosCodeSign,
    this.md5Hash,
    this.sha1Hash,
    this.sha256Hash,
    this.isComputingHash = false,
    this.signature,
    this.isComputingSignature = false,
    this.securityResult,
  });

  /// 当前文件的平台。
  ///
  /// 由**已到位的解析结果**决定，而不是看扩展名 —— 扩展名可以随便改，
  /// 而「解析出的是哪种结构」才是事实。
  PackagePlatform get platform {
    if (ipaAnalysis != null) return PackagePlatform.ios;
    if (apkInfo != null) return PackagePlatform.android;
    return PackagePlatform.unknown;
  }

  /// 由当前已到位的各来源结果**派生**的统一分析结果。
  ///
  /// 刻意做成派生而不是单独维护一份状态：哈希、签名、解析是三条并行的异步
  /// 线，任何一条先到都只更新自己那一项，分析结果随之自动反映最新情况 ——
  /// 不需要额外同步，也不会出现「汇总结果与明细不一致」。
  PackageAnalysisResult? get analysis {
    final ios = ipaAnalysis;
    if (ios != null) {
      final sha256 = sha256Hash;
      return AnalysisBuilder.buildIos(
        filePath: filePath ?? '',
        fileSize: fileSize ?? 0,
        hashes: sha256 == null
            ? null
            : FileHashes(
                md5: md5Hash ?? '', sha1: sha1Hash ?? '', sha256: sha256),
        analysis: ios,
        codeSign: iosCodeSign,
        security: securityResult,
        // 诊断必须传上来。此前漏了这一句，于是详情页的「解析诊断」卡片与
        // 导出的报告里**永远**是空的 —— 而 iOS 侧其实产出了几十条诊断
        // （Info.plist 解析、图标定位、Mach-O、描述文件…）。
        // 「读不到」与「没有可说的」必须分得开，这条链路断在这里就等于
        // 把前者说成了后者。
        diagnostics: ios.allDiagnostics,
      );
    }

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
      // 空结构等于「没收集到」，传 null 而不是一个空对象，
      // 免得下游把「没数据」渲染成「有数据但全是 0」。
      structure: info.structure.fileEntryCount == 0 ? null : info.structure,
      signature: signature,
      security: info.securityResult,
    );
  }

  /// 生成副本。
  ///
  /// 所有参数默认 [_unset]：**不传**表示保留原值，**显式传 `null`** 表示清空。
  /// 旧的 `??` 写法无法表达「清空」，切文件时可能留下上一个文件的残留值。
  FileState copyWith({
    Object? filePath = _unset,
    Object? fileSize = _unset,
    Object? apkInfo = _unset,
    Object? ipaAnalysis = _unset,
    Object? iosCodeSign = _unset,
    Object? md5Hash = _unset,
    Object? sha1Hash = _unset,
    Object? sha256Hash = _unset,
    Object? isComputingHash = _unset,
    Object? signature = _unset,
    Object? isComputingSignature = _unset,
    Object? securityResult = _unset,
  }) {
    return FileState(
      filePath:
          identical(filePath, _unset) ? this.filePath : filePath as String?,
      fileSize: identical(fileSize, _unset) ? this.fileSize : fileSize as int?,
      apkInfo: identical(apkInfo, _unset) ? this.apkInfo : apkInfo as ApkInfo?,
      ipaAnalysis: identical(ipaAnalysis, _unset)
          ? this.ipaAnalysis
          : ipaAnalysis as IpaAnalysis?,
      iosCodeSign: identical(iosCodeSign, _unset)
          ? this.iosCodeSign
          : iosCodeSign as IosCodeSignResult?,
      md5Hash: identical(md5Hash, _unset) ? this.md5Hash : md5Hash as String?,
      sha1Hash:
          identical(sha1Hash, _unset) ? this.sha1Hash : sha1Hash as String?,
      sha256Hash: identical(sha256Hash, _unset)
          ? this.sha256Hash
          : sha256Hash as String?,
      isComputingHash: identical(isComputingHash, _unset)
          ? this.isComputingHash
          : isComputingHash as bool,
      signature: identical(signature, _unset)
          ? this.signature
          : signature as SignatureAnalysis?,
      isComputingSignature: identical(isComputingSignature, _unset)
          ? this.isComputingSignature
          : isComputingSignature as bool,
      securityResult: identical(securityResult, _unset)
          ? this.securityResult
          : securityResult as SecurityAnalysisResult?,
    );
  }

  /// 值语义比较。
  ///
  /// Riverpod 的 `updateShouldNotify` 默认就是 `previous != next`，因此实现
  /// `==` 能直接省掉「内容没变却通知监听者」的多余重建。
  ///
  /// [apkInfo]、[ipaAnalysis]、[iosCodeSign] 与 [signature] 用 `identical`
  /// 比较：它们是体积不小、且**没有**值语义的可变对象，两个内容相同但实例
  /// 不同的解析结果仍然是两次不同的解析，按引用比较才是诚实的。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FileState &&
          other.filePath == filePath &&
          other.fileSize == fileSize &&
          identical(other.apkInfo, apkInfo) &&
          identical(other.ipaAnalysis, ipaAnalysis) &&
          identical(other.iosCodeSign, iosCodeSign) &&
          other.md5Hash == md5Hash &&
          other.sha1Hash == sha1Hash &&
          other.sha256Hash == sha256Hash &&
          other.isComputingHash == isComputingHash &&
          identical(other.signature, signature) &&
          other.isComputingSignature == isComputingSignature &&
          identical(other.securityResult, securityResult);

  @override
  int get hashCode => Object.hash(
        filePath,
        fileSize,
        identityHashCode(apkInfo),
        identityHashCode(ipaAnalysis),
        identityHashCode(iosCodeSign),
        md5Hash,
        sha1Hash,
        sha256Hash,
        isComputingHash,
        identityHashCode(signature),
        isComputingSignature,
        identityHashCode(securityResult),
      );
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

/// 最近文件列表。
///
/// 让数据本身成为 provider，而不是「概览页直接读 `Config` + 别处手动
/// bump 一个版本号」：
/// - 概览页常驻 `IndexedStack`，不会自己重建，读 `Config` 只会拿到首次
///   构建时的快照（表现为「分析完了统计还是 0」）；
/// - 写入方更新 state，读方 `ref.watch` 即可，不存在忘记通知的路径。
@Riverpod(keepAlive: true)
class RecentFiles extends _$RecentFiles {
  @override
  List<RecentFileEntry> build() => RecentFilesManager.load();

  Future<void> add(String path, int size, {String? platform}) async {
    await RecentFilesManager.add(path, size, platform: platform);
    state = RecentFilesManager.load();
  }

  Future<void> clear() async {
    await RecentFilesManager.clear();
    state = const [];
  }
}

/// 跨页面的「打开这个文件」请求。
///
/// 概览页（拖放 / 选择文件 / 最近文件）与分析页位于不同的 widget 子树，
/// 而真正触发解析的 `openApk` 是 `APKInfoPage` 的内部方法 —— 概览页够不到。
///
/// 这里用一次性请求做桥：发起方写入路径并导航到分析页，分析页在
/// `ref.listen` 里收到后调用自己的 `openApk`，随后立刻清空。
///
/// **刻意不在概览页复制一份解析逻辑**：任务句柄、阶段回调、取消、
/// 代际计数（`_loadGeneration`）这些状态只存在于分析页，复制一份出来
/// 迟早会对不上 —— 那正是「导入后没反应」这个 bug 的成因。
@Riverpod(keepAlive: true)
class PendingOpenRequest extends _$PendingOpenRequest {
  @override
  String? build() => null;

  void request(String filePath) => state = filePath;

  /// 取走请求并清空，避免同一次请求被重复触发。
  String? consume() {
    final path = state;
    state = null;
    return path;
  }
}
