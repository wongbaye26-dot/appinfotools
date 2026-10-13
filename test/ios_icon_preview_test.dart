// iOS 图标预览的测试（规范 5.3）。
//
// 两件事必须被钉死：
// 1. **不解码不该解码的东西** —— 超预算的图在分配内存之前就被拒绝；
// 2. **找不到图时说明原因**，而不是留一个空白框 —— 空白框会被读成
//    「这个包没有图标」。
//
// 真实 PNG 用仓库内的 `assets/image/icon.png`；超预算的样本只能手工造
// 头部（没有工具能生成一张 20000×20000 的真图，也不该为了测试去生成）。

import 'dart:io';
import 'dart:typed_data';

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/ios_icon_decoder.dart';
import 'package:apk_info_tool/widgets/ios_icon_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart'
    show
        IosIconCandidate,
        IosIconResolution,
        IosIconSource,
        IosImageFormat,
        IosUnresolvedIcon;

Uint8List _realPng() {
  final file = File('assets/image/icon.png');
  expect(file.existsSync(), isTrue, reason: '缺少测试样本 assets/image/icon.png');
  return file.readAsBytesSync();
}

/// 构造一个 PNG 头部，只够读出宽高（`readPngDimensions` 需要到 IHDR）。
Uint8List _pngHeaderWithSize(int width, int height) {
  final bytes = BytesBuilder();
  bytes.add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]); // 魔数
  bytes.add(const [0x00, 0x00, 0x00, 0x0D]); // 长度 13
  bytes.add('IHDR'.codeUnits); // 类型
  bytes.add([
    (width >> 24) & 0xFF,
    (width >> 16) & 0xFF,
    (width >> 8) & 0xFF,
    width & 0xFF,
    (height >> 24) & 0xFF,
    (height >> 16) & 0xFF,
    (height >> 8) & 0xFF,
    height & 0xFF,
    0x08,
    0x06,
    0x00,
    0x00,
    0x00,
  ]);
  bytes.add(const [0x00, 0x00, 0x00, 0x00]); // CRC（占位）
  return bytes.takeBytes();
}

IosIconCandidate _candidate({
  Uint8List? bytes,
  IosImageFormat format = IosImageFormat.png,
  int? width,
  int? height,
  String path = 'Payload/Example.app/Icon@2x.png',
  IosIconSource source = IosIconSource.primaryIconFiles,
}) =>
    IosIconCandidate(
      source: source,
      relativePath: path.split('/').last,
      archivePath: path,
      size: bytes?.length ?? 0,
      format: format,
      pixelWidth: width,
      pixelHeight: height,
      bytes: bytes,
    );

Future<void> _pumpPreview(
  WidgetTester tester,
  IosIconResolution resolution,
) async {
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Scaffold(body: IosIconPreview(resolution: resolution)),
      ),
    ),
  );
  // 不能用 `pumpAndSettle`：解码过程中会显示一个 CircularProgressIndicator，
  // 它永远在动，pumpAndSettle 会一直等下去直到超时。
  //
  // 图片解码走的是引擎的真实异步，因此要在 `runAsync` 里给它真实时间。
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
  });
  await tester.pump();
}

