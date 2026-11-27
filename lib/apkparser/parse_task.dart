import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:isolate';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/utils/cancellable_task.dart';
import 'package:apk_info_tool/utils/content_digest.dart';
import 'package:apk_info_tool/utils/logger.dart';
import 'package:apk_info_tool/utils/official_baseline_store.dart';
import 'package:apk_parser/apk_parser.dart';

/// APK 解析任务发出的事件。
///
/// 事件按顺序到达，且只会以 [ParseSucceeded]、[ParseFailed]、
/// [ParseOpenFailed] 或 [ParseCancelled] 之一收尾。
sealed class ParseEvent {
  const ParseEvent();
}

/// 解析推进到了某个阶段。
class ParseStageReached extends ParseEvent {
  final ApkParseStage stage;

  const ParseStageReached(this.stage);
}

/// 归档容器打开失败 —— 携带可本地化的具体原因。
class ParseOpenFailed extends ParseEvent {
  final ArchiveOpenResult result;

  /// 命中解压预算时的**具体原因**（哪个条目、多少字节、上限多少）。
  ///
  /// 只在 [ArchiveOpenResult.resourceBudgetExceeded] 时非空。界面把它作为
  /// 第二行显示 —— 只说「超出安全解压上限」，用户既不知道是哪一条超的，
  /// 也无法判断这是不是自己那个包本身有问题。
  final String? detail;

  const ParseOpenFailed(this.result, {this.detail});
}

/// 解析失败，[reason] 面向诊断（英文，直接进日志）。
/// 解析失败。
///
/// [security] 是 **Manifest 读不出来时仍然产出的审计结果** —— 里面只有
/// 局限说明（「Manifest 未解析，权限与组件审计无法进行」），没有发现项。
///
/// 带上它是为了让界面能区分「没查到」与「没查」：不带的话安全 Tab 一片
/// 空白，用户会以为这个包没有问题 —— 而实际情况是根本没审。
class ParseFailed extends ParseEvent {
  final String reason;
  final SecurityAnalysisResult? security;

  const ParseFailed(this.reason, {this.security});
}

/// 解析成功。
class ParseSucceeded extends ParseEvent {
  final ParsedApkData data;

  const ParseSucceeded(this.data);
}

/// 任务被用户取消。取消之后不会再有其它事件。
class ParseCancelled extends ParseEvent {
  const ParseCancelled();
}

/// 可跨 isolate 传递的解析结果。
///
/// 只装**可发送**的数据。`ApkInfo` 持有 `dart:ui` 的 `Image`，不能跨 isolate
/// 传递，因此图标渲染留在主 isolate —— worker 只做容器解析与资源表解析这类
/// 纯计算，那也正是真正卡住 UI 的部分。
class ParsedApkData {
  final ApkMeta meta;
  final Map<int, ResourceInfo> arscResources;

  /// 容器结构上观察到的加固线索（只描述事实，不含厂商判定）。
  final List<HardeningObservation> hardeningObservations;

  /// 容器结构概览（DEX / SO / ABI / 目录）。
  final ContainerStructure structure;

  /// 安全检测分析结果（V1.1）。
  ///
  /// `null` 表示 worker 未执行安全分析（例如 aapt2 路径）。
  final SecurityAnalysisResult? security;

  /// 资源引用图的环检测结果。
  ///
  /// 在 worker 里顺带算出来，因为 [arscResources] 已经在这里了 ——
  /// 环检测的输入正是它，不需要为了这项检查再遍历一遍整张资源表。
  final ReferenceCycleReport referenceCycles;

  /// 参与符号分析的原生库（`lib/**.so`）名字与字节。
  ///
  /// 只包含**通过预算挑选**的那批（见 `NativeSymbolScanner.selectLibraries`）：
  /// 同一个库只取一个 ABI，超限的库不读。因此这里的数量少于归档里的实际数量。
  final List<NativeLibraryBytes> nativeLibraries;

