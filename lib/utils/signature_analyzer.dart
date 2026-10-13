import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:apk_info_tool/utils/command_tools.dart';
import 'package:apk_info_tool/utils/logger.dart';

/// 签名验证的结果状态。
///
/// 这四个状态**必须分开**：
/// - 把「工具不可用」显示成「签名无效」，会把没装 Android SDK 的开发机
///   误报成恶意应用；
/// - 把「结果未知」显示成「验证通过」则是更危险的方向 —— 会让用户以为
///   已经验证过。
///
/// 因此只要没有拿到明确结论，就绝不显示「签名有效」。
enum SignatureStatus {
  /// apksigner 明确验证通过。
  verified,

  /// apksigner 明确报告验证失败（退出码 1 / 输出 `DOES NOT VERIFY`）。
  verificationFailed,

  /// 找不到或无法执行 apksigner —— **无法得出结论**，不代表签名有问题。
  toolUnavailable,

  /// 执行了工具，但既非通过也非明确失败（超时、非预期退出码、输出异常）。
  unknown;

  bool get hasConclusiveResult =>
      this == SignatureStatus.verified ||
      this == SignatureStatus.verificationFailed;
}

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
    return SignatureAnalysis(
      status: _determineStatus(exitCode, stdout, stderr),
      verifiedSchemes: _parseVerifiedSchemes(stdout),
      signers: _parseSigners(stdout),
      exitCode: exitCode,
      stdout: stdout,
      stderr: stderr,
      toolExecuted: true,
    );
  }

  /// apksigner 的退出码约定：0 = 验证通过，1 = 未通过验证。
  ///
  /// 其他非零码（参数错误、内部异常）归入 [SignatureStatus.unknown] ——
  /// 把工具自身的故障说成「签名无效」是误报。
  static SignatureStatus _determineStatus(
    int exitCode,
    String stdout,
    String stderr,
  ) {
    if (exitCode == 0) return SignatureStatus.verified;
    if (exitCode == 1) return SignatureStatus.verificationFailed;
    // 少数版本在输出中给出明确结论但退出码不同，做一次兜底识别。
    if ('$stdout\n$stderr'.contains('DOES NOT VERIFY')) {
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
