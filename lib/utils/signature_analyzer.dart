import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_parser/apk_parser.dart'
    show ApkReader, ApkSigningSchemes, parseApkSigningBlock;
import 'package:apk_info_tool/utils/command_tools.dart';
import 'package:crypto/crypto.dart';
import 'package:ipa_parser/ipa_parser.dart'
    show CmsContentExtractor, X509CertificateInfo, X509Parser;
import 'package:apk_info_tool/utils/java_runtime.dart';
import 'package:apk_info_tool/utils/logger.dart';

/// 重新导出 [SignatureStatus]。
///
/// 这个枚举原先定义在本文件里，iOS 侧需要同一套结论语义，于是上移到
/// `analysis_model`（零依赖、平台无关）。这里保留一次 re-export：凡是拿到
/// [SignatureAnalysis] 的调用方都需要这个类型在作用域内，强迫他们多写一行
/// import 只是噪音。**定义只有一处**，不会再出现两份漂移的副本。
export 'package:analysis_model/analysis_model.dart' show SignatureStatus;

/// 单个签名者的证书信息。
///
/// 字段全部可空：apksigner 的输出随版本变化，缺失的字段保持 `null`，
/// **不做任何推测填充**。例如 `issuer` 不在此列 —— apksigner 只输出
/// certificate DN（即 subject），本项目不自行推断 issuer。
class SignatureSigner {
  /// 签名者序号（apksigner 输出中的 `Signer #N`）。
  final int index;

  /// 证书 subject DN（apksigner 的 `certificate DN`）。
  final String? subjectDn;

  /// 证书 SHA-256 指纹（apksigner 已按 `:` 分组，保持原样）。
  final String? sha256Digest;

  /// 证书 SHA-1 指纹。
  final String? sha1Digest;

  /// 公钥算法，例如 `RSA`、`EC`。
  final String? keyAlgorithm;

  /// 公钥长度（位）。
  final int? keySizeBits;

  /// 证书有效期，形如 `2020-01-01T00:00:00Z -- 2050-01-01T00:00:00Z`。
  /// 旧版 apksigner 不输出该行时为 `null`。
  final String? validity;

  const SignatureSigner({
    required this.index,
    this.subjectDn,
    this.sha256Digest,
    this.sha1Digest,
    this.keyAlgorithm,
    this.keySizeBits,
    this.validity,
  });

  bool get isEmpty =>
      subjectDn == null &&
      sha256Digest == null &&
      sha1Digest == null &&
      keyAlgorithm == null &&
      keySizeBits == null &&
      validity == null;
}

/// 本地读出的一张签名证书。
///
/// 来源只有两处，都是**结构事实**：
/// - v2 / v3 / v3.1：APK Signing Block 里每个签名者的 X.509 DER；
/// - v1：`META-INF/<name>.RSA|.DSA|.EC` 这个 PKCS#7 签名块里的证书集合。
///
/// [details] 是纯解析结果，**不代表证书可信、也不代表签名有效** —— 任何人都
/// 能把一张证书塞进上述两个位置。指纹的用途只有一个：和官方公布的值比对。
class SignatureCertificate {
  /// 来源方案：`v1` / `v2` / `v3` / `v3.1`。
  final String scheme;

  /// 同一方案内的签名者序号；v1 里是证书在 PKCS#7 集合中的顺序。
  final int signerIndex;

  final X509CertificateInfo details;

  const SignatureCertificate({
    required this.scheme,
    required this.signerIndex,
    required this.details,
  });

  /// SHA-256 指纹（小写十六进制，无分隔符），读不出时为 `null`。
  String? get sha256 => details.sha256Fingerprint;

  @override
  String toString() =>
      'SignatureCertificate($scheme #$signerIndex, ${details.subject})';
}

/// `apksigner verify` 的结构化结果。
class SignatureAnalysis {
  final SignatureStatus status;

  /// 验证通过的签名方案，例如 `{'v1', 'v2'}`。仅当 [status] 为
  /// [SignatureStatus.verified] 时有意义。
  final Set<String> verifiedSchemes;

  final List<SignatureSigner> signers;

  /// 进程退出码。工具未执行时为 `null`。
  final int? exitCode;

