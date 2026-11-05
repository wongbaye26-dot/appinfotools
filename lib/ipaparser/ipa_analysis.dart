import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:archive_safety/archive_safety.dart';
import 'package:archive/archive.dart';
import 'package:ipa_parser/ipa_parser.dart';
import 'package:apk_info_tool/utils/official_baseline_store.dart';

/// IPA 解析推进到的阶段。
///
/// 与 `ApkParseStage` 一样，**只报阶段、不报百分比**：各阶段耗时极不均匀
/// （图标定位几乎是瞬时的，Mach-O 解析取决于可执行文件大小），百分比会是
/// 编出来的。阶段由解析器在真正推进到该步时上报。
enum IpaParseStage {
  /// 打开 ZIP 容器。
  openContainer,

  /// 枚举 bundle（主应用 / 扩展 / Watch / 框架）。
  container,

  /// 解析 `Info.plist`。
  infoPlist,

  /// 定位图标资源。
  icon,

  /// 解析 Mach-O 可执行文件。
  macho,

  /// 读取签名材料与描述文件。
  signature,

  /// 完成。
  done,
}

/// 一个 IPA 的解析结果（**不含**任何需要外部工具的部分）。
///
/// 全部字段都是普通数据，可以跨 isolate 传递 —— worker 与主 isolate 用的是
/// 同一个类型，不存在两套模型。
///
/// 这里只装**静态**结果：签名材料「有什么」在这里，签名「是否有效」不在。
/// 后者由 `codesign` 得出（见 `IosCodeSignAnalyzer`），刻意分开是因为
/// 规范 5.5 要求两者不得混为一谈。
class IpaAnalysis {
  final IpaContainer container;

  /// 主应用 bundle。没有 `Payload/*.app` 时为 `null`。
  final IosBundle? mainApp;

  /// 主应用的 `Info.plist` 字段。
  final IpaInfoPlist? infoPlist;

  /// 图标定位结果。
  final IosIconResolution? icon;

  /// 主可执行文件的 Mach-O 解析结果。
  final MachOFile? executable;

  /// 主可执行文件在归档中的条目名；取不到时为 `null`。
  final String? executablePath;

  /// 主可执行文件的原始字节（用于安全检测的字符串扫描）。
  ///
  /// `null` 表示文件不存在或超过体积上限（64 MiB）。
  final Uint8List? executableBytes;

  /// 主应用的签名材料。
  final IosSignatureMaterials? signature;

  /// 应用声明与描述文件授权的比较。无法比较时为 `null`。
  final IosAuthorizationComparison? authorization;

  /// 嵌套 bundle 的 Mach-O（扩展 / Watch / 框架）。
  ///
  /// 只解析**顶层镜像**，不做递归展开：一个 IPA 里可能有几十个框架，
  /// 全解析会让「打开一个包」变成一次重型操作，而用户关心的是主应用。
  final List<IosNestedBinary> nestedBinaries;

  /// 容器里**含代码**（framework / app extension / watch app / 嵌套 app）的
  /// bundle 总数，不含主应用。
  ///
  /// 与 [nestedBinaries]`.length` 不是一回事：后者是**实际解析**的个数，受
  /// [IpaAnalysisReader.maxNestedBinaries] 限制。覆盖率的分母必须用这个数 ——
  /// 用后者会把「24 个里扫了 24 个」显示成「全包已覆盖」，而实测的真实样本
  /// （`sun_signed.ipa`）有 27 个含代码的嵌套 bundle，只解析了 24 个。
  ///
  /// 手工构造的 [IpaAnalysis]（测试、降级路径）可以留 `0`：消费方会取
  /// `max(这个值, nestedBinaries.length)`，不会因此算出比实际更小的分母。
  final int nestedBundleTotal;

  /// 主应用 bundle 的目录布局事实（重打包判据的输入）。
  ///
  /// 手工构造时留 [IpaLayoutFacts.empty]：那表示「没算过」，审计据此
  /// **不产出** `IOS-REPACKAGED`，而不是编一个「布局正常」的结论。
  final IpaLayoutFacts layout;

