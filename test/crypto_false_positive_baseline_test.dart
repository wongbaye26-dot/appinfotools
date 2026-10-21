// 「盗 U」规则的**误报基线**：仓库里的真实二进制夹具不应产出任何信号。
//
// ## 这条能证明什么
//
// 地址正则是「从二进制里捞 ASCII 串再匹配」，最容易出的问题是**幻觉**：
// 把哈希、颜色值、内存偏移切一段出来当成地址；或者标记在正常二进制上误命中。
// 18 个真实夹具（13 个 DEX + 5 个 Mach-O，都是真实工具产出）零命中，说明
// 判据的边界是站得住的。
//
// **这条不是空转**：同一批 DEX 里其它标记是命中的（`real-cooccurrence.dex`
// 命中 `uploadimage` / `ocr-recognizetext`，`real-netprobe.dex` 命中
// `httpurlconnection` / `okhttp`）—— 扫描确实读了字节、也确实在做匹配，
// 只是没有一条落在加密资产上。下面那条 `anyClue` 断言把这一点钉住：
// 扫描器哪天退化成读不到东西，这条基线会立刻变成假绿，必须让它红。
//
// ## 这条不能证明什么
//
// **不是真实应用的误报率**。夹具都很小（DEX 1–2 KB、dylib 几十 KB），
// 既没有钱包 SDK、也没有剪贴板调用、更没有地址字面量 —— 它们本来就该是干净的。
// 真实基线需要 `APPINFOTOOL_SAMPLES` 指向的真实包样本。
//
// 另：13 个 APK 夹具**全部 0 DEX**（见 `android_security_e2e_test.dart` 的说明），
// 这条规则在它们上面根本跑不到，所以没有纳入。

import 'dart:io';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart';

List<File> _filesIn(String dir, String suffix) {
  final directory = Directory(dir);
  if (!directory.existsSync()) return const [];
  return directory
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith(suffix))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

void main() {
  test('DEX 夹具不产出盗 U 信号（地址正则不会从噪声里幻觉出地址）', () {
    final files = _filesIn('test/fixtures/dex', '.dex');
    expect(files, isNotEmpty, reason: '夹具目录不见了 —— 这条基线就失效了');
    var anyClue = false;
    for (final file in files) {
      final scan = DexClueScanner.scan(
        [DexBytes(file.path.split('/').last, file.readAsBytesSync())],
      );
      anyClue = anyClue || scan.clues.isNotEmpty;
      expect(
        scan.cryptoAddresses,
        isEmpty,
        reason: '${file.path} 里被识别出了地址：${scan.cryptoAddresses}',
      );
      expect(
        scan.clues
            .where((c) => c.category == SecurityCategory.cryptoAsset)
            .map((c) => c.markerId)
            .toList(),
        isEmpty,
        reason: '${file.path} 命中了加密资产标记',
      );
    }
    // 扫描器真的读到了东西吗？读不到的话上面那些「没有命中」全是假绿。
    expect(anyClue, isTrue, reason: '所有夹具都没命中任何标记 —— 扫描器可能没在跑');
  });

  test('Mach-O 夹具不产出盗 U 信号', () {
    final files = _filesIn('test/fixtures/macho', '.dylib');
    expect(files, isNotEmpty, reason: '夹具目录不见了 —— 这条基线就失效了');
    for (final file in files) {
      final signals = IosCryptoSignals();
      for (final text in AsciiStrings.extract(file.readAsBytesSync())) {
        signals.collect(text, file.path);
      }
      expect(
        signals.samples,
        isEmpty,
        reason: '${file.path} 命中了标记：${signals.samples.keys}',
      );
      expect(signals.addresses, isEmpty, reason: '${file.path} 里被识别出了地址');
      expect(iosCryptoIsHighRisk(signals), isFalse);
    }
  });
}