  /// worker 内部各阶段的耗时（毫秒）。
  ///
  /// **为什么要在结果里回传**：worker 是独立 isolate，`log` 的监听器
  /// 只注册在主 isolate 上 —— worker 里写日志既不到控制台也不到文件。
  /// 而「解析慢」恰恰只能在 worker 内部拆开看：外层的
  /// `[PERF] getApkInfo(builtin)` 只有一个 total 和一个 icon，
  /// 分不清慢在解压、DEX 扫描还是封签校验。
  ///
  /// 键是稳定的英文标识（`open` / `parse` / `dex` / `seal` / `audit` …），
  /// 只进日志，不进界面，因此不需要本地化。
  final Map<String, int> stageTimings;

  const ParsedApkData({
    required this.meta,
    required this.arscResources,
    this.hardeningObservations = const [],
    this.structure = const ContainerStructure(),
    this.security,
    this.referenceCycles = const ReferenceCycleReport(),
    this.nativeLibraries = const [],
    this.stageTimings = const {},
  });
}

/// 一次在独立 isolate 中执行的 APK 解析任务。
///
/// 存在的理由有两条，且缺一不可：
/// - **不冻结 UI**：解析（ZIP 解压 + 完整 `resources.arsc` 遍历）是同步 CPU
///   密集计算，跑在主 isolate 上会让大 APK 冻住整个界面。
/// - **真能取消**：`Isolate.run` 无法中断，只能把结果丢掉。这里持有
///   `Isolate` 句柄，[cancel] 是真正的终止。
class ApkParseTask implements CancellableParseTask {
  /// 解析过程的事件流。
  final Stream<ParseEvent> events;

  final ReceivePort _receive;
  final StreamController<ParseEvent> _controller;

  Isolate? _isolate;
  bool _finished = false;

  ApkParseTask._(this._receive, this._controller) : events = _controller.stream;

  /// 启动一次解析。返回后 worker isolate 已在运行。
  static Future<ApkParseTask> start(
    String filePath, {
    OfficialBaselineDb? baselineDb,
  }) async {
    final receive = ReceivePort();
    final controller = StreamController<ParseEvent>();
    final task = ApkParseTask._(receive, controller);

    receive.listen((message) {
      if (message is ParseEvent) task._handle(message);
    });

    final isolate = await Isolate.spawn(
      _parseEntryPoint,
      _ParseRequest(
        reply: receive.sendPort,
        filePath: filePath,
        baselineDb: baselineDb,
      ),
    );
    task._isolate = isolate;

    // 极小概率：在 spawn 完成之前就被取消了。
    if (task._finished) {
      isolate.kill(priority: Isolate.immediate);
    }
    return task;
  }

  /// 取消解析。
  ///
  /// 用 [Isolate.immediate] 而不是默认的 `beforeNextEvent`：后者要等 worker
  /// 回到事件循环才生效，而 worker 的绝大部分时间都耗在一段同步的
  /// `resources.arsc` 解析里 —— 那恰恰是用户想取消的时刻。
  ///
  /// 代价是立即终止不会执行 `finally`，worker 若正持有文件句柄，该句柄要等
  /// 进程退出才释放。这里可以接受：worker 不创建临时文件，句柄也只在解析
  /// 期间短暂存在。**这也是 worker 内不做任何需要显式清理的副作用的原因。**
  @override
  bool get isFinished => _finished;

  @override
  void cancel() {
    if (_finished) return;
    _finished = true;
    _isolate?.kill(priority: Isolate.immediate);
    _emitAndClose(const ParseCancelled());
    _receive.close();
  }

  void _handle(ParseEvent event) {
    if (_finished) return;

    switch (event) {
      case ParseSucceeded() || ParseFailed() || ParseOpenFailed():
        _finished = true;
        _emitAndClose(event);
        _receive.close();
      case ParseStageReached() || ParseCancelled():
        if (!_controller.isClosed) _controller.add(event);
    }
  }

  void _emitAndClose(ParseEvent last) {
    if (_controller.isClosed) return;
    _controller.add(last);
    _controller.close();
  }
}

