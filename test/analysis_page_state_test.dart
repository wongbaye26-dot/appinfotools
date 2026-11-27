import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/pages/info_page.dart';
import 'package:apk_info_tool/providers/info_page_provider.dart';
import 'package:apk_info_tool/utils/analysis_page_status.dart';
import 'package:apk_info_tool/widgets/detail_tab_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Future<ProviderContainer> _pumpPage(
  WidgetTester tester, {
  FileState? state,
  bool parsing = false,
}) async {
  tester.view.physicalSize = const Size(1200, 6000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer();
  addTearDown(container.dispose);
  if (state != null) {
    container.read(currentFileStateProvider.notifier).update(state);
    if (state.apkInfo != null) {
      container.read(currentApkInfoProvider.notifier).update(state.apkInfo);
    }
  }
  container.read(isParsingProvider.notifier).update(parsing);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: TranslationProvider(
        child: const MaterialApp(home: Scaffold(body: APKInfoPage())),
      ),
    ),
  );
  await tester.pump();
  return container;
}

void main() {
  group('resolveAnalysisPageStatus', () {
    test('没有文件是 empty', () {
      expect(
        resolveAnalysisPageStatus(
          filePath: null,
          isParsing: false,
          hasParsedResult: false,
          parsePartial: false,
          hasFailure: false,
        ),
        AnalysisPageStatus.empty,
      );
    });

    test('已选文件、解析中、尚无结果是 loading', () {
      expect(
        resolveAnalysisPageStatus(
          filePath: '/tmp/a.apk',
          isParsing: true,
          hasParsedResult: false,
          parsePartial: false,
          hasFailure: false,
        ),
        AnalysisPageStatus.loading,
      );
    });

    test('已有结果时失败标记不能把成功页替换掉', () {
      expect(
        resolveAnalysisPageStatus(
          filePath: '/tmp/a.apk',
          isParsing: false,
          hasParsedResult: true,
          parsePartial: false,
          hasFailure: true,
        ),
        AnalysisPageStatus.success,
      );
    });

    test('结果存在但解析有缺口是 partial', () {
      expect(
        resolveAnalysisPageStatus(
          filePath: '/tmp/a.apk',
          isParsing: false,
          hasParsedResult: true,
          parsePartial: true,
          hasFailure: false,
        ),
        AnalysisPageStatus.partial,
      );
    });

    test('已选文件、解析结束、无结果、无显式失败仍是 failure', () {
      expect(
        resolveAnalysisPageStatus(
          filePath: '/tmp/a.apk',
          isParsing: false,
          hasParsedResult: false,
          parsePartial: false,
          hasFailure: false,
        ),
        AnalysisPageStatus.failure,
      );
    });
  });

  group('分析页状态', () {
    testWidgets('空态显示打开入口，而不是一屏详情占位', (tester) async {
      await _pumpPage(tester);

      expect(find.text(t.analysis_state.empty_title), findsOneWidget);
      expect(find.text(t.analysis_state.empty_action), findsOneWidget);
      expect(find.byType(DetailTabView), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('解析中显示加载态，不渲染详情占位', (tester) async {
      await _pumpPage(
        tester,
        state: FileState(filePath: '/tmp/a.apk', fileSize: 10),
        parsing: true,
      );

      expect(find.text(t.analysis_state.loading_title), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(DetailTabView), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('文件不存在时显示失败态和重试入口', (tester) async {
      await _pumpPage(tester);
      final dynamic pageState = tester.state(find.byType(APKInfoPage));
      pageState.openApk('/definitely/not/found/app.apk');
      await tester.pump();

      expect(find.text(t.analysis_state.failure_title), findsOneWidget);
      expect(find.text(t.analysis_state.file_not_found), findsOneWidget);
      expect(find.text(t.analysis_state.retry), findsOneWidget);
      expect(find.byType(DetailTabView), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('部分解析时保留详情，同时给出页面级部分提示', (tester) async {
      final info = ApkInfo()..parseFailureReason = 'manifest unreadable';
      final state = FileState(
        filePath: '/tmp/a.apk',
        fileSize: 10,
        apkInfo: info,
      );
      await _pumpPage(tester, state: state);

      expect(find.text(t.analysis_state.partial_title), findsOneWidget);
      expect(find.byType(DetailTabView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
