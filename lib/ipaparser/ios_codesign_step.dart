import 'dart:io';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/utils/ios_codesign_analyzer.dart';
import 'package:apk_info_tool/utils/ipa_bundle_extractor.dart';
import 'package:apk_info_tool/utils/logger.dart';
import 'package:apk_info_tool/utils/macho_crypt_id.dart';
import 'package:apk_info_tool/utils/zip_helper.dart';
import 'package:ipa_parser/ipa_parser.dart' show IosBundle;

/// 「解包 + `codesign` 验证」这一步。
///
/// 之所以单独成一个类、且**不在 worker isolate 里做**：
/// 这一步会往磁盘写文件，而 `IpaParseTask.cancel` 用的是 `Isolate.immediate`
/// —— 立即终止不保证执行 `finally`，在那种 worker 里写临时文件就可能留下垃圾。
/// 放在主 isolate 上，[run] 的 `finally` 一定能删掉临时目录。
///
/// 代价是这一步的 CPU 占用会与 UI 竞争。可接受：解包本身是 IO 密集型，
/// 真正的 CPU 计算（哈希、Mach-O、plist）已经在 worker 里做完了。
class IosCodeSignStep {
  IosCodeSignStep._();

  /// 解包 [bundle] 并用 `codesign` 验证它的签名。
  ///
  /// **无论成功、失败还是取消，临时目录都会被删除。**
  ///
  /// 任何一步不成立都返回 [SignatureStatus.toolUnavailable] 而不是
  /// [SignatureStatus.verificationFailed]：解包失败、工具缺失都不是
  /// 「签名有问题」。取消则返回 [SignatureStatus.unknown] 并在 [error] 里
  /// 说明是取消。
  static Future<IosCodeSignResult> run(
    String ipaPath,
    IosBundle bundle, {
    bool Function()? isCancelled,
    String? codesignPath,
    Duration timeout = IosCodeSignAnalyzer.defaultTimeout,
  }) async {
    // 先看工具在不在。不在就没必要解包 —— 白白往磁盘上写几百 MB。
    if (IosCodeSignAnalyzer.findCodesignPath(override: codesignPath) == null) {
      log.info('IosCodeSignStep: codesign 不可用，跳过解包');
      return const IosCodeSignResult.toolUnavailable(
        'codesign is not available on this platform',
      );
    }

    final helper = ZipHelper();
    String? tempRoot;
    try {
      final openResult = await helper.open(ipaPath);
      if (!openResult.isOk) {
        return IosCodeSignResult.toolUnavailable(
          'the IPA could not be reopened for extraction: '
          '${openResult.description}',
        );
      }
      final archive = helper.archive;
      if (archive == null) {
        return const IosCodeSignResult.toolUnavailable(
          'the IPA archive is not available',
        );
      }

      final extraction = await IpaBundleExtractor.extract(
        archive,
        bundle,
        isCancelled: isCancelled,
      );

      if (extraction.cancelled) {
        return const IosCodeSignResult(
          status: SignatureStatus.unknown,
          error: 'signature verification was cancelled',
        );
      }
      if (!extraction.ok) {
        return IosCodeSignResult.toolUnavailable(
          'the app bundle could not be extracted: '
          '${extraction.failure ?? extraction.failureCode}',
        );
      }

      tempRoot = extraction.tempRoot;

      final analyzed = await IosCodeSignAnalyzer.analyze(
        extraction.bundlePath!,
        timeout: timeout,
        codesignPath: codesignPath,
      );

      // 顺手读一下主二进制是不是已解密。
      //
      // `codesign` 说「签名无效」时，「砸壳」与「有人打了补丁」从输出上
      // 一模一样；`cryptid` 能把它们分开 —— 报告因此能给出**有证据的**结论，
      // 而不是「可能是砸壳」。
      final decrypted = await _isMainBinaryDecrypted(
        extraction.bundlePath!,
        analyzed.info?.executable,
      );
      final result = analyzed.withMainBinaryDecrypted(decrypted);

      // 符号链接被当普通文件写出，会让 codesign 的密封校验失败。这不是
      // 「签名被篡改」，必须在结果里说清楚，否则用户会得到错误结论。
      //
      // 判据是「不是 verified」而不是「没有明确结论」：**验证失败**恰恰是
      // 最需要这条说明的情况 —— 那正是「我们的解包方式可能造成了这个失败」
      // 与「文件真的被改过」需要被区分开的地方。
      if (extraction.symlinkCount > 0 &&
          result.status != SignatureStatus.verified) {
        final base = result.error ?? 'signature verification was inconclusive';
        final note = '${extraction.symlinkCount} symbolic link '
            '${extraction.symlinkCount == 1 ? 'entry was' : 'entries were'} '
            'materialised as regular files, which can invalidate the seal';
        return IosCodeSignResult(
          status: result.status,
          toolExecuted: result.toolExecuted,
          exitCode: result.exitCode,
          stdout: result.stdout,
          stderr: result.stderr,
          error: '$base (note: $note)',
          info: result.info,
          mainBinaryDecrypted: result.mainBinaryDecrypted,
        );
      }
      return result;
    } finally {
      // 保证清理：成功、失败、取消、抛异常，四条路都走到这里。
      await IpaBundleExtractor.cleanUp(tempRoot);
      helper.close();
    }
  }

  /// 主可执行文件是否已解密（`cryptid == 0`）。
  ///
  /// 只读文件**开头一段**：加载命令在头部，而主二进制常有几百 MB，整读进
  /// 内存只为取一个 u32 不值得。1 MiB 足够覆盖任何正常二进制的加载命令；
  /// 超出就返回 `null`（没查出来），而不是猜。
  ///
  /// 任何失败都返回 `null`：文件不在、不是 Mach-O、fat 二进制、读不动。
  /// **`null` 不能显示成「已解密」。**
  static Future<bool?> _isMainBinaryDecrypted(
    String bundlePath,
    String? executableName,
  ) async {
    if (executableName == null || executableName.isEmpty) return null;
    RandomAccessFile? handle;
    try {
      final file = File('$bundlePath/$executableName');
      if (!await file.exists()) return null;
      handle = await file.open();
      final bytes = await handle.read(1024 * 1024);
      return switch (readMachOCryptId(bytes)) {
        0 => true,
        1 => false,
        _ => null,
      };
    } catch (_) {
      return null;
    } finally {
      await handle?.close();
    }
  }
}
