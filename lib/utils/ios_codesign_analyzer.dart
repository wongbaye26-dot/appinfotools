import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/utils/logger.dart';
import 'package:apk_info_tool/utils/tool_paths.dart';
import 'package:ipa_parser/ipa_parser.dart'
    show IosEntitlement, PlistDict, PlistParser, PlistValue;

/// `codesign -d` 报告的**描述性**信息。
///
/// 这些是「签名里写了什么」，**不是**「签名是否有效」。规范 5.5 要求两者
/// 分开：`codesign -d` 即使对一个签名已损坏的 bundle 也会成功返回并打印
/// 内容，把它当作验证结论正是要避免的错误。有效性只以
/// `codesign --verify` 的退出码为准。
class IosCodeSignInfo {
  /// `Identifier=`，即签名里记录的 bundle id。
  final String? identifier;

  /// `TeamIdentifier=`。未设置时为 `null`（`codesign` 会打印 `not set`）。
  final String? teamIdentifier;

  /// `Format=`，例如 `app bundle with Mach-O universal (arm64 arm64e)`。
  final String? format;

  /// 主可执行文件路径。
  final String? executable;

  /// `Authority=` 行，从叶证书到根证书依次排列。
  final List<String> authorities;

  /// `CDHash=`。
  final String? cdHash;

  /// `Signature=`，例如 `adhoc`。
  final String? signatureKind;

  /// `Sealed Resources=`。
  final String? sealedResources;

  /// 签名里的授权项（`--entitlements :-`）。
  final List<IosEntitlement> entitlements;

  /// 授权项是否成功取到。
  ///
  /// `false` 表示「没读到」（命令没执行、输出不是 plist），**不是**「没有
  /// 授权项」—— 后者表现为空列表且本字段为 true。
  final bool entitlementsRead;

  const IosCodeSignInfo({
    this.identifier,
    this.teamIdentifier,
    this.format,
    this.executable,
    this.authorities = const [],
    this.cdHash,
    this.signatureKind,
    this.sealedResources,
    this.entitlements = const [],
    this.entitlementsRead = false,
  });

  /// 是否从签名里读到了任何描述性信息。
  bool get hasAnyValue =>
      identifier != null ||
      teamIdentifier != null ||
      format != null ||
      authorities.isNotEmpty ||
      cdHash != null;

  @override
  String toString() => 'IosCodeSignInfo(identifier: $identifier, '
      'team: $teamIdentifier, authorities: ${authorities.length}, '
      'entitlements: ${entitlements.length})';
}

/// `codesign` 验证一个 bundle 的结果。
class IosCodeSignResult {
  final SignatureStatus status;

  /// 是否真的执行了 `codesign`。`false` 表示 [SignatureStatus.toolUnavailable]。
  final bool toolExecuted;

  /// `codesign --verify` 的退出码。未执行时为 `null`。
  final int? exitCode;

  /// `--verify` 的原始输出（`codesign` 把 verbose 输出写到 stderr）。
  final String stdout;
  final String stderr;

  /// 失败/未知时的人类可读原因。
  final String? error;

  /// 描述性信息。**只用于展示，不作为验证结论。**
  final IosCodeSignInfo? info;

  const IosCodeSignResult({
    required this.status,
    this.toolExecuted = false,
    this.exitCode,
    this.stdout = '',
    this.stderr = '',
    this.error,
    this.info,
  });

  /// 工具不可用。**不是**「签名无效」。
  const IosCodeSignResult.toolUnavailable(String reason)
      : this(
          status: SignatureStatus.toolUnavailable,
          error: reason,
        );

  bool get hasConclusiveResult => status.hasConclusiveResult;

  /// 供 UI 展示的原始输出（失败时含具体原因）。
  String get rawOutput {
    final parts = <String>[
      if (stderr.trim().isNotEmpty) stderr.trim(),
      if (stdout.trim().isNotEmpty) stdout.trim(),
    ];
    return parts.join('\n');
  }
}