class _ParseRequest {
  final SendPort reply;
  final String filePath;
  final OfficialBaselineDb? baselineDb;

  const _ParseRequest({
    required this.reply,
    required this.filePath,
    required this.baselineDb,
  });
}

/// worker isolate 的入口。
///
/// 是 async 函数：`Isolate.spawn` 的入口在第一个 `await` 处返回并不会让
/// isolate 提前结束，它会一直活到异步工作结束（已用探针测试确认）。
///
/// **不要在这里创建临时文件或持有需要显式释放的资源** —— [ApkParseTask.cancel]
/// 用的是立即终止，`finally` 不保证执行。
void _parseEntryPoint(_ParseRequest request) async {
  final reader = ApkReader();
  // 各段耗时。只回传给主 isolate 打日志（见 `ParsedApkData.stageTimings`）——
  // worker 里写日志没有监听器，写了也看不到。
  final timings = <String, int>{};
  try {
    request.reply.send(const ParseStageReached(ApkParseStage.openContainer));

    final openSw = Stopwatch()..start();
    final openResult = await reader.open(request.filePath);
    timings['open'] = openSw.elapsedMilliseconds;
    if (!openResult.isOk) {
      request.reply.send(
        ParseOpenFailed(openResult, detail: reader.budgetFailure),
      );
      return;
    }

    final parseSw = Stopwatch()..start();
    final meta = await reader.parse(
      onStage: (stage) => request.reply.send(ParseStageReached(stage)),
    );
    timings['parse'] = parseSw.elapsedMilliseconds;
    if (meta == null) {
      // Manifest 读不出来时**仍然跑一次审计**，把「没查」明确说出来。
      // 早先这里只回一个 reason，界面上安全 Tab 就是一片空白 —— 用户分不清
      // 「没查到问题」与「根本没审」，而这两件事的结论完全相反。
      //
      // 原因取 `reader.manifestFailure`：它区分「归档里没有这个文件」与
      // 「有，但解析失败」—— 后者说明包被做过手脚，措辞不该和前者一样。
      final reason =
          reader.manifestFailure ?? 'AndroidManifest.xml missing or unreadable';
      final failedSecurity = AndroidSecurityAudit.audit(
        meta: ApkMeta(),
        dexEntries: const [],
        manifestParsed: false,
        manifestFailureReason: reason,
        containerAnomalyNotes: [
          for (final obs in reader.scanHardeningSignals()) obs.asNote,
          if (reader.structureAnomaly case final anomaly?)
            AnalysisNote(
              'android.container.structure_anomaly',
              anomaly,
              {'anomaly': anomaly},
            ),
        ],
      );
      request.reply.send(ParseFailed(reason, security: failedSecurity));
      return;
    }

    // Phase E：官方基线匹配（包名 + 证书 SHA-256）。
    final certificate = meta.signingSchemes?.signingCertificate;
    final certSha256 =
        certificate == null ? null : contentDigest('sha256', certificate);
    final baseline = OfficialBaselineStore.matchAndroid(
      request.baselineDb,
      packageId: meta.packageName,
      actualCertSha256: [if (certSha256 != null) certSha256],
    );

    // 安全分析：提取 DEX 字节并在 worker 中完成审计。
    // 这里不创建临时文件，只读内存中的 ZIP 条目，因此即使
    // [Isolate.immediate] 终止，也不会留下垃圾。
    final dexSw = Stopwatch()..start();
    final dexEntries = <DexBytes>[
      for (final name in reader.listFiles(extension: '.dex'))
        if (reader.readFile(name) case final bytes?) DexBytes(name, bytes),
    ];
    timings['dex'] = dexSw.elapsedMilliseconds;

    // 资源表只遍历一次：环检测与图标渲染器都用这一份。
    final arscSw = Stopwatch()..start();
    final arscResources =
        reader.arscParser?.getAllResources() ?? const <int, ResourceInfo>{};
    final resourceStrings = _collectResourceStrings(reader);
    timings['resources'] = arscSw.elapsedMilliseconds;

    // Phase B 事实层：清单、加载链、载荷探测。三者都只读目录/有界头部，
    // 不执行、不解压额外内容；放在 worker 里做，避免新增 UI 卡顿。
    final factsSw = Stopwatch()..start();
    final entryFacts = reader.entryFacts();
    final artifactInventory = AndroidArtifactInventoryScanner.scan(entryFacts);
    timings['facts'] = factsSw.elapsedMilliseconds;
    // ---- 三段独立扫描并行跑 ----
    //
    // 这三段的输入相同、输出互不依赖，串行只是实现上的顺手：
    // - 方法扫描（`methodScan`）：加载链与审计共用；
    // - 字符串线索扫描（`clueScan`）：`audit` 内部原本自己再算一遍；
    // - v2/v3 内容摘要（`seal`）：整包 SHA-256，纯 IO + CPU。
    //
    // 真实大包（68.8 MB / 2 个 DEX）上三者串行约 1.7 s，是「打开一个包要等
    // 多久」的主要部分。并行只是把同一批函数换个地方跑，**输入输出完全不变**。
    //
    // **核数不足或扫描量太小都退回串行**：每个子 isolate 都要复制一份 DEX
    // 字节并付出一次启动开销（Windows 上单次 20–30 ms）。9 MB 的小包上
    // 实测净收益只有 40 ms，再小就变成负的；大包上才有意义。
    //
    // **已知代价**：`ApkParseTask.cancel` 用 `Isolate.immediate` 终止 worker，
    // 而 worker 派生的子 isolate 不会被连带杀掉 —— 它们会把自己那段扫完
    // （受 DEX 扫描预算约束，通常一两秒）才退出。取消后结果不再被采用，
    // 只是多烧一点 CPU。
    final ocrMarkerIds = {
      for (final marker in codeMarkers)
        if (marker.category == SecurityCategory.ocrImage) marker.id,
    };
    final parallelIsolates = Platform.numberOfProcessors >= 3 &&
        dexEntries.fold<int>(0, (sum, e) => sum + e.bytes.length) >=
            4 * 1024 * 1024;
    final scanSw = Stopwatch()..start();
    late final DexMethodScanResult methodScan;
    late final DexScanResult clueScan;
    SealCheck? seal;
    if (parallelIsolates) {
      final results = await Future.wait<Object?>([
        _scanMethodRefsInIsolate(dexEntries, ocrMarkerIds),
        _scanClueStringsInIsolate(dexEntries),
        _sealV2V3InIsolate(request.filePath, meta.signingSchemes),
      ]);
      methodScan = results[0] as DexMethodScanResult;
      clueScan = results[1] as DexScanResult;
      seal = results[2] as SealCheck?;
    } else {
      methodScan = DexMethodScanner.scan(
        dexEntries,
        deepChainFrom: ocrMarkerIds,
        deepChainTo: AndroidSecurityAudit.uploadMarkerIds,
      );
      clueScan = DexClueScanner.scan(dexEntries);
      seal = _checkSealV2V3(request.filePath, meta.signingSchemes);
    }
    // v1 兜底必须在**本 isolate**：它要读归档条目，而 `Archive` 不可跨
    // isolate 传递。
    seal ??= _checkSealV1(reader);
    timings['scan'] = scanSw.elapsedMilliseconds;
    timings['parallelIsolates'] = parallelIsolates ? 1 : 0;

    final loadGraph = AndroidLoadGraphScanner.scan(
      dexEntries: dexEntries,
      inventory: artifactInventory,
      methodScan: methodScan,
    );
    final payloadProbe = _probePayloads(reader, artifactInventory);

    // 原生库：**先按声明尺寸挑，再读** —— 读进来才知道大小就已经晚了。
    // `selectLibraries` 会按库名去重（同一个库只取一个 ABI）、跳过超大库、
    // 并受数量与总体积上限约束；被跳过的都会记进覆盖范围说明。
    final nativeSw = Stopwatch()..start();
    final nativeCandidates = reader.listFilesWithSize(extension: '.so');
    final nativeSelection =
        NativeSymbolScanner.selectLibraries(nativeCandidates);
    final nativeLibraries = <NativeLibraryBytes>[
      for (final name in nativeSelection.selected)
        if (reader.readFile(name) case final bytes?)
          NativeLibraryBytes(name, bytes),
    ];
    timings['native'] = nativeSw.elapsedMilliseconds;

    // 容器结构扫描**只做一次**：它要遍历整张条目表（几千条），而
    // `AndroidSecurityAudit.audit` 与结果对象都要用它。此前这里调了两次
    // `scanHardeningSignals()`，同一份结果算两遍。
    final hardeningObservations = reader.scanHardeningSignals();

    final auditSw = Stopwatch()..start();
    final security = AndroidSecurityAudit.audit(
      meta: meta,
      dexEntries: dexEntries,
      manifestParsed: !meta.manifestUnparsed,
      manifestFailureReason: meta.manifestParseFailure,
      containerAnomalyNotes: [
        for (final obs in hardeningObservations) obs.asNote,
        // 结构异常（EOCD 声明的条目数与实际不符）也要进覆盖说明 ——
        // 「这个包的结构与声明对不上」直接影响本次结论的可信范围。
        if (reader.structureAnomaly case final anomaly?)
          AnalysisNote(
            'android.container.structure_anomaly',
            anomaly,
            {'anomaly': anomaly},
          ),
      ],
      nativeEntries: nativeLibraries,
      // 覆盖率口径要「包里有几个唯一库」，不是「传进来几个」。
      nativeLibraryTotal:
          NativeSymbolScanner.uniqueLibraryCount(nativeCandidates),
      nativeSkipped: nativeSelection.skipped,
      // 资源表覆盖量用**实际读到的条目数**。`arscParser == null` 表示没读到
      // （文件不存在 / 被预算拒绝 / 解析失败），此时传 `null` 让它标「缺失」；
      // 解析成功但表是空的，传 0，措辞是「空表」而不是「缺失」。
      arscEntryCount: reader.arscParser == null ? null : arscResources.length,
      resourceStrings: resourceStrings,
      artifacts: artifactInventory,
      loadGraph: loadGraph,
      payloadProbe: payloadProbe,
      methodScanResult: methodScan,
      // 字符串线索扫描已经在上面的并行段里算过 —— 不传的话 `audit` 会
      // 自己再扫一遍（那是它此前唯一的行为，也是这轮要省掉的那一遍）。
      clueScan: clueScan,
      seal: seal,
      baseline: baseline,
    );
    timings['audit'] = auditSw.elapsedMilliseconds;

    request.reply.send(ParseSucceeded(ParsedApkData(
      meta: meta,
      arscResources: arscResources,
      hardeningObservations: hardeningObservations,
      structure: reader.collectStructure(),
      security: security,
      // 环检测的输入就是 arscResources，顺手算掉 —— 不为了这项检查再遍历
      // 一遍整张资源表。
      referenceCycles: ResourceReferenceGraph.findCycles(arscResources),
      nativeLibraries: nativeLibraries,
      stageTimings: timings,
    )));
  } catch (e) {
    log.warning('ApkParseTask: worker failed: $e');
    request.reply.send(ParseFailed('$e'));
  } finally {
    reader.close();
  }
}