void main() {
  group('IosIconDecoder — 解码预算', () {
    test('真实的 PNG 能被解码', () async {
      final result = await IosIconDecoder.decode(_candidate(
        bytes: _realPng(),
        width: 512,
        height: 512,
      ));

      expect(result.hasImage, isTrue, reason: result.failure);
      expect(result.image!.width, greaterThan(0));
      result.image!.dispose();
    });

    test('像素数超预算时拒绝解码，且原因里给出尺寸', () async {
      // 20000×20000 = 4 亿像素，按 RGBA 算是 1.6 GB。
      // 关键：**必须在解码之前**拒绝 —— 解完再检查，内存已经分配了。
      final result = await IosIconDecoder.decode(_candidate(
        bytes: _pngHeaderWithSize(20000, 20000),
        width: 20000,
        height: 20000,
      ));

      expect(result.hasImage, isFalse);
      expect(result.failure, contains('20000x20000'));
      expect(result.failure, contains('decode budget'));
    });

    test('宽或高为 0 时拒绝，而不是交给解码器', () async {
      final result = await IosIconDecoder.decode(_candidate(
        bytes: _pngHeaderWithSize(0, 100),
        width: 0,
        height: 100,
      ));

      expect(result.hasImage, isFalse);
      expect(result.failure, contains('zero or negative'));
    });

    test('预算边界：正好等于上限时允许', () async {
      // 只验证判定逻辑不把「等于上限」误判为超限，因此不真的解码
      // 这么大的图 —— 用一个不可能解码成功的畸形字节，看它走到哪一步。
      const side = 4096;
      final result = await IosIconDecoder.decode(_candidate(
        bytes: _pngHeaderWithSize(side, side),
        width: side,
        height: side,
      ));

      // 预算内的图会进入解码；这些字节是畸形的，因此应当是**解码失败**
      // 而不是**预算拒绝** —— 两者的原因不同。
      expect(result.hasImage, isFalse);
      expect(result.failure, isNot(contains('decode budget')));
    });

    test('字节未被携带时给出明确原因，而不是当作「没有图标」', () async {
      final result = await IosIconDecoder.decode(_candidate(
        bytes: null,
        width: 512,
        height: 512,
      ));

      expect(result.hasImage, isFalse);
      expect(result.failure, contains('did not carry'));
    });

    test('空字节同样被拒绝', () async {
      final result = await IosIconDecoder.decode(_candidate(
        bytes: Uint8List(0),
      ));

      expect(result.hasImage, isFalse);
      expect(result.failure, contains('did not carry'));
    });

    test('HEIC 之类不可解码的格式被拒绝，且明确说明没有找替代图', () async {
      final result = await IosIconDecoder.decode(_candidate(
        bytes: _realPng(),
        format: IosImageFormat.heic,
        width: 512,
        height: 512,
      ));

      expect(result.hasImage, isFalse);
      expect(result.failure, contains('HEIC'));
      expect(result.failure, contains('no substitute'));
    });

    test('损坏的 PNG 不会抛异常，而是返回失败原因', () async {
      final result = await IosIconDecoder.decode(_candidate(
        bytes: Uint8List.fromList(_realPng().sublist(0, 40)),
        width: 512,
        height: 512,
      ));

      expect(result.hasImage, isFalse);
      expect(result.failure, isNotNull);
    });
  });

  group('IosIconPreview — 渲染', () {
    testWidgets('完全没有图标信息时说明「未找到」，而不是留空', (tester) async {
      await _pumpPreview(tester, const IosIconResolution());

      expect(
          find.textContaining('no previewable icon resource'), findsOneWidget);
    });

    testWidgets('有候选时显示文件名、尺寸与归档路径', (tester) async {
      await _pumpPreview(
        tester,
        IosIconResolution(candidates: [
          _candidate(
            bytes: _realPng(),
            width: 512,
            height: 512,
          ),
        ]),
      );

      expect(find.textContaining('Icon@2x.png'), findsWidgets);
      expect(find.textContaining('512x512'), findsOneWidget);
      // 归档路径也要给出来 —— 排查时需要它。
      expect(
          find.textContaining('Payload/Example.app/Icon@2x.png'), findsWidgets);
    });

    testWidgets('声明了但取不到的条目会连同原因一起显示', (tester) async {
      await _pumpPreview(
        tester,
        const IosIconResolution(unresolved: [
          IosUnresolvedIcon(
            source: IosIconSource.assetCatalogName,
            declared: 'AppIcon',
            reason: 'the icon lives in Assets.car and cannot be previewed',
          ),
        ]),
      );

      expect(
          find.textContaining('declared but not resolvable'), findsOneWidget);
      expect(find.textContaining('AppIcon'), findsOneWidget);
      expect(find.textContaining('Assets.car'), findsOneWidget);
    });

    testWidgets('解码失败时在图片位置显示原因', (tester) async {
      await _pumpPreview(
        tester,
        IosIconResolution(candidates: [
          _candidate(
            bytes: Uint8List.fromList(_realPng().sublist(0, 40)),
            width: 512,
            height: 512,
          ),
        ]),
      );

      expect(find.textContaining('could not be decoded'), findsWidgets);
    });

    testWidgets('多个候选时只预览最大的，其余列出文件名', (tester) async {
      await _pumpPreview(
        tester,
        IosIconResolution(candidates: [
          _candidate(
            bytes: _realPng(),
            width: 512,
            height: 512,
          ),
          _candidate(
            bytes: _realPng(),
            width: 256,
            height: 256,
            path: 'Payload/Example.app/Icon@3x.png',
          ),
        ]),
      );

      expect(find.textContaining('other candidates'), findsOneWidget);
      expect(find.textContaining('Icon@3x.png'), findsOneWidget);
      expect(find.textContaining('256x256'), findsOneWidget);
    });
  });
}