  /// 安全审计结果（Phase C-3 起在 worker 内计算）。
  ///
  /// `null` = 本次未执行安全审计（`securityAudit: false` 或旧的手工构造）；
  /// 不表示「没有风险」。
  final SecurityAnalysisResult? security;

  final List<AnalysisDiagnostic> diagnostics;

  const IpaAnalysis({
    required this.container,
    this.mainApp,
    this.infoPlist,
    this.icon,
    this.executable,
    this.executablePath,
    this.executableBytes,
    this.signature,
    this.authorization,
    this.nestedBinaries = const [],
    this.nestedBundleTotal = 0,
    this.layout = IpaLayoutFacts.empty,
    this.security,
    this.diagnostics = const [],
  });

  /// 全部诊断（含各子解析器的）。
  ///
  /// 汇总顺序固定为「容器 → Info.plist → 图标 → Mach-O → 签名材料」，
  /// 与解析推进顺序一致，用户读到的顺序就是解析发生的顺序。
  List<AnalysisDiagnostic> get allDiagnostics => [
        ...diagnostics,
        ...?infoPlist?.diagnostics,
        ...?icon?.diagnostics,
        ...?executable?.diagnostics,
        for (final nested in nestedBinaries) ...?nested.macho?.diagnostics,
        ...?signature?.diagnostics,
      ];

  bool get hasMainApp => mainApp != null;

  /// 带上安全审计结果的新副本。
  ///
  /// 两阶段解析用：先构造 `security == null` 的 [IpaAnalysis] 让 UI 立刻显示
  /// 静态结果，审计完成后再用本方法补上 `security`，不重新解析归档。
  IpaAnalysis copyWithSecurity(SecurityAnalysisResult? security) => IpaAnalysis(
        container: container,
        mainApp: mainApp,
        infoPlist: infoPlist,
        icon: icon,
        executable: executable,
        executablePath: executablePath,
        executableBytes: executableBytes,
        signature: signature,
        authorization: authorization,
        nestedBinaries: nestedBinaries,
        nestedBundleTotal: nestedBundleTotal,
        layout: layout,
        security: security,
        diagnostics: diagnostics,
      );
}

/// 一个嵌套 bundle 里的 Mach-O 概览。
class IosNestedBinary {
  final String bundlePath;
  final IosBundleKind kind;

  /// 可执行文件在归档中的条目名。
  final String path;

  /// 解析结果；无法解析时为 `null`（原因见 [failure]）。
  final MachOFile? macho;

  /// 无法解析的原因。
  final String? failure;

  /// 可执行文件的字节，供安全扫描做字符串线索检查。
  ///
  /// `null` 有两种可能，**必须分开**：字节没保留下来（超出
  /// [IpaAnalysisReader.maxNestedRetainedBytes] 总预算），或条目本身读不到
  /// （见 [failure]）。原因见 [bytesFailure]。
  ///
  /// 保留字节是**额外**的内存开销：Mach-O 解析本身只需要一次性读完，而
  /// 安全扫描要在解析之后再做，所以必须把字节留住。因此有总预算，
  /// 超出的如实记为未覆盖，而不是悄悄丢掉。
  final Uint8List? bytes;

  /// 字节没能保留的原因；保留成功时为 `null`。
  final String? bytesFailure;

  /// 该 bundle 自己 `Info.plist` 里的用途说明（键 → 值）；读不到时为 `null`。
  ///
  /// 为什么必须逐 bundle 带上：扩展**常常正是**处理照片与 OCR 的地方，
  /// 而主应用的 `Info.plist` 里可能一条相册用途都没有。只看主应用，
  /// 「扩展声明了相册访问」这件事就完全看不见。
  ///
  /// `null` 表示**没读到**（与「读到了但一条都没有」= 空 map 不同）。
  final Map<String, String>? usageDescriptions;

  const IosNestedBinary({
    required this.bundlePath,
    required this.kind,
    required this.path,
    this.macho,
    this.failure,
    this.bytes,
    this.bytesFailure,
    this.usageDescriptions,
  });

  /// 该可执行文件是否**参与安全扫描**（字节在手上）。
  bool get isScannable => bytes != null && bytes!.isNotEmpty;

