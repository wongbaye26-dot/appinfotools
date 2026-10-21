// 安全结论的**语料基线**：同一批真实样本，规则改动不该悄悄改变结论。
//
// ## 为什么需要它
//
// 59 条规则各有单测，但单测只覆盖「构造输入 → 期望输出」。真实包上的行为是
// 这些规则**叠加**出来的：修 A 规则时很容易顺手改掉 B 规则在真实包上的命中，
// 而所有单测仍然是绿的。`tool/crypto_corpus_eval_test.dart` 只覆盖了盗 U 一条链。
//
// 这份基线把「12 个真实 IPA 各自产出哪些 ruleId + 等级」固定下来：
// **任何一条结论的变化都必须显式更新基线**，逼改动者回答「为什么变了」。
//
// ## 样本不进仓库
//
// 真实样本有版权、也有几十 MB，不能进 git。所以：
// - 基线文件只存**文件名 + 该文件的发现项**，不含样本本身；
// - 没设 `APPINFOTOOL_SAMPLES` 时整个用例跳过，并打印原因（跳过 ≠ 通过）。
//
// 重新生成基线（**只在确认结论变化是有意的之后**）：
//
// ```sh
// APPINFOTOOL_SAMPLES=/path/to/ipa REGEN_SECURITY_BASELINE=1 \
//   flutter test test/security_baseline_test.dart
// ```

import 'dart:convert';
import 'dart:io';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/ipaparser/ipa_analysis.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart';

const String _baselinePath = 'test/fixtures/security_baseline.json';

/// 一条发现项在基线里的形状。
///
/// 只留 `ruleId` 与 `severity` —— 正文措辞会随文案调整而变，那不是结论；
/// 结论是「这条规则在这个包上是否命中、等级是什么」。
String _line(SecurityFinding f) => '${f.ruleId}:${f.severity.name}';

Map<String, List<String>> _collect(Directory dir) {
  final result = <String, List<String>>{};
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.ipa'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final file in files) {
    final name = file.uri.pathSegments.last;
    try {
      final archive = ZipDecoder().decodeBytes(file.readAsBytesSync());
      final analysis = IpaAnalysisReader.analyze(archive);
      final plist = analysis.infoPlist;
      if (plist == null) {
        result[name] = const ['<no info.plist>'];
        continue;
      }
      final security = IosPrivacyAudit.audit(
        infoPlist: plist,
        executableBytes: analysis.executableBytes,
        executablePath: analysis.executablePath,
        entitlements:
            analysis.signature?.profile.value?.entitlements ?? const [],
        provisioningProfilePresent: analysis.signature?.profile.value != null,
        nestedBundleTotal: analysis.nestedBundleTotal,
        nestedExecutables: [
          for (final nested in analysis.nestedBinaries)
            IosNestedExecutableInput(
              path: nested.path,
              bundlePath: nested.bundlePath,
              kind: nested.kind,
              bytes: nested.bytes,
              failure: nested.failure ?? nested.bytesFailure,
              usageDescriptions: nested.usageDescriptions,
            ),
        ],
        layout: analysis.layout,
      );
      final lines = security.findings.map(_line).toSet().toList()..sort();
      result[name] = lines.cast<String>();
    } catch (e) {
      result[name] = ['<error: $e>'];
    }
  }
  return result;
}

void main() {
  final samplesPath = Platform.environment['APPINFOTOOL_SAMPLES'];
  if (samplesPath == null || samplesPath.isEmpty) {
    test('安全语料基线', () {
      // ignore: avoid_print
      print('Skip: 未设置 APPINFOTOOL_SAMPLES，安全语料基线未比对');
    }, skip: '未设置 APPINFOTOOL_SAMPLES，安全语料基线未比对');
    return;
  }

  final dir = Directory(samplesPath);
  if (!dir.existsSync()) {
    test('安全语料基线', () {}, skip: 'APPINFOTOOL_SAMPLES 指向的目录不存在');
    return;
  }

  test('真实样本的安全结论与基线一致', () {
    final actual = _collect(dir);

    if (Platform.environment['REGEN_SECURITY_BASELINE'] == '1') {
      File(_baselinePath).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(actual),
      );
      // ignore: avoid_print
      print('基线已重新生成：$_baselinePath（${actual.length} 个样本）');
      return;
    }

    final baselineFile = File(_baselinePath);
    if (!baselineFile.existsSync()) {
      fail('缺少基线文件 $_baselinePath。'
          '首次使用请用 REGEN_SECURITY_BASELINE=1 生成。');
    }
    final baseline =
        jsonDecode(baselineFile.readAsStringSync()) as Map<String, dynamic>;

    final problems = <String>[];
    for (final entry in actual.entries) {
      final expected = baseline[entry.key];
      if (expected == null) {
        problems.add('${entry.key}: 基线里没有这个样本（新增样本？请重新生成）');
        continue;
      }
      final want = (expected as List).cast<String>().toSet();
      final got = entry.value.toSet();
      final added = got.difference(want).toList()..sort();
      final removed = want.difference(got).toList()..sort();
      if (added.isEmpty && removed.isEmpty) continue;
      problems.add('${entry.key}:'
          '${added.isEmpty ? '' : '\n  新增: ${added.join(', ')}'}'
          '${removed.isEmpty ? '' : '\n  消失: ${removed.join(', ')}'}');
    }
    for (final key in baseline.keys) {
      if (!actual.containsKey(key)) {
        problems.add('$key: 基线里有，但这次没扫到（样本被删了？）');
      }
    }

    expect(
      problems,
      isEmpty,
      reason: '安全结论发生了变化。如果这是有意的，'
          '用 REGEN_SECURITY_BASELINE=1 重新生成基线并在提交信息里说明原因：\n'
          '${problems.join('\n')}',
    );
  }, timeout: const Timeout(Duration(minutes: 20)));
}