/// v2 / v3 内容摘要校验 —— **可跨 isolate**（只依赖路径与签名块）。
///
/// 拆出来是为了能跟方法扫描、字符串扫描并行跑：整包 SHA-256 在 68.8 MB
/// 样本上要 461 ms，串行时它纯粹是在等。
///
/// 返回 `null` 表示没有可用的 v2/v3 块（或块读失败），调用方据此退回 v1。
SealCheck? _checkSealV2V3(String path, ApkSigningSchemes? schemes) {
  if (schemes != null && schemes.hasV2 && schemes.v2Value != null) {
    RandomAccessFile? raf;
    try {
      raf = File(path).openSync();
      final length = raf.lengthSync();
      return ApkSealCheck.checkV2(
        schemes: schemes,
        fileLength: length,
        digest: contentDigest,
        read: (offset, count) {
          if (offset < 0 || count <= 0 || offset + count > length) {
            return Uint8List(0);
          }
          raf!.setPositionSync(offset);
          return raf.readSync(count);
        },
      );
    } catch (_) {
      // v2 读失败不阻断解析：尝试 v3，再退回 v1。
    } finally {
      raf?.closeSync();
    }
  }
  if (schemes != null &&
      (schemes.hasV3 || schemes.hasV31) &&
      schemes.v3Value != null) {
    RandomAccessFile? raf;
    try {
      raf = File(path).openSync();
      final length = raf.lengthSync();
      return ApkSealCheck.checkV3(
        schemes: schemes,
        fileLength: length,
        digest: contentDigest,
        read: (offset, count) {
          if (offset < 0 || count <= 0 || offset + count > length) {
            return Uint8List(0);
          }
          raf!.setPositionSync(offset);
          return raf.readSync(count);
        },
      );
    } catch (_) {
      // 尝试 v1。
    } finally {
      raf?.closeSync();
    }
  }
  return null;
}

