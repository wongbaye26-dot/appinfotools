// 一键诊断复制的内容筛选。
//
// 目标不是把整份 debug.log 塞进剪贴板，而是只留下能定位「时间花在哪一段」
// 的 PERF 行与解析起点。每帧刷新的 FINE 行会把真正有用的信息淹掉。

import 'package:apk_info_tool/utils/diagnostics_report.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const log = '''
INFO: 2026-11-26 10:00:00.000: getApkInfo: apk=[a.apk] start
FINE: 2026-11-26 10:00:00.001: _buildMoreMenuButton: state.filePath=a.apk
INFO: 2026-11-26 10:00:02.000: [PERF] getApkInfo(builtin): total=2000ms | worker [open=1 scan=2 audit=3] | spawn+transfer=4ms
INFO: 2026-11-26 10:00:03.000: [PERF] computeFileHashes: 120ms (3 isolates, file read 3×)
FINE: 2026-11-26 10:00:03.500: _buildMoreMenuButton: state.filePath=a.apk
''';

  test('只保留 PERF 与解析起点，按时间顺序输出', () {
    final out = collectDiagnostics(log);
    expect(out, contains('getApkInfo: apk=[a.apk] start'));
    expect(out, contains('worker [open=1 scan=2 audit=3]'));
    expect(out, contains('computeFileHashes: 120ms'));
    expect(out, isNot(contains('_buildMoreMenuButton')));
    expect(
      out.indexOf('start'),
      lessThan(out.indexOf('computeFileHashes')),
    );
  });

  test('没有相关行时返回空串', () {
    expect(collectDiagnostics('FINE: only noise\n'), '');
    expect(collectDiagnostics(''), '');
  });

  test('只取最新的若干条，避免剪贴板塞满旧日志', () {
    final many = List<int>.generate(100, (i) => i)
        .map((i) => 'INFO: t=$i: [PERF] line=$i')
        .join('\n');
    final out = collectDiagnostics(many, maxLines: 5);
    expect(out.split('\n').length, 5);
    expect(out, contains('line=99'));
    expect(out, isNot(contains('line=94 ')));
  });

  test('容忍 CRLF 日志', () {
    final out = collectDiagnostics('INFO: t: [PERF] x=1\r\nFINE: noise\r\n');
    expect(out, 'INFO: t: [PERF] x=1');
  });
}