  /// 全部架构名。
  List<String> get architectures => [
        for (final image in macho?.images ?? const <MachOImage>[])
          image.architectureName,
      ];

  /// 无法解析的原因；成功时为 `null`。
  String? get failureReason => failure ?? (macho == null ? 'not parsed' : null);

  @override
  String toString() => 'IosNestedBinary($path, ${architectures.join('/')})';
}

/// 对一个**已打开的** IPA 归档做静态解析。
///
/// 不解压到磁盘、不执行任何外部命令，因此这一层没有路径穿越面，也可以安全地
/// 放进 worker isolate（`Isolate.immediate` 终止不会留下任何东西）。
class IpaAnalysisReader {
  IpaAnalysisReader._();

  /// 解析嵌套 bundle 的 Mach-O 数量上限。
  ///
  /// 只影响展示用的清单；超过之后不再解析并记一条诊断，而不是把整个解析
  /// 拖成几十秒。
  static const int maxNestedBinaries = 24;

  /// 嵌套可执行文件**保留字节**的总预算（32 MiB）。
  static const int maxNestedRetainedBytes = 32 * 1024 * 1024;

  /// 单个 Mach-O 的体积上限（64 MiB）。
  static const int maxMachOBytes = 64 * 1024 * 1024;

  /// 主可执行文件在归档里的路径。
  ///
  /// 由 `CFBundleExecutable` 决定，**不猜文件名**（猜「与 .app 同名」在真实
  /// 应用里经常不成立）。取不到声明时返回 `null`。
  static String? _executablePath(IosBundle bundle, IpaInfoPlist info) {
    final name = info.executable.value;
    if (name == null || name.isEmpty) return null;
    // 声明里带路径分隔符是非法的，宁可拒绝也不去拼一个可疑路径。
    if (name.contains('/') || name.contains('\\')) return null;
    return '${bundle.path}/$name';
  }

  /// 解析嵌套 bundle 的 Mach-O。
  ///
  /// 返回值里的 [total] 是**候选总数**（容器里含代码的 bundle 个数，不含主
  /// 应用），[binaries] 是实际解析的那些 —— 两者在触发数量上限时不同。
  /// 覆盖率的分母必须用 `total`：截断是「我们没看」，不能从分母里消失。
  static ({List<IosNestedBinary> binaries, int total}) _readNestedBinaries(
    Archive archive,
    IpaContainer container,
    IosBundle mainApp,
    List<AnalysisDiagnostic> diagnostics,
    BoundedReadLedger ledger,
  ) {
    // 只列真正「装着代码」的 bundle 类型；`Payload/` 直属的其他 .app 已经
    // 在主应用之外被容器层标记为 nestedApp，这里一并纳入。
    const interesting = {
      IosBundleKind.framework,
      IosBundleKind.appExtension,
      IosBundleKind.watchApp,
      IosBundleKind.nestedApp,
    };

    final candidates = container.bundles
        .where((b) => b.path != mainApp.path && interesting.contains(b.kind))
        .toList();

    final result = <IosNestedBinary>[];
    var retainedBytes = 0;
    var droppedForBudget = 0;
    for (final bundle in candidates) {
      if (result.length >= maxNestedBinaries) {
        // **不许静默截断。** 用户看到一份 24 条的清单，会以为这个包只有
        // 24 个框架 —— 而实测的真实样本有 27 个。截断了就要说出来，
        // 否则清单看起来是完整的。
        diagnostics.add(
          AnalysisDiagnostic.info(
            'ios.nested.truncated',
            'only the first $maxNestedBinaries of ${candidates.length} nested '
                'bundles were parsed',
            source: FieldSource.zipDirectory,
          ),
        );
        break;
      }

      final info = IpaInfoPlistReader.read(archive, bundle, ledger: ledger);
      final path = _executablePath(bundle, info);
      if (path == null) {
        result.add(IosNestedBinary(
          bundlePath: bundle.path,
          kind: bundle.kind,
          path: '',
          failure: 'no usable CFBundleExecutable',
        ));
        continue;
      }

      final bytes = _readEntry(archive, path, maxMachOBytes, ledger);
      if (bytes == null) {
        result.add(IosNestedBinary(
          bundlePath: bundle.path,
          kind: bundle.kind,
          path: path,
          failure: 'entry missing or too large',
        ));
        continue;
      }

      final macho = MachOParser.parse(bytes);
      // 字节是否**保留下来**供安全扫描用，与「能不能解析」是两件事：
      // 解析只需要读一次，扫描要在之后做，因此要把字节留住 —— 但受总预算约束。
      final retain = retainedBytes + bytes.length <= maxNestedRetainedBytes;
      if (retain) {
        retainedBytes += bytes.length;
      } else {
        droppedForBudget++;
      }
      result.add(IosNestedBinary(
        bundlePath: bundle.path,
        kind: bundle.kind,
        path: path,
        macho: macho.isMachO ? macho : null,
        failure: macho.isMachO
            ? null
            : (macho.diagnostics.isEmpty
                ? 'not a Mach-O'
                : macho.diagnostics.first.message),
        bytes: retain ? bytes : null,
        bytesFailure: retain
            ? null
            : 'bytes not retained (nested budget of '
                '${maxNestedRetainedBytes ~/ (1024 * 1024)} MiB reached)',
        usageDescriptions: info.privacyUsageDescriptions.value,
      ));
    }
    if (droppedForBudget > 0) {
      // **不许静默丢字节。** 丢了就意味着这些可执行文件不参与安全扫描，
      // 报告里的覆盖率必须反映出来。
      diagnostics.add(AnalysisDiagnostic.info(
        'ios.nested.bytes_dropped',
        '$droppedForBudget nested executables were parsed but their bytes '
            'were not retained (nested budget of '
            '${maxNestedRetainedBytes ~/ (1024 * 1024)} MiB reached): they are '
            'not covered by the API-usage scan',
        source: FieldSource.zipDirectory,
      ));
    }

    return (binaries: result, total: candidates.length);
  }