  /// 工具的原始输出，完整保留以便排查 —— 尤其是验证失败时，
  /// apksigner 的具体原因只出现在这里。
  final String stdout;
  final String stderr;

  /// 失败/未知时的人类可读原因（超时、无法执行等）。
  final String? error;

  /// 是否真的执行了 apksigner。`false` 表示 [SignatureStatus.toolUnavailable]。
  final bool toolExecuted;

  /// **本地**从 v2/v3 签名块读出的签名证书 SHA-256（小写十六进制，无冒号）。
  ///
  /// 存在的理由：没装 apksigner 时，签名结论只能是「无法确认」—— 但
  /// 「这个包由哪张证书签的」是**结构事实**，不需要密码学验证也能读出来。
  /// 用户拿这个指纹就能和官方公布的比对。
  ///
  /// **它不是「签名有效」的证据**：任何人都能把一张证书塞进签名块。
  final String? localCertificateSha256;

  /// 本地读出的全部证书（v2 → v3 → v3.1 → v1，各自按签名者顺序）。
  ///
  /// 与 [localCertificateSha256] 的关系：那个为了兼容旧界面只保留 v2+ 的
  /// 第一张；这里是完整清单，v1 的 PKCS#7 证书也在其中。空表示「一个都没读到」，
  /// **不表示「没有签名」**（可能是没有 v1 证书、也可能读取被预算拒绝）。
  final List<SignatureCertificate> localCertificates;

  const SignatureAnalysis({
    required this.status,
    this.verifiedSchemes = const {},
    this.signers = const [],
    this.exitCode,
    this.stdout = '',
    this.stderr = '',
    this.error,
    this.toolExecuted = false,
    this.localCertificateSha256,
    this.localCertificates = const [],
  });

  /// 工具不可用时的结果。**不是**「签名无效」。
  factory SignatureAnalysis.toolUnavailable(
    String reason, {
    String? localCertificateSha256,
    List<SignatureCertificate> localCertificates = const [],
  }) =>
      SignatureAnalysis(
        status: SignatureStatus.toolUnavailable,
        localCertificateSha256: localCertificateSha256,
        localCertificates: localCertificates,
        error: reason,
      );

  /// 供 UI 直接展示的原始输出（失败时含具体原因）。
  String get rawOutput {
    final parts = <String>[
      if (stderr.trim().isNotEmpty) stderr.trim(),
      if (stdout.trim().isNotEmpty) stdout.trim(),
    ];
    return parts.join('\n');
  }
}