/// v1（`META-INF/MANIFEST.MF`）兜底校验。
///
/// **必须在持有归档的那个 isolate 里跑**：它要读归档条目，而 `Archive`
/// 不可跨 isolate 传递。
SealCheck? _checkSealV1(ApkReader reader) {
  final archive = reader.archive;
  if (archive == null) return null;
  return ApkSealCheck.check(archive: archive, digest: contentDigest);
}

/// 在独立 isolate 里跑方法扫描。
///
/// **必须是顶层函数，不能写成内联闭包**：闭包会连同它所在作用域一起被发送，
/// 而同作用域里还有 `ApkReader`（持有归档与文件句柄，不可跨 isolate 传递）。
/// 内联写法在 `perf_probe_apk_test.dart` 里实测会直接抛
/// 「Illegal argument in isolate message」；放在顶层，作用域里只有参数。
Future<DexMethodScanResult> _scanMethodRefsInIsolate(
  List<DexBytes> dexEntries,
  Set<String> ocrMarkerIds,
) {
  return Isolate.run(() => DexMethodScanner.scan(
        dexEntries,
        deepChainFrom: ocrMarkerIds,
        deepChainTo: AndroidSecurityAudit.uploadMarkerIds,
      ));
}

/// 在独立 isolate 里跑 DEX 字符串线索扫描。理由同上（必须是顶层函数）。
Future<DexScanResult> _scanClueStringsInIsolate(List<DexBytes> dexEntries) {
  return Isolate.run(() => DexClueScanner.scan(dexEntries));
}