  /// 读取归档里的 `.strings` / 本地化文本文件。
  ///
  /// 只读主应用与嵌套 bundle 的 `.strings`，单文件 ≤1 MiB、最多 64 个、
  /// 总量 ≤8 MiB；二进制 plist 不在本方法处理范围。
  static List<IosStringsFile> _readStringsFiles(
    Archive archive,
    BoundedReadLedger ledger,
  ) {
    final out = <IosStringsFile>[];
    var total = 0;
    for (final entry in archive.files) {
      if (out.length >= 64 || total >= 8 * 1024 * 1024) break;
      if (entry.isDirectory) continue;
      final lower = entry.name.toLowerCase();
      if (!lower.endsWith('.strings')) continue;
      if (entry.size <= 0 || entry.size > 1024 * 1024) continue;
      final read = readEntryBounded(
        entry,
        maxEntryBytes: 1024 * 1024,
        ledger: ledger,
      );
      if (!read.isOk || read.bytes == null) continue;
      out.add(IosStringsFile(entry.name, read.bytes!));
      total += read.bytes!.length;
    }
    return out;
  }

  /// 读一个条目，超过 [maxBytes] 时返回 `null`（**逐块中止，不整条分配**）。
  ///
  /// 此前是「先 `entry.content` 全解压、再比长度」—— 声明值撒谎时，那一步
  /// 已经把整条条目读进内存了，比长度只是事后发现。V2.4.12 改为有界读取。
  static Uint8List? _readEntry(
    Archive archive,
    String path,
    int maxBytes,
    BoundedReadLedger ledger,
  ) {
    final entry = archive.findFile(path);
    if (entry == null) return null;
    final read = readEntryBounded(
      entry,
      maxEntryBytes: maxBytes,
      ledger: ledger,
    );
    return read.isOk ? read.bytes : null;
  }