/// 调用 Android SDK Build Tools 的 apksigner 做签名验证。
///
/// 只以 apksigner 的结论为准。**不**通过读取 `META-INF/` 目录来推断
/// 「v1 已通过」—— 那只能说明存在签名材料，不能说明签名有效，更不能
/// 覆盖 v2/v3/v4 方案。
class SignatureAnalyzer {
  /// 执行 `apksigner verify --print-certs --verbose <apk>`。
  ///
  /// [timeout] 默认 120 秒，与 aapt2 路径保持一致。
  static Future<SignatureAnalysis> analyze(
    String apkPath, {
    Duration timeout = const Duration(seconds: 120),
    String? apksignerPath,
  }) async {
    // 先把**结构事实**读出来：不管 apksigner 在不在，证书指纹都是能拿到的。
    final localCert = readLocalCertificateSha256(apkPath);
    final localCertificates = await readLocalCertificates(apkPath);

    final resolved = apksignerPath ?? CommandTools.findApkSignerPath();
    if (resolved == null || resolved.isEmpty) {
      log.info('SignatureAnalyzer: apksigner 不可用，无法得出结论');
      return SignatureAnalysis.toolUnavailable(
        'apksigner not found',
        localCertificateSha256: localCert,
        localCertificates: localCertificates,
      );
    }

    Process process;
    try {
      process = await Process.start(
        resolved,
        ['verify', '--print-certs', '--verbose', apkPath],
        // `apksigner` 是 java 的壳：脚本内部执行的是裸命令 `java`（macOS /
        // Linux）或 `%JAVA_HOME%\bin\java.exe`（Windows 的 .bat）。
        //
        // **只探测到 java 在哪是不够的** —— 用户的 java 常常装了但不在 PATH
        // 里，脚本照样找不到它。这里把 java 的 `bin` 前置到 PATH 并设好
        // `JAVA_HOME`，两条脚本路径就都能走通。没找到 java 时返回空 map，
        // 等于不覆盖父进程环境（`includeParentEnvironment` 默认为 true）。
        environment: JavaRuntime.childEnvironment(),
      );
    } on ProcessException catch (e) {
      // 二进制存在但无法执行（权限、架构不匹配等）—— 仍属「工具不可用」，
      // 而不是「签名无效」。
      log.warning('SignatureAnalyzer: apksigner 无法执行: $e');
      return SignatureAnalysis.toolUnavailable(
        'cannot execute apksigner: $e',
        localCertificateSha256: localCert,
        localCertificates: localCertificates,
      );
    }

    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();
    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .listen(stdoutBuffer.write)
        .asFuture<void>();
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .listen(stderrBuffer.write)
        .asFuture<void>();

    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      // 必须主动结束子进程：只用 `Future.timeout` 只是不再等待，子进程会继续
      // 跑下去，留下孤儿进程占用 CPU 与文件句柄。
      //
      // 终止后**不能**再等 stdout/stderr 关闭 —— 子进程可能还有继承了同一批
      // 管道的孙进程（apksigner 本身是启动 java 的脚本），等下去就等于等它
      // 自然结束。这里直接丢弃两个 future（`.ignore()` 同时抑制未处理异常）。
      //
      // 已知局限：kill 只作用于直接子进程，孙进程可能在超时后继续存活一小段
      // 时间。apksigner 是本地可信工具且超时上限 120s，风险有限；彻底解决需要
      // 进程组级别的终止，Dart 未暴露该能力。
      log.warning('SignatureAnalyzer: apksigner 超时（${timeout.inSeconds}s），已终止');
      process.kill(ProcessSignal.sigkill);
      stdoutDone.ignore();
      stderrDone.ignore();
      return SignatureAnalysis(
        status: SignatureStatus.unknown,
        error: 'apksigner timed out after ${timeout.inSeconds}s',
        toolExecuted: true,
        localCertificateSha256: localCert,
        localCertificates: localCertificates,
      );
    }

    await _drain(stdoutDone);
    await _drain(stderrDone);

