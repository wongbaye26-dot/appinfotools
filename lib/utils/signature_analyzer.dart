import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/utils/command_tools.dart';
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

  const SignatureAnalysis({
    required this.status,
    this.verifiedSchemes = const {},
    this.signers = const [],
    this.exitCode,
    this.stdout = '',
    this.stderr = '',
    this.error,
    this.toolExecuted = false,
  });

  /// 工具不可用时的结果。**不是**「签名无效」。
  factory SignatureAnalysis.toolUnavailable(String reason) => SignatureAnalysis(
        status: SignatureStatus.toolUnavailable,
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
    final resolved = apksignerPath ?? CommandTools.findApkSignerPath();
    if (resolved == null || resolved.isEmpty) {
      log.info('SignatureAnalyzer: apksigner 不可用，无法得出结论');
      return SignatureAnalysis.toolUnavailable('apksigner not found');
    }

    Process process;
    try {
      process = await Process.start(
        resolved,
        ['verify', '--print-certs', '--verbose', apkPath],
      );
    } on ProcessException catch (e) {
      // 二进制存在但无法执行（权限、架构不匹配等）—— 仍属「工具不可用」，
      // 而不是「签名无效」。
      log.warning('SignatureAnalyzer: apksigner 无法执行: $e');
      return SignatureAnalysis.toolUnavailable('cannot execute apksigner: $e');
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
      );
    }

    await _drain(stdoutDone);
    await _drain(stderrDone);

    return parseResult(
      exitCode: exitCode,
      stdout: stdoutBuffer.toString(),
      stderr: stderrBuffer.toString(),
    );
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