  static IpaAnalysis analyze(
    Archive archive, {
    void Function(IpaParseStage)? onStage,
    void Function(IpaAnalysis analysis)? onParsed,
    bool securityAudit = true,
    ContentDigestFn? digest,
    OfficialBaselineDb? baselineDb,
    bool retainRawBytes = true,

    /// 性能探查用：阶段回调；生产传 `null`。
    void Function(String stage)? onProfileStage,
  }) {
    onProfileStage?.call('start');
    final diagnostics = <AnalysisDiagnostic>[];
    final ledger = BoundedReadLedger.session();

    onStage?.call(IpaParseStage.container);
    final container = IpaContainerReader.read(archive);
    if (!container.hasPayloadDirectory) {
      diagnostics.add(AnalysisDiagnostic.warning(
        'ios.container.no_payload',
        'the archive has no Payload/ directory; this is not a standard IPA',
        source: FieldSource.zipDirectory,
      ));
    }
    if (container.hasMultipleMainApps) {
      diagnostics.add(AnalysisDiagnostic.warning(
        'ios.container.multiple_main_apps',
        'the container holds ${container.payloadApps.length} Payload/*.app '
            'bundles: ${container.payloadApps.map((b) => b.path).join(', ')}',
        messageArgs: {
          'count': container.payloadApps.length,
          'paths': container.payloadApps.map((b) => b.path).join(', '),
        },
        source: FieldSource.zipDirectory,
      ));
    }

    final mainApp = container.mainApp;
    if (mainApp == null) {
      diagnostics.add(const AnalysisDiagnostic.error(
        'ios.container.no_main_app',
        'no Payload/*.app bundle was found',
        source: FieldSource.zipDirectory,
      ));
      return IpaAnalysis(container: container, diagnostics: diagnostics);
    }

    onStage?.call(IpaParseStage.infoPlist);
    final infoPlist = IpaInfoPlistReader.read(archive, mainApp, ledger: ledger);

    onStage?.call(IpaParseStage.icon);
    final icon = IpaIconResolver.resolve(archive, infoPlist, ledger: ledger);

    onStage?.call(IpaParseStage.macho);
    final executablePath = _executablePath(mainApp, infoPlist);
    MachOFile? executable;
    Uint8List? executableBytes;
    if (executablePath == null) {
      diagnostics.add(AnalysisDiagnostic.warning(
        'ios.macho.no_executable_declared',
        '${mainApp.path} does not declare a usable CFBundleExecutable',
        source: FieldSource.infoPlist,
      ));
    } else {
      final bytes = _readEntry(archive, executablePath, maxMachOBytes, ledger);
      executableBytes = bytes;
      if (bytes == null) {
        diagnostics.add(AnalysisDiagnostic.warning(
          'ios.macho.missing',
          '$executablePath is not present or is too large to read',
          source: FieldSource.zipDirectory,
        ));
      } else {
        executable = MachOParser.parse(bytes);
        if (!executable.isMachO) {
          diagnostics.add(AnalysisDiagnostic.warning(
            'ios.macho.unparsable',
            '$executablePath could not be parsed as Mach-O',
            source: FieldSource.machO,
          ));
        }
      }
    }

    onProfileStage?.call('macho:done');
    final nested = _readNestedBinaries(
      archive,
      container,
      mainApp,
      diagnostics,
      ledger,
    );

    onStage?.call(IpaParseStage.signature);
    final signature =
        IpaSignatureMaterialReader.read(archive, mainApp, ledger: ledger);
    final authorization = signature.profile.value == null
        ? null
        : compareIosAuthorization(
            bundleIdentifier: infoPlist.bundleIdentifier,
            profile: signature.profile.value!,
          );

    onProfileStage?.call('nested:done');
    final layoutFacts = IpaLayoutReader.read(archive, mainApp);
    onProfileStage?.call('layout:done');

    // Phase E: official baseline (Bundle ID + Team ID).
    final teamIds =
        signature.profile.value?.teamIdentifiers.value ?? const <String>[];
    final baseline = OfficialBaselineStore.matchIos(
      baselineDb,
      bundleId: infoPlist.bundleIdentifier.value,
      actualTeamIds: teamIds,
    );

    onProfileStage?.call('baseline:done');
    // Phase D: CodeResources digest check.
    SealCheck? seal;
    if (digest != null) {
      seal = IosCodeResourcesCheck.check(
        archive: archive,
        bundle: mainApp,
        digest: digest,
        ledger: ledger,
      );
    }

    onProfileStage?.call('seal:done');
    // Phase B/C-3 facts.
    final entryFacts = <ContainerEntryFact>[
      for (final entry in archive.files)
        ContainerEntryFact(
          path: normalizeArchivePath(entry.name),
          sizeBytes: entry.size,
          isDirectory: entry.isDirectory,
        ),
    ];
    onProfileStage?.call('entry-facts:done');
    final artifacts = IosArtifactInventoryScanner.scan(entryFacts);
    onProfileStage?.call('artifacts:done');
    final machoInputs = <IosMachOInput>[
      if (executable != null && executablePath != null)
        IosMachOInput(path: executablePath, macho: executable),
      for (final nestedBinary in nested.binaries)
        if (nestedBinary.macho != null)
          IosMachOInput(path: nestedBinary.path, macho: nestedBinary.macho!),
    ];
    final loadGraph = IosLoadGraphScanner.scan(
      binaries: machoInputs,
      inventory: artifacts,
      mainBundlePath: mainApp.path,
    );
    onProfileStage?.call('load-graph:done');
    final payloadInputs = <PayloadProbeInput>[];
    for (final artifact in artifacts.entries) {
      if (payloadInputs.length >= 64) break;
      if (artifact.sizeBytes <= 0 || artifact.sizeBytes > 8 * 1024 * 1024) {
        continue;
      }
      if (!(artifact.kind.isCode ||
          artifact.kind == ArtifactKind.assetArchive ||
          artifact.kind == ArtifactKind.assetBinary ||
          artifact.kind == ArtifactKind.script)) {
        continue;
      }
      final file = archive.findFile(artifact.path);
      if (file == null) continue;
      final read = readEntryPrefix(file, maxBytes: 4096, ledger: ledger);
      if (!read.isOk || read.bytes == null) continue;
      final dot = artifact.path.lastIndexOf('.');
      payloadInputs.add(PayloadProbeInput(
        path: artifact.path,
        sizeBytes: artifact.sizeBytes,
        headBytes: read.bytes!,
        declaredExtension:
            dot > 0 ? artifact.path.substring(dot).toLowerCase() : null,
      ));
    }
    final payloadProbe = IosPayloadProbe.scan(payloadInputs);
    onProfileStage?.call('payload:done');

    final baseAnalysis = IpaAnalysis(
      container: container,
      mainApp: mainApp,
      infoPlist: infoPlist,
      icon: icon,
      executable: executable,
      executablePath: executablePath,
      executableBytes: retainRawBytes ? executableBytes : null,
      signature: signature,
      authorization: authorization,
      nestedBinaries: nested.binaries,
      nestedBundleTotal: nested.total,
      layout: layoutFacts,
      security: null,
      diagnostics: diagnostics,
    );
    onParsed?.call(baseAnalysis);
    onProfileStage?.call('base:done');

    SecurityAnalysisResult? securityResult;
    if (securityAudit) {
      securityResult = IosPrivacyAudit.audit(
        infoPlist: infoPlist,
        executableBytes: executableBytes,
        executablePath: executablePath,
        nestedExecutables: [
          for (final nestedBinary in nested.binaries)
            IosNestedExecutableInput(
              path: nestedBinary.path,
              bundlePath: nestedBinary.bundlePath,
              kind: nestedBinary.kind,
              bytes: nestedBinary.bytes,
              failure: nestedBinary.failure ?? nestedBinary.bytesFailure,
              usageDescriptions: nestedBinary.usageDescriptions,
            ),
        ],
        nestedBundleTotal: nested.total,
        entitlements: signature.profile.value?.entitlements ?? const [],
        provisioningProfilePresent: signature.profile.value != null,
        layout: layoutFacts,
        artifacts: artifacts,
        loadGraph: loadGraph,
        payloadProbe: payloadProbe,
        seal: seal,
        baseline: baseline,
        stringsFiles: _readStringsFiles(archive, ledger),
        onStage: onProfileStage,
      );
    }

    onProfileStage?.call('audit:done');
    onStage?.call(IpaParseStage.done);
    return baseAnalysis.copyWithSecurity(securityResult);
  }
}