    return parseResult(
      exitCode: exitCode,
      stdout: stdoutBuffer.toString(),
      stderr: stderrBuffer.toString(),
      localCertificateSha256: localCert,
      localCertificates: localCertificates,
    );
  }

  /// 从 v2/v3 签名块里读出签名证书的 SHA-256。
  ///
  /// **只读结构，不做密码学校验**。证书是否存在是确定的，签名是否有效不是 ——
  /// 所以这个值只能在「apksigner 跑不了」时作为**替代信息**展示，
  /// 不能替代签名结论。
  ///
  /// 失败一律返回 `null`：读不出指纹不该让签名分析失败。
  static String? readLocalCertificateSha256(String apkPath) {
    final schemes = _readSigningSchemes(apkPath);
    final cert = schemes?.signingCertificate;
    if (cert == null) return null;
    return sha256.convert(cert).toString();
  }

  /// 读出 APK 里全部签名证书：v2/v3/v3.1 来自签名块，v1 来自 `META-INF`。
  ///
  /// **只读结构，不验证任何签名**。读取失败的部分直接缺席（不编造），
  /// 空列表的含义是「一张都没读到」，不是「这个包没签名」。
  ///
  /// v1 的证书藏在 PKCS#7 签名块（`.RSA` / `.DSA` / `.EC`）里，不在 `.SF`
  /// 里；只认 `META-INF` 顶层的条目 —— 子目录下的同名文件不是 JAR 签名材料。
  static Future<List<SignatureCertificate>> readLocalCertificates(
    String apkPath,
  ) async {
    final out = <SignatureCertificate>[];

    // v2 / v3 / v3.1：签名块里每个签名者的每一张证书。
    final schemes = _readSigningSchemes(apkPath);
    if (schemes != null) {
      for (final certificate in schemes.certificates) {
        final details = X509Parser.parse(certificate.der);
        if (details == null) {
          log.warning(
            'SignatureAnalyzer: ${certificate.scheme} 证书无法解析 '
            '(${certificate.der.length} bytes)',
          );
          continue;
        }
        out.add(SignatureCertificate(
          scheme: certificate.scheme,
          signerIndex: certificate.signerIndex,
          details: details,
        ));
      }
    }

    // v1：PKCS#7 里可能是一张或多张证书。
    final reader = ApkReader();
    try {
      await reader.open(apkPath);
      final names = <String>[
        ...reader.listFiles(extension: '.rsa'),
        ...reader.listFiles(extension: '.dsa'),
        ...reader.listFiles(extension: '.ec'),
      ].where(_isTopLevelMetaInf).toList()
        ..sort();
      for (final name in names) {
        final bytes = reader.readFile(name);
        if (bytes == null || bytes.isEmpty) continue;
        final cms = CmsContentExtractor.extractCertificates(bytes);
        for (var i = 0; i < cms.certificates.length; i++) {
          out.add(SignatureCertificate(
            scheme: 'v1',
            signerIndex: i,
            details: cms.certificates[i],
          ));
        }
        if (cms.certificates.isEmpty) {
          log.warning('SignatureAnalyzer: $name 里没有可读证书 (${cms.failure})');
        }
      }
    } catch (e) {
      // 归档打不开、预算拒绝、条目损坏 —— 都只是「v1 证书缺席」。
      log.warning('SignatureAnalyzer: 读取 v1 签名证书失败: $e');
    } finally {
      reader.close();
    }

    return out;
  }

  /// JAR 签名材料只可能出现在 `META-INF` 顶层。
  static bool _isTopLevelMetaInf(String name) {
    final parts = name.split('/');
    return parts.length == 2 && parts[0].toUpperCase() == 'META-INF';
  }

  /// 读 APK 尾部的 APK Signing Block；读不出返回 `null`。
  static ApkSigningSchemes? _readSigningSchemes(String apkPath) {
    RandomAccessFile? raf;
    try {
      final file = File(apkPath);
      final length = file.lengthSync();
      if (length < 32) return null;
      raf = file.openSync();
      return parseApkSigningBlock(
        fileLength: length,
        read: (offset, count) {
          if (offset < 0 || count <= 0 || offset + count > length) {
            return Uint8List(0);
          }
          raf!.setPositionSync(offset);
          return raf.readSync(count);
        },
      );
    } catch (e) {
      log.warning('SignatureAnalyzer: 读取签名块失败: $e');
      return null;
    } finally {
      raf?.closeSync();
    }
  }

  /// 等待输出流关闭。
  ///
  /// 进程被终止时流可能以错误收尾，这里吞掉即可 —— 调用方关心的是退出码与
  /// 已经收集到的输出。
  static Future<void> _drain(Future<void> done) async {
    try {
      await done;
    } catch (_) {
      // ignore: 流关闭异常不影响结论
    }
  }

  /// 从 apksigner 的原始输出解析结构化结果。
  ///
  /// 刻意与进程调用分离：这样可以用真实输出样本做单元测试，
  /// 不必依赖本机装有 Android SDK。
  static SignatureAnalysis parseResult({
    required int exitCode,
    required String stdout,
    String stderr = '',
    String? localCertificateSha256,
    List<SignatureCertificate> localCertificates = const [],
  }) {
    final status = _determineStatus(exitCode, stdout, stderr);
    // 运行时缺失时 apksigner 根本没跑起来，不能标成「执行过」。
    final runtimeMissing = status == SignatureStatus.toolUnavailable;
    return SignatureAnalysis(
      status: status,
      verifiedSchemes: _parseVerifiedSchemes(stdout),
      signers: _parseSigners(stdout),
      exitCode: exitCode,
      stdout: stdout,
      stderr: stderr,
      error: runtimeMissing
          ? 'apksigner could not start (Java runtime missing?): '
              '${_firstNonEmptyLine(stderr) ?? _firstNonEmptyLine(stdout) ?? 'exit code $exitCode'}'
          : null,
      toolExecuted: !runtimeMissing,
      localCertificateSha256: localCertificateSha256,
      localCertificates: localCertificates,
    );
  }

  static String? _firstNonEmptyLine(String value) {
    for (final line in const LineSplitter().convert(value)) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }

  /// 「启动器自己起不来」的输出特征。
  ///
  /// 必须**在**退出码判定之前拦下来，原因是 macOS 的 `/usr/bin/java` 是一个
  /// **桩**：没装 JDK 时它存在、也能执行，但立刻打印
  /// `Unable to locate a Java Runtime` 并以 **1** 退出 —— 正好和 apksigner 的
  /// 「验证未通过」撞码。不先拦，缺 JDK 的机器上**每一个包**都会被判成
  /// 「签名被篡改」，这是最严重的一类误报。
  static final _runtimeMissingPatterns = <RegExp>[
    RegExp(r'unable to locate a java runtime', caseSensitive: false),
    RegExp(r'no java runtime present', caseSensitive: false),
    // bash / zsh / dash：`line 97: java: command not found` / `java: not found`
    RegExp(r'\bjava(w)?(\.exe)?\b.*(command )?not found', caseSensitive: false),
    // cmd.exe：`'java' is not recognized as an internal or external command`
    RegExp(r'\bjava(w)?(\.exe)?\b.*is not recognized', caseSensitive: false),
  ];

  /// apksigner 的退出码约定：0 = 验证通过，1 = 未通过验证。
  ///
  /// 其他非零码（参数错误、内部异常）归入 [SignatureStatus.unknown] ——
  /// 把工具自身的故障说成「签名无效」是误报。
  static SignatureStatus _determineStatus(
    int exitCode,
    String stdout,
    String stderr,
  ) {
    final combined = '$stdout\n$stderr';
    // 先判「启动器起不来」：它可能借用了 1 号退出码（见 _runtimeMissingPatterns）。
    if (exitCode == 127 ||
        _runtimeMissingPatterns.any((p) => p.hasMatch(combined))) {
      return SignatureStatus.toolUnavailable;
    }
    if (exitCode == 0) return SignatureStatus.verified;
    if (exitCode == 1) return SignatureStatus.verificationFailed;
    // 少数版本在输出中给出明确结论但退出码不同，做一次兜底识别。
    if (combined.contains('DOES NOT VERIFY')) {
      return SignatureStatus.verificationFailed;
    }
    return SignatureStatus.unknown;
  }

  static final _schemePattern =
      RegExp(r'^Verified using (v[0-9.]+) scheme.*:\s*(true|false)\s*$');

  static Set<String> _parseVerifiedSchemes(String output) {
    final schemes = <String>{};
    for (final line in const LineSplitter().convert(output)) {
      final m = _schemePattern.firstMatch(line.trim());
      if (m != null && m.group(2) == 'true') {
        schemes.add(m.group(1)!);
      }
    }
    return schemes;
  }

  static final _signerPatterns = <String, RegExp>{
    'dn': RegExp(r'^Signer #(\d+) certificate DN:\s*(.+)$'),
    'sha256': RegExp(r'^Signer #(\d+) certificate SHA-256 digest:\s*(.+)$'),
    'sha1': RegExp(r'^Signer #(\d+) certificate SHA-1 digest:\s*(.+)$'),
    'keyAlg': RegExp(r'^Signer #(\d+) key algorithm:\s*(.+)$'),
    'keyBits': RegExp(r'^Signer #(\d+) key size \(bits\):\s*(\d+)$'),
    'validity': RegExp(r'^Signer #(\d+) certificate validity:\s*(.+)$'),
  };

  static List<SignatureSigner> _parseSigners(String output) {
    // 先收集每个签名者序号的字段，再统一构造 —— 这样字段顺序变化不会影响结果。
    final fields = <int, Map<String, String>>{};

    for (final line in const LineSplitter().convert(output)) {
      final trimmed = line.trim();
      for (final entry in _signerPatterns.entries) {
        final m = entry.value.firstMatch(trimmed);
        if (m == null) continue;
        final index = int.tryParse(m.group(1)!);
        if (index == null) continue;
        fields.putIfAbsent(index, () => {})[entry.key] = m.group(2)!.trim();
        break;
      }
    }

    final indices = fields.keys.toList()..sort();
    return [
      for (final index in indices)
        SignatureSigner(
          index: index,
          subjectDn: fields[index]!['dn'],
          sha256Digest: fields[index]!['sha256'],
          sha1Digest: fields[index]!['sha1'],
          keyAlgorithm: fields[index]!['keyAlg'],
          keySizeBits: int.tryParse(fields[index]!['keyBits'] ?? ''),
          validity: fields[index]!['validity'],
        ),
    ];
  }
}
