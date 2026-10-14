// ApkReader 阶段回报的单元测试。
//
// 进度回调是「真实进度」的契约：只有实际执行到的阶段才允许被报告，
// 没打开归档就一个都不该报。这里用不含 AndroidManifest.xml 的最小归档
// 来钉住这个契约 —— 它能在不构造 AXML 二进制样本的前提下验证阶段顺序。

import 'dart:io';
import 'dart:typed_data';

import 'package:apk_parser/apk_parser.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

Uint8List _zip(Map<String, String> files) {
  final archive = Archive();
  files.forEach(
    (name, content) => archive.addFile(ArchiveFile.string(name, content)),
  );
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  group('ApkReader.parse 的阶段回报', () {
    test('未打开归档时不会触发任何阶段回调', () async {
      final reader = ApkReader();
      addTearDown(reader.close);

      final stages = <ApkParseStage>[];
      expect(await reader.parse(onStage: stages.add), isNull);
      expect(stages, isEmpty);
    });

    test('缺少 AndroidManifest.xml 时只报告到 manifest 阶段就停止', () async {
      final reader = ApkReader();
      addTearDown(reader.close);
      expect(reader.openBytes(_zip({'x.txt': 'hi'})).isOk, isTrue);

      final stages = <ApkParseStage>[];
      final meta = await reader.parse(onStage: stages.add);

      expect(meta, isNull);
      expect(
        stages,
        [ApkParseStage.manifest],
        reason: '没有 manifest 就不该声称进入了 resources 阶段',
      );
    });

    test('不传 onStage 时解析照常工作', () async {
      final reader = ApkReader();
      addTearDown(reader.close);
      expect(reader.openBytes(_zip({'x.txt': 'hi'})).isOk, isTrue);

      expect(await reader.parse(), isNull);
    });
  });

  // 结构异常检查必须**在流式路径上也活着**。
  //
  // `ApkReader.open(String)` 走 `ZipDecoder().decodeStream`，拿不到原始字节，
  // 于是最初只在 `openBytes` 里做的 EOCD 校验在**生产路径上是死的** ——
  // 内置引擎（worker）走的正是 `open`。这组测试钉住「流式路径也读尾部并比对」。
  group('ApkReader.open 的结构异常检查（流式路径）', () {
    /// 写一个 ZIP 到临时文件；[declaredOverride] 非空时改写 EOCD 的总条目数。
    File writeZip(Directory dir, String name, Map<String, String> files,
        {int? declaredOverride}) {
      final bytes = _zip(files);
      if (declaredOverride != null) {
        // 无注释时 EOCD 就是最后 22 字节。
        final eocd = bytes.length - 22;
        expect(bytes[eocd], 0x50, reason: '样本应当是合法 ZIP');
        // 偏移 10 是总条目数。
        bytes[eocd + 10] = declaredOverride & 0xff;
        bytes[eocd + 11] = (declaredOverride >> 8) & 0xff;
      }
      final file = File(path.join(dir.path, name));
      file.writeAsBytesSync(bytes);
      return file;
    }

    test('条目数一致的归档不报结构异常', () async {
      final dir = Directory.systemTemp.createTempSync('reader_ok');
      addTearDown(() => dir.deleteSync(recursive: true));

      final file = writeZip(dir, 'ok.apk', {'a.txt': 'a', 'b.txt': 'b'});
      final reader = ApkReader();
      addTearDown(reader.close);

      expect((await reader.open(file.path)).isOk, isTrue);
      expect(reader.structureAnomaly, isNull);
    });

    test('条目数与声明不符时记下结构异常，但**不拒绝打开**', () async {
      final dir = Directory.systemTemp.createTempSync('reader_anomaly');
      addTearDown(() => dir.deleteSync(recursive: true));

      final file =
          writeZip(dir, 'tampered.apk', {'a.txt': 'a'}, declaredOverride: 99);
      final reader = ApkReader();
      addTearDown(reader.close);

      final result = await reader.open(file.path);
      expect(
        result.isOk,
        isTrue,
        reason: '结构不一致只作为线索，不足以直接判死 —— 误报比漏报更糟',
      );
      expect(reader.structureAnomaly, isNotNull);
      expect(reader.structureAnomaly, contains('99'));
    });

    test('非 ZIP 文件不产生结构异常（避免把「不是归档」说成「归档损坏」）', () async {
      final dir = Directory.systemTemp.createTempSync('reader_notzip');
      addTearDown(() => dir.deleteSync(recursive: true));

      final file = File(path.join(dir.path, 'plain.bin'))
        ..writeAsBytesSync(List<int>.filled(200, 0x41));
      final reader = ApkReader();
      addTearDown(reader.close);

      expect((await reader.open(file.path)).isOk, isFalse);
      expect(reader.structureAnomaly, isNull);
    });
  });
}
