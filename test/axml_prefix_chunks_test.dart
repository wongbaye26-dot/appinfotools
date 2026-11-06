// 加固包在 AXML 字符串池前塞诱饵 chunk 的回归测试。
//
// 实测样本 `/Users/wangbaye/Downloads/200_1106154007.apk`：
// 78 个 848 字节、类型 0x7fxx 的 chunk 把真正的 string pool 推到 0x10268，
// aapt2 只警告「unexpected chunk type」仍能读出完整清单，而严格要求
// 「第一块必须是 string pool」的解析器会抛 FormatException，整包退化成
// 「只有包名、版本/权限/组件全空」。
//
// 夹具以真实 APK 的 manifest 为底，只在头部后插入诱饵块；期望值用
// `aapt2 dump badging` 独立核对过（package / version / sdk / label）。

import 'dart:io';
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixture = 'test/fixtures/apk/signed-v2-v3.apk';

List<int> _u32(int value) => [
      value & 0xff,
      (value >> 8) & 0xff,
      (value >> 16) & 0xff,
      (value >> 24) & 0xff,
    ];

/// 在 8 字节 AXML 文件头之后插入 [count] 个诱饵 chunk，并修正根 chunk 尺寸。
Uint8List _withDecoyPrefix(
  Uint8List manifest, {
  required int count,
  int chunkSize = 848,
  int? declaredSize,
}) {
  final fake = <int>[];
  for (var i = 0; i < count; i++) {
    final type = 0x7fa5 + (i * 7 % 0x50);
    fake.addAll([type & 0xff, (type >> 8) & 0xff, 0x08, 0x00]);
    fake.addAll(_u32(declaredSize ?? chunkSize));
    if ((declaredSize ?? chunkSize) > 8) {
      fake.addAll(List<int>.filled((declaredSize ?? chunkSize) - 8, 0));
    }
  }
  final out = Uint8List(8 + fake.length + manifest.length - 8);
  out.setRange(0, 8, manifest.sublist(0, 8));
  out.setRange(8, 8 + fake.length, fake);
  out.setRange(8 + fake.length, out.length, manifest.sublist(8));
  ByteData.sublistView(out).setUint32(4, out.length, Endian.little);
  return out;
}

Future<String> _writeApk(Uint8List manifest) async {
  final source = File(_fixture).readAsBytesSync();
  final original = ZipDecoder().decodeBytes(source);
  final rebuilt = Archive();
  for (final file in original.files) {
    final content = file.name == 'AndroidManifest.xml'
        ? manifest
        : (file.content as List<int>);
    rebuilt.addFile(ArchiveFile(file.name, content.length, content));
  }
  final temp = Directory.systemTemp.createTempSync('axml_prefix');
  final path = '${temp.path}/prefix.apk';
  File(path).writeAsBytesSync(ZipEncoder().encode(rebuilt));
  return path;
}

Uint8List _originalManifest() {
  final original = ZipDecoder().decodeBytes(File(_fixture).readAsBytesSync());
  return Uint8List.fromList(
      original.findFile('AndroidManifest.xml')!.content as List<int>);
}

void main() {
  test('78 个诱饵 chunk 后仍能解析出完整清单，并把跳过的事实写进 note', () async {
    final padded = _withDecoyPrefix(_originalManifest(), count: 78);
    final path = await _writeApk(padded);
    final reader = ApkReader();
    try {
      expect((await reader.open(path)).isOk, isTrue);
      final meta = await reader.parse();
      expect(meta, isNotNull);
      expect(reader.manifestFailure, isNull);
      expect(meta!.manifestUnparsed, isFalse);

      // 期望值来自 aapt2 dump badging，不取自本项目解析器。
      expect(meta.packageName, 'com.example.extrafixture');
      expect(meta.versionName, '3.0');
      expect(meta.versionCode, 3);
      expect(meta.minSdkVersion, 21);
      expect(meta.targetSdkVersion, 29);

      final notes = meta.manifestLayoutNotes
          .where((n) => n.code == 'android.manifest.string_pool_prefix')
          .toList();
      expect(notes, hasLength(1));
      expect(notes.single.args['count'], 78);
      // 8 + 78 * 848 = 0x10268，与真实加固样本的偏移一致。
      expect(notes.single.args['offset'], 0x10268);
      expect(meta.manifestLayoutAnomalies.join('\n'),
          contains('non-standard chunk(s) preceded'));
    } finally {
      reader.close();
      File(path).parent.deleteSync(recursive: true);
    }
  });

  test('decompressXml（矢量图/自适应图标那条链路）同样跳过诱饵', () {
    final padded = _withDecoyPrefix(_originalManifest(), count: 3);
    final xml = BinaryXmlDecompressor().decompressXml(padded);
    expect(xml, contains('<manifest'));
    expect(xml, contains('com.example.extrafixture'));
  });

  test('跳过数量超上限时拒绝解析，不把畸形文件当成正常清单', () {
    final padded = _withDecoyPrefix(
      _originalManifest(),
      count: BinaryXmlDecompressor.maxPrefixChunks + 1,
      chunkSize: 8,
    );
    final meta = ManifestParser.parse(padded);
    expect(meta.manifestUnparsed, isTrue);
    expect(meta.manifestParseFailure, contains('Too many chunks'));
  });

  test('诱饵 chunk 声明的尺寸越界时拒绝解析', () {
    final padded = _withDecoyPrefix(
      _originalManifest(),
      count: 1,
      declaredSize: 4,
    );
    final meta = ManifestParser.parse(padded);
    expect(meta.manifestUnparsed, isTrue);
    expect(
        meta.manifestParseFailure, contains('Invalid String table identifier'));
  });

  test('诱饵 chunk 说明走本地化，不退回英文原文', () async {
    await LocaleSettings.setLocaleRaw('zh-CN');
    const note = AnalysisNote(
      'android.manifest.string_pool_prefix',
      'english fallback',
      {'count': 78, 'offset': 0x10268},
    );
    final text = AnalysisReport.limitationNoteText(note, t);
    expect(text, contains('78'));
    expect(text, contains('66152'));
    expect(text, isNot(contains('english fallback')));
    expect(text, isNot(contains('{')));
    await LocaleSettings.setLocaleRaw('en');
  });

  // 真实加固样本不入库（29 MB 且含用户数据）；设置环境变量即可复跑。
  final sample = Platform.environment['APPINFOTOOL_HARDENED_APK'];
  test(
    '真实加固样本：manifest 完整解析且跳过 78 个诱饵 chunk',
    () async {
      final reader = ApkReader();
      try {
        expect((await reader.open(sample!)).isOk, isTrue);
        final meta = await reader.parse();
        expect(meta, isNotNull);
        expect(meta!.manifestUnparsed, isFalse);
        // aapt2 dump badging 的独立核对结果。
        expect(meta.packageName, 'com.jKJNPisqzojujqpK.yBjYcgXuuZmrJjjk');
        expect(meta.versionName, '3.8.7.0');
        expect(meta.versionCode, 178649800);
        expect(meta.permissions, contains('android.permission.INTERNET'));
        final note = meta.manifestLayoutNotes
            .where((n) => n.code == 'android.manifest.string_pool_prefix')
            .toList();
        expect(note, hasLength(1));
        expect(note.single.args['count'], 78);
        expect(note.single.args['offset'], 0x10268);
      } finally {
        reader.close();
      }
    },
    skip: sample == null || sample.isEmpty
        ? '未设置 APPINFOTOOL_HARDENED_APK，真实样本用例跳过'
        : null,
  );
}
