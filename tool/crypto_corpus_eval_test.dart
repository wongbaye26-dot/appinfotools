// 「盗 U」规则的**语料评估**（不进质量门禁，默认 `flutter test` 跑不到它）。
//
// 上一轮我给的可信度数字全是**估计**。这个脚本是把估计换成实测的唯一办法：
// 拿一份标注好的语料跑一遍，算出召回与精确度。
//
// ## 用法
//
// ```
// CRYPTO_CORPUS=/path/to/corpus \
//   NO_PROXY=127.0.0.1,localhost,::1 \
//   ~/development/flutter/bin/flutter test tool/crypto_corpus_eval_test.dart
// ```
//
// 可选：`CRYPTO_CORPUS_OUT=/path/report.md` 把同一份结果写成 Markdown。
//
// ## 语料目录约定
//
// ```
// corpus/
//   malicious/   *.apk *.ipa   已知的盗 U / 钱包木马样本
//   wallet/      *.apk *.ipa   正规钱包、交易所（用来量误报）
//   benign/      *.apk *.ipa   普通应用（用来量误报）
// ```
//
// 三个目录都允许不存在（缺哪个就少算哪一档），但 `malicious/` 为空时
// **召回无法计算** —— 脚本会明说，而不是给一个 0。
//
// ## 两个阈值
//
// - **有任何发现**（P3 及以上）：宽口径，看「值不值得人工看一眼」；
// - **P2 及以上**：窄口径，看「敢不敢报警」。
//
// 两个口径都报，因为它们的用途不同 —— 只报一个数会让人误以为规则只有一个开关。
//
// ## 分析失败的文件
//
// 解析不了的文件**不进分母**，单独计数并列出。把「打不开」算成「没命中」
// 会让召回虚高，这是这类评估最常见的自欺。

import 'dart:io';
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart';

const List<String> _categories = ['malicious', 'wallet', 'benign'];

/// 一行的评估结果。
class _Row {
  _Row(this.category, this.name);

  final String category;
  final String name;

  SecurityFinding? finding;

  /// 非空表示这个文件**没能分析**（不计入分母）。
  String? failure;

  bool get analysed => failure == null;

  bool hitAny() => finding != null;

  bool hitHigh() =>
      finding != null && finding!.severity.index <= SecuritySeverity.p2.index;

  String get verdict {
    if (!analysed) return 'SKIP';
    if (finding == null) return '-';
    return finding!.severity.name.toUpperCase();
  }
}

/// APK：复刻 `lib/apkparser/parse_task.dart` 的调用序列，只跑到安全审计。
Future<_Row> _evalApk(File file, String category) async {
  final row = _Row(category, file.uri.pathSegments.last);
  final reader = ApkReader();
  try {
    final open = await reader.open(file.path);
    if (!open.isOk) {
      row.failure = 'open: ${open.name}';
      return row;
    }
    final meta = await reader.parse();
    if (meta == null) {
      row.failure = 'manifest: ${reader.manifestFailure ?? 'unparsed'}';
      return row;
    }
    final dexEntries = <DexBytes>[
      for (final name in reader.listFiles(extension: '.dex'))
        if (reader.readFile(name) case final bytes?) DexBytes(name, bytes),
    ];
    final candidates = reader.listFilesWithSize(extension: '.so');
    final selection = NativeSymbolScanner.selectLibraries(candidates);
    final natives = <NativeLibraryBytes>[
      for (final name in selection.selected)
        if (reader.readFile(name) case final bytes?)
          NativeLibraryBytes(name, bytes),
    ];
    final security = AndroidSecurityAudit.audit(
      meta: meta,
      dexEntries: dexEntries,
      nativeEntries: natives,
      nativeLibraryTotal: NativeSymbolScanner.uniqueLibraryCount(candidates),
      nativeSkipped: selection.skipped,
      arscEntryCount: reader.arscParser?.getAllResources().length,
    );
    row.finding = _cryptoFinding(security);
    return row;
  } catch (e) {
    row.failure = 'exception: $e';
    return row;
  } finally {
    reader.close();
  }
}

