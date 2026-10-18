// Android 的两处广度缺口：Camera2 直接调用、MediaProjection 录屏。
//
// ## Camera2 / Camera1
//
// 此前 Android 侧**没有任何相机 API 标记** —— 「应用能不能拍照」只能从 CAMERA
// 权限推。而权限只是声明，代码里可能根本没用；反过来用 `android.hardware.camera2`
// 的代码也可能漏了权限（那是另一个问题）。补上代码层的相机线索后，相机才会
// 参与「图像输入 + OCR」这类组合判定。
//
// ## MediaProjection
//
// 原来 `MediaProjection` 挂在 **OCR 线索**里（`screencapture`，category
// ocrImage），于是「录屏」会被算成「文字识别能力」—— 两件事完全不同：录屏是
// 抓整块屏幕画面（可含验证码、聊天记录），OCR 是识别图片里的字。
// 现在它单列一条能力发现，并且**不再**污染 OCR 线索。

import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';

ApkMeta _meta() => ApkMeta()
  ..permissionRequests = const []
  ..permissions = const []
  ..components = const [];

Uint8List _blob(List<String> strings) {
  final parts = <int>[];
  for (final s in strings) {
    parts.addAll(s.codeUnits);
    parts.add(0);
  }
  return Uint8List.fromList(parts);
}

SecurityAnalysisResult _audit(List<String> strings) =>
    AndroidSecurityAudit.audit(
      meta: _meta(),
      dexEntries: [DexBytes('classes.dex', _blob(strings))],
    );

SecurityFinding? _byId(SecurityAnalysisResult r, String ruleId) {
  for (final f in r.findings) {
    if (f.ruleId == ruleId) return f;
  }
  return null;
}

const _ocr = 'Lcom/google/mlkit/vision/text/TextRecognizer;';

void main() {
  setUpAll(() async {
    await LocaleSettings.setLocaleRaw('zh-CN');
  });

  tearDownAll(() async {
    await LocaleSettings.setLocaleRaw('en');
  });

  group('相机 API 参与「图像输入」判定', () {
    test('Camera2 线索 + OCR → 命中 RULE-B（相机也算图像输入）', () {
      final result = _audit(['Landroid/hardware/camera2/CameraManager;', _ocr]);
      expect(_byId(result, 'ANDROID-RULE-B'), isNotNull,
          reason: 'Camera2 是明确的图像输入来源，不该只靠 CAMERA 权限推断');
    });

    test('Camera1（android.hardware.Camera）+ OCR → 同样命中 RULE-B', () {
      final result = _audit(['Landroid/hardware/Camera;', _ocr]);
      expect(_byId(result, 'ANDROID-RULE-B'), isNotNull);
    });

    test('只有相机、没有 OCR → 不报 RULE-B（图像输入不等于识别）', () {
      final result = _audit(['Landroid/hardware/camera2/CameraManager;']);
      expect(_byId(result, 'ANDROID-RULE-B'), isNull);
    });
  });

  group('MediaProjection 单列，不算 OCR', () {
    test('MediaProjection → 一条 P3/independentCapability', () {
      final result = _audit(['Landroid/media/projection/MediaProjection;']);
      final finding = _byId(result, 'ANDROID-SCREEN-CAPTURE');
      expect(finding, isNotNull, reason: '录屏是高权限能力，必须单列');
      expect(finding!.severity, SecuritySeverity.p3);
      expect(finding.confidence, SecurityConfidence.independentCapability);
    });

    test('MediaProjection **不再**算作 OCR 能力', () {
      final result = _audit(['Landroid/media/projection/MediaProjection;']);
      expect(_byId(result, 'ANDROID-OCR-CAPABILITY'), isNull,
          reason: '录屏抓的是画面，不是识别文字 —— 混进 OCR 会误导读者');
    });

    test('MediaProjection + OCR → 两条独立能力，各自成立', () {
      final result = _audit([
        'Landroid/media/projection/MediaProjection;',
        _ocr,
      ]);
      expect(_byId(result, 'ANDROID-SCREEN-CAPTURE'), isNotNull);
      expect(_byId(result, 'ANDROID-OCR-CAPABILITY'), isNotNull);
    });

    test('没有 MediaProjection → 不产生这条', () {
      final result = _audit(['unrelated']);
      expect(_byId(result, 'ANDROID-SCREEN-CAPTURE'), isNull);
    });
  });

  group('措辞', () {
    test('录屏正文是中文，且说清「能力」不是「恶意」', () {
      final result = _audit(['Landroid/media/projection/MediaProjection;']);
      final text = AnalysisReport.findingText(
          _byId(result, 'ANDROID-SCREEN-CAPTURE')!, t);
      expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(text), isTrue,
          reason: '中文界面下不能显示英文回退：$text');
      // 「不是恶意结论」这句话里本来就含「恶意」二字 —— 要断言的是
      // **否定形态**存在，而不是「恶意」一词不出现。
      expect(text, contains('不是恶意结论'));
      expect(text, contains('录屏'));
    });
  });
}