/// 在独立 isolate 里做 v2/v3 内容摘要校验。理由同上。
Future<SealCheck?> _sealV2V3InIsolate(
  String path,
  ApkSigningSchemes? schemes,
) {
  return Isolate.run(() => _checkSealV2V3(path, schemes));
}

/// 对 assets 下的代码类条目 / 非标准位置 DEX 做**有界头部**载荷探测。
///
/// 只读声明大小 ≤ 8 MiB 的条目，且最多 64 条；读取后只取前 4 KiB 交给
/// `PayloadProbe`。这是「预算先于读」的同一纪律，避免为探测把整包解开。
///
/// **只解压到 64 KiB 就停**（`readFilePrefix`）：此前用 `readFile` 把整条
/// 条目解压出来再取前 4 KiB，64 条 8 MiB 的资源包因此白解压 512 MiB。
/// `HardeningScanner` 早已改为有界前缀读，这条路径此前漏了。
PayloadProbeResult _probePayloads(
  ApkReader reader,
  ArtifactInventory inventory,
) {
  const maxEntries = 64;
  const maxEntryBytes = 8 * 1024 * 1024;
  const headBytes = 4096;
  const probeBytes = 64 * 1024;
  final inputs = <PayloadProbeInput>[];
  var candidateCount = 0;
  var skipped = 0;
  for (final entry in inventory.entries) {
    final path = entry.path;
    final candidate = path.startsWith('assets/') ||
        entry.kind == ArtifactKind.dex ||
        entry.kind == ArtifactKind.assetArchive ||
        entry.kind == ArtifactKind.assetBinary ||
        entry.kind == ArtifactKind.script;
    if (!candidate) continue;
    candidateCount++;
    // **先计数，再决定要不要读**：调用方 cap 64 不能把「还有候选」藏起来。
    // 否则 `PayloadProbe.scan` 只看到 64 条，会诚实地对它看到的输入报
    // `complete=true`，而报告读者以为整个包都探过了。
    if (inputs.length >= maxEntries) {
      skipped++;
      continue;
    }
    if (entry.sizeBytes <= 0 || entry.sizeBytes > maxEntryBytes) {
      skipped++;
      continue;
    }
    final bytes = reader.readFilePrefix(path, maxBytes: probeBytes);
    if (bytes == null || bytes.isEmpty) {
      skipped++;
      continue;
    }
    final head =
        bytes.length <= headBytes ? bytes : bytes.sublist(0, headBytes);
    final dot = path.lastIndexOf('.');
    inputs.add(PayloadProbeInput(
      path: path,
      // 声明值，与 `PayloadProbe` 的口径一致（中央目录可伪造，信号里
      // 标注来源是「声明」）。
      sizeBytes: entry.sizeBytes,
      headBytes: head,
      declaredExtension: dot > 0 ? path.substring(dot).toLowerCase() : null,
    ));
  }
  final scanned = PayloadProbe.scan(inputs);
  if (skipped == 0 && candidateCount == inputs.length) return scanned;
  return PayloadProbeResult(
    signals: scanned.signals,
    entriesProbed: scanned.entriesProbed,
    entriesTotal: candidateCount,
    complete: false,
    noteCodes: [...scanned.noteCodes, 'payload.candidates_skipped']..sort(),
  );
}