/// 用 macOS 的 `codesign` 验证一个**已解包** bundle 的签名。
///
/// 只在 macOS 上可用；其他平台返回 [SignatureStatus.toolUnavailable]，
/// 由调用方如实呈现为「无法确认」—— 规范 5.5 明确要求不得把「没有工具」
/// 说成「签名有问题」。
///
/// 与 Android 侧 `SignatureAnalyzer` 的分工一致：本类只负责调用与解析，
/// 不做任何自己的密码学判断。
class IosCodeSignAnalyzer {
  IosCodeSignAnalyzer._();

  /// 单次调用的超时上限。
  ///
  /// 取 120 秒与 aapt2 / apksigner 路径保持一致。`codesign --verify` 在大
  /// bundle 上可能要遍历上千个文件，太短会误报。
  static const Duration defaultTimeout = Duration(seconds: 120);

  /// 查找 `codesign`。
  ///
  /// macOS 上它固定在 `/usr/bin/codesign`；这里仍然走一次存在性检查，
  /// 而不是只判断 `Platform.isMacOS` —— 判断平台得到的是「应该存在」，
  /// 检查文件得到的是「确实存在」。
  static String? findCodesignPath({String? override}) {
    if (override != null && override.isNotEmpty) return override;
    if (!Platform.isMacOS) return null;

    const standardPath = '/usr/bin/codesign';
    if (File(standardPath).existsSync()) return standardPath;
    return ToolPaths.findInPath('codesign');
  }

  /// 验证并读取 [bundlePath] 的签名信息。
  static Future<IosCodeSignResult> analyze(
    String bundlePath, {
    Duration timeout = defaultTimeout,
    String? codesignPath,
  }) async {
    final resolved = findCodesignPath(override: codesignPath);
    if (resolved == null) {
      log.info('IosCodeSignAnalyzer: codesign 不可用，无法得出结论');
      return const IosCodeSignResult.toolUnavailable('codesign not available');
    }

    // 先跑验证：结论只来自这一步。
    final verify = await _run(
      resolved,
      ['--verify', '--strict', '--verbose=4', bundlePath],
      timeout,
    );
    if (verify == null) {
      return IosCodeSignResult(
        status: SignatureStatus.unknown,
        toolExecuted: true,
        error: 'codesign --verify timed out after ${timeout.inSeconds}s',
      );
    }

    final status = parseVerifyResult(
      exitCode: verify.exitCode,
      stderr: verify.stderr,
      stdout: verify.stdout,
    );

    // 再读描述性信息。它**不**影响 status —— 即使验证失败也照样读，
    // 因为「签名里写了什么」在排查时同样有用，只是不能被当成结论。
    final info = await _readInfo(resolved, bundlePath, timeout);

    return IosCodeSignResult(
      status: status.$1,
      toolExecuted: true,
      exitCode: verify.exitCode,
      stdout: verify.stdout,
      stderr: verify.stderr,
      error: status.$2,
      info: info,
    );
  }

