// ApkReader 阶段回报的单元测试。
//
// 进度回调是「真实进度」的契约：只有实际执行到的阶段才允许被报告，
// 没打开归档就一个都不该报。这里用不含 AndroidManifest.xml 的最小归档
// 来钉住这个契约 —— 它能在不构造 AXML 二进制样本的前提下验证阶段顺序。

import 'dart:typed_data';

import 'package:apk_parser/apk_parser.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