/// `resources.arsc` 全局字符串池 + 文本型 `assets/**` 的字符串。
///
/// 资源表字符串直接来自已经解析好的 StringPool；assets 只读文本型扩展名，
/// 单文件 ≤2 MiB、最多 64 个、总字符 ≤2M，避免把大包拖慢或吃内存。
List<String> _collectResourceStrings(ApkReader reader) {
  final out = <String>[
    ...?reader.arscParser?.globalStringPool?.strings,
  ];
  const textExtensions = {
    '.json',
    '.js',
    '.html',
    '.htm',
    '.txt',
    '.xml',
    '.css',
    '.properties',
    '.csv',
    '.md',
    '.yaml',
    '.yml',
    '.strings',
    '.plist',
    '.conf',
    '.ini',
  };
  var files = 0;
  var chars = out.fold<int>(0, (a, b) => a + b.length);
  for (final entry in reader.listFilesWithSize()) {
    if (files >= 64 || chars >= 2 * 1024 * 1024) break;
    final lower = entry.name.toLowerCase();
    if (!lower.startsWith('assets/') || entry.size <= 0) continue;
    if (entry.size > 2 * 1024 * 1024) continue;
    final dot = lower.lastIndexOf('.');
    if (dot >= 0 && !textExtensions.contains(lower.substring(dot))) continue;
    final bytes = reader.readFile(entry.name);
    if (bytes == null || bytes.isEmpty) continue;
    files++;
    for (final text in Utf8Strings.extract(
      bytes,
      minLength: 2,
      minCjkChars: 2,
    )) {
      if (chars >= 2 * 1024 * 1024) break;
      out.add(text);
      chars += text.length;
    }
    for (final text in Utf16Strings.extract(
      bytes,
      minLength: 2,
      requireWide: true,
    )) {
      if (chars >= 2 * 1024 * 1024) break;
      out.add(text);
      chars += text.length;
    }
  }
  return out;
}