  /// 把 `codesign --verify` 的结果映射成结论。
  ///
  /// 退出码语义（实测于 macOS 26 的 `codesign`）：
  /// - `0`：验证通过；
  /// - `1`：验证不通过（签名缺失、密封资源不匹配、磁盘上的文件被改过）；
  /// - `3`：密封本身完好，但**不满足其指定要求**（ad-hoc 签名没有
  ///   指定要求，必然走到这里）。这也是「没通过验证」，但原因不同，
  ///   因此单独说明，避免用户误以为文件被篡改；
  /// - 其他：工具自身的问题，归入「未知」—— 把工具的故障说成「签名无效」
  ///   是误报。
  ///
  /// 退出码 0 **还要求输出里能看到 codesign 的结论行**。只认退出码的话，
  /// 一个被错误配置成别的程序的路径（比如 `/usr/bin/true`）也会返回 0，
  /// 于是「签名有效」就被凭空报了出来 —— 这正是规范 5.5 禁止的那种
  /// 「没有验证却显示验证通过」。
  static (SignatureStatus, String?) parseVerifyResult({
    required int exitCode,
    required String stderr,
    String stdout = '',
  }) {
    if (exitCode == 0) {
      if (_looksLikeSuccessfulVerification('$stderr\n$stdout')) {
        return (SignatureStatus.verified, null);
      }
      return (
        SignatureStatus.unknown,
        'codesign exited with 0 but printed no recognizable verification '
            'result; the configured tool may not be codesign',
      );
    }

    final output = stderr.trim();
    final firstLine = output.isEmpty ? '' : output.split('\n').first.trim();
    final detail = firstLine.isEmpty ? '' : ': $firstLine';

    // 路径不存在属于调用方的问题，不能当成「签名无效」。
    if (output.contains('No such file or directory') ||
        output.contains('does not exist')) {
      return (
        SignatureStatus.unknown,
        'codesign could not find the bundle$detail',
      );
    }

    if (exitCode == 1) {
      return (
        SignatureStatus.verificationFailed,
        'codesign reported that the signature is not valid$detail',
      );
    }
    if (exitCode == 3) {
      return (
        SignatureStatus.verificationFailed,
        'the signature seal is intact but the bundle does not satisfy its '
            'designated requirement$detail',
      );
    }

    return (
      SignatureStatus.unknown,
      'codesign exited with $exitCode$detail',
    );
  }

  /// 输出是否具备「验证通过」的形态。
  ///
  /// `codesign --verify --verbose=4` 通过时会打印
  /// `…: valid on disk` 与 `…: satisfies its Designated Requirement`。
  /// 这两句是 codesign 特有的措辞，用它确认「确实是 codesign 在回答」。
  static bool _looksLikeSuccessfulVerification(String output) =>
      output.contains('valid on disk') ||
      output.contains('satisfies its Designated Requirement');

  /// 解析 `codesign -d --verbose=4` 的输出。
  ///
  /// 输出走 stderr。只按**已知键名**逐行匹配，未知行忽略 —— `codesign` 的
  /// 输出随版本变化，为每个键建模只会让解析器跟着版本跑；反过来按
  /// 「第一个等号」切分会把 `Sealed Resources version=2 rules=13 files=74`
  /// 这种行切成错误的键值对。
  static IosCodeSignInfo parseInfo(String output) {
    String? identifier;
    String? teamIdentifier;
    String? format;
    String? executable;
    String? cdHash;
    String? signatureKind;
    String? sealedResources;
    final authorities = <String>[];

    for (final line in const LineSplitter().convert(output)) {
      final trimmed = line.trim();

      // `Sealed Resources` 后面直接跟空格，等号在更后面
      // （`Sealed Resources version=2 rules=13 files=74`）。先单独处理，
      // 否则按第一个等号切分会得到 `Sealed Resources version` 这个假键。
      if (trimmed.startsWith('Sealed Resources ')) {
        sealedResources =
            _nonEmpty(trimmed.substring('Sealed Resources '.length).trim());
        continue;
      }

      final index = trimmed.indexOf('=');
      if (index <= 0) continue;
      final key = trimmed.substring(0, index);
      final value = trimmed.substring(index + 1).trim();

      switch (key) {
        case 'Identifier':
          identifier = _nonEmpty(value);
        case 'TeamIdentifier':
          teamIdentifier = _nonEmpty(value);
        case 'Format':
          format = _nonEmpty(value);
        case 'Executable':
          executable = _nonEmpty(value);
        case 'CDHash':
          cdHash = _nonEmpty(value);
        case 'Signature':
          signatureKind = _nonEmpty(value);
        case 'Authority':
          final authority = _nonEmpty(value);
          if (authority != null) authorities.add(authority);
      }
    }

    return IosCodeSignInfo(
      identifier: identifier,
      teamIdentifier: teamIdentifier,
      format: format,
      executable: executable,
      authorities: authorities,
      cdHash: cdHash,
      signatureKind: signatureKind,
      sealedResources: sealedResources,
    );
  }