/// IPA：只跑到 `IosPrivacyAudit`（codesign 那一步需要 macOS 工具，与规则无关）。
Future<_Row> _evalIpa(File file, String category) async {
  final row = _Row(category, file.uri.pathSegments.last);
  try {
    final archive = ZipDecoder().decodeBytes(file.readAsBytesSync());
    final container = IpaContainerReader.read(archive);
    final main = container.bundles.isEmpty ? null : container.bundles.first;
    if (main == null) {
      row.failure = 'no bundle';
      return row;
    }
    final plist = IpaInfoPlistReader.read(archive, main);
    final executableName = plist.executable.value;
    final executablePath = executableName == null || executableName.isEmpty
        ? null
        : '${main.path}/$executableName';
    List<int>? executableBytes;
    if (executablePath != null) {
      for (final entry in archive.files) {
        if (!entry.isFile || entry.name != executablePath) continue;
        executableBytes = entry.content;
        break;
      }
    }

    final security = IosPrivacyAudit.audit(
      infoPlist: plist,
      executableBytes:
          executableBytes == null ? null : Uint8List.fromList(executableBytes),
      executablePath: executablePath,
    );
    row.finding = _cryptoFinding(security);
    return row;
  } catch (e) {
    row.failure = 'exception: $e';
    return row;
  }
}

SecurityFinding? _cryptoFinding(SecurityAnalysisResult result) {
  for (final finding in result.findings) {
    if (finding.category == SecurityCategory.cryptoAsset) return finding;
  }
  return null;
}

String _signalsOf(SecurityFinding finding) {
  final raw = finding.messageArgs['signals'];
  if (raw is List) return raw.join(', ');
  return '';
}

void _report(List<_Row> rows, {String? outPath}) {
  final buffer = StringBuffer();
  void line(String text) {
    // ignore: avoid_print
    print(text);
    buffer.writeln(text);
  }

  line('| 类别 | 文件 | 结果 | 信号 |');
  line('|---|---|---|---|');
  for (final row in rows) {
    line('| ${row.category} | ${row.name} | ${row.verdict} | '
        '${row.finding == null ? '' : _signalsOf(row.finding!)} |');
  }

  final analysed = rows.where((r) => r.analysed).toList();
  final skipped = rows.where((r) => !r.analysed).toList();
  final malicious = analysed.where((r) => r.category == 'malicious').toList();
  final negatives = analysed.where((r) => r.category != 'malicious').toList();

  String pct(int a, int b) => b == 0 ? 'n/a' : '${(100 * a / b).round()}%';

  for (final (label, predicate) in <(String, bool Function(_Row))>[
    ('有任何发现（P3+）', (r) => r.hitAny()),
    ('P2 及以上', (r) => r.hitHigh()),
  ]) {
    final tp = malicious.where(predicate).length;
    final fp = negatives.where(predicate).length;
    line('');
    line('**$label**：召回 $tp/${malicious.length} '
        '(${pct(tp, malicious.length)})，'
        '精确度 ${pct(tp, tp + fp)}（$tp 真阳性 / $fp 误报，'
        '负样本 ${negatives.length} 个）');
  }

  final walletFp = negatives.where((r) => r.category == 'wallet' && r.hitAny());
  final benignFp = negatives.where((r) => r.category == 'benign' && r.hitAny());
  line('');
  line('误报分布：正规钱包 ${walletFp.length}/'
      '${negatives.where((r) => r.category == 'wallet').length}，'
      '普通应用 ${benignFp.length}/'
      '${negatives.where((r) => r.category == 'benign').length}');

  if (skipped.isNotEmpty) {
    line('');
    line('**未能分析（不计入分母）**：${skipped.length} 个');
    for (final row in skipped) {
      line('- ${row.category}/${row.name}：${row.failure}');
    }
  }

  if (malicious.isEmpty) {
    line('');
    line('**malicious/ 为空 —— 召回无法计算**，上面的召回行不作数。');
  }

  if (outPath != null && outPath.isNotEmpty) {
    File(outPath).writeAsStringSync(buffer.toString());
  }
}

void main() {
  test('盗 U 规则：语料评估', () async {
    final root = Platform.environment['CRYPTO_CORPUS'];
    if (root == null || root.isEmpty) {
      markTestSkipped(
        '未设置 CRYPTO_CORPUS —— 目录约定见 tool/crypto_corpus_eval_test.dart 文件头',
      );
      return;
    }
    final directory = Directory(root);
    if (!directory.existsSync()) {
      markTestSkipped('语料目录不存在：$root');
      return;
    }

    final rows = <_Row>[];
    for (final category in _categories) {
      final dir = Directory('$root/$category');
      if (!dir.existsSync()) continue;
      final files = dir
          .listSync(recursive: false)
          .whereType<File>()
          .where((f) => f.path.endsWith('.apk') || f.path.endsWith('.ipa'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final file in files) {
        rows.add(file.path.endsWith('.ipa')
            ? await _evalIpa(file, category)
            : await _evalApk(file, category));
      }
    }

    if (rows.isEmpty) {
      markTestSkipped('语料目录里没有 .apk / .ipa：$root');
      return;
    }
    _report(rows, outPath: Platform.environment['CRYPTO_CORPUS_OUT']);
  });
}