  /// `codesign` 用 `not set` / `none` 表示「没有这个值」，不该当成一个值。
  static String? _nonEmpty(String value) {
    if (value.isEmpty) return null;
    if (value == 'not set' || value == 'none') return null;
    return value;
  }

  /// 解析 `codesign -d --entitlements :-` 的输出（一段 XML plist）。
  ///
  /// 输出为空表示该 bundle 没有授权项，返回空列表 —— 这不是失败。
  /// 输出非空但解析不出 plist 时返回 `null`，调用方据此标记「没读到」，
  /// 而不是当成「没有授权项」。
  static List<IosEntitlement>? parseEntitlements(String output) {
    final trimmed = output.trim();
    if (trimmed.isEmpty) return const [];

    final PlistValue parsed;
    try {
      parsed = PlistParser.parseString(trimmed);
    } catch (_) {
      return null;
    }
    if (parsed is! PlistDict) return null;

    return [
      for (final entry in parsed.value.entries)
        IosEntitlement(key: entry.key, value: entry.value),
    ];
  }

  /// 读取描述性信息。任何一步失败都只返回 `null`，不影响验证结论。
  static Future<IosCodeSignInfo?> _readInfo(
    String codesignPath,
    String bundlePath,
    Duration timeout,
  ) async {
    final display = await _run(
      codesignPath,
      ['-d', '--verbose=4', bundlePath],
      timeout,
    );
    if (display == null) return null;

    final info =
        parseInfo(display.stderr.isEmpty ? display.stdout : display.stderr);

    final entitlements = await _run(
      codesignPath,
      // `:-` 让 codesign 输出原始 XML plist（裸 `-` 会输出它自己的人读格式）。
      // 该写法已被 codesign 标记为将来会移除，因此解析失败时只记「没读到」。
      ['-d', '--entitlements', ':-', bundlePath],
      timeout,
    );
    final parsedEntitlements =
        entitlements == null ? null : parseEntitlements(entitlements.stdout);

    if (parsedEntitlements == null) {
      return info;
    }
    return IosCodeSignInfo(
      identifier: info.identifier,
      teamIdentifier: info.teamIdentifier,
      format: info.format,
      executable: info.executable,
      authorities: info.authorities,
      cdHash: info.cdHash,
      signatureKind: info.signatureKind,
      sealedResources: info.sealedResources,
      entitlements: parsedEntitlements,
      entitlementsRead: true,
    );
  }

  /// 执行一条命令，超时则终止子进程并返回 `null`。
  ///
  /// 与 `SignatureAnalyzer` 同样的处理：`Future.timeout` 只是不再等待，
  /// 子进程会继续跑下去，必须显式 kill；kill 之后不能再等 stdout/stderr
  /// 关闭（可能有继承了同一批管道的孙进程），直接丢弃。
  static Future<_CommandOutput?> _run(
    String executable,
    List<String> arguments,
    Duration timeout,
  ) async {
    Process process;
    try {
      // 参数以数组传入，不经过任何 shell —— 路径里的空格、引号、分号都只是
      // 普通字符。
      process = await Process.start(executable, arguments);
    } on ProcessException catch (e) {
      log.warning('IosCodeSignAnalyzer: 无法执行 $executable: $e');
      return null;
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
      log.warning(
          'IosCodeSignAnalyzer: $executable 超时（${timeout.inSeconds}s），已终止');
      process.kill(ProcessSignal.sigkill);
      stdoutDone.ignore();
      stderrDone.ignore();
      return null;
    }

    await _drain(stdoutDone);
    await _drain(stderrDone);

    return _CommandOutput(
      exitCode: exitCode,
      stdout: stdoutBuffer.toString(),
      stderr: stderrBuffer.toString(),
    );
  }

  static Future<void> _drain(Future<void> done) async {
    try {
      await done;
    } catch (_) {
      // 流关闭异常不影响结论。
    }
  }
}

class _CommandOutput {
  final int exitCode;
  final String stdout;
  final String stderr;

  const _CommandOutput({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });
}
