import 'dart:convert';

import '../gen/strings.g.dart';

/// 自包含 HTML 报告（真实数据，无外部资源）。
///
/// 输入是 `AnalysisReport.renderJson` 的同一份结构化报告，因此 HTML 与
/// JSON/Markdown 不会各算一遍结论。只做渲染，不解释、不补数据。
class HtmlReport {
  const HtmlReport._();

  static String render(Map<String, dynamic> data, Translations t) {
    final input = _map(data['inputArtifact']);
    final app = _map(data['application']);
    final summary = _map(data['securitySummary']);
    final counts = _map(summary['counts']);
    final findings = _list(data['findings']);
    final coverage = _map(data['coverage']);
    final network = _map(data['network']);
    final artifacts = _map(_map(data['security'])['artifacts']);
    final graph = _map(_map(data['security'])['loadGraph']);

    final b = StringBuffer();
    b.writeln('<!doctype html>');
    b.writeln('<html lang="zh-CN"><head><meta charset="utf-8">');
    b.writeln(
        '<meta name="viewport" content="width=device-width, initial-scale=1">');
    b.writeln(
        '<title>${_e(app['appName'] ?? input['fileName'] ?? 'AppInfoTool Report')}</title>');
    b.writeln('<style>');
    b.writeln('''
:root{--ink:#16151b;--muted:#5f5c67;--line:#e5e1d8;--paper:#f4f2ee;--card:#fff;--violet:#6a57f2;--red:#b42318;--amber:#9a5b00;--green:#0b7a57}
*{box-sizing:border-box}body{margin:0;background:var(--paper);color:var(--ink);font:14px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC",sans-serif}
main{max-width:1040px;margin:0 auto;padding:40px 28px 64px}
header{border-bottom:2px solid var(--ink);padding-bottom:18px;margin-bottom:24px}
h1{font-size:30px;letter-spacing:-.8px;margin:0 0 6px}h2{font-size:17px;margin:30px 0 10px}
.meta{color:var(--muted);font:12px/1.7 ui-monospace,SFMono-Regular,Menlo,monospace;word-break:break-all}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;margin:18px 0}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px}
.num{font:700 24px/1.1 ui-monospace,monospace}.label{color:var(--muted);font-size:11px}
table{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--line);border-radius:12px;overflow:hidden}
th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line);vertical-align:top;font-size:12px}
th{background:#faf9f6;color:var(--muted);font-weight:600}tr:last-child td{border-bottom:0}
code{font:11px/1.5 ui-monospace,monospace;word-break:break-all}
.tag{display:inline-block;border:1px solid var(--line);border-radius:999px;padding:1px 7px;font:10px/1.6 ui-monospace,monospace}
.high{color:var(--red);font-weight:700}.review{color:var(--amber);font-weight:700}.info{color:var(--green)}
.note{color:var(--muted);font-size:12px;margin-top:8px}
footer{margin-top:36px;border-top:1px solid var(--line);padding-top:12px;color:var(--muted);font-size:11px}
''');
    b.writeln('</style></head><body><main>');
    b.writeln('<header><div class="meta">${_e(t.html_report.title)}</div>');
    b.writeln(
        '<h1>${_e(app['appName'] ?? input['fileName'] ?? t.html_report.unnamed)}</h1>');
    b.writeln(
        '<div class="meta">${_e(app['packageId'] ?? '—')} · ${_e(app['version'] ?? '—')} · ${_e(app['platform'] ?? '—')}<br>');
    b.writeln(
        '${_e(t.html_report.file)} ${_e(input['fileName'] ?? '—')} · ${_fmtBytes(input['sizeBytes'])}<br>');
    b.writeln('${_e(t.html_report.sha)} ${_e(input['sha256'] ?? '—')}<br>');
    b.writeln(
        '${_e(t.html_report.generated)} ${_e(data['generatedAt'] ?? '—')} · ${_e(t.html_report.schema)} ${_e(data['reportSchemaVersion'])}</div></header>');

    b.writeln('<div class="cards">');
    b.writeln(_card(_e(counts['high'] ?? 0), 'HIGH'));
    b.writeln(_card(_e(counts['review'] ?? 0), 'REVIEW'));
    b.writeln(_card(_e(counts['info'] ?? 0), 'INFO'));
    b.writeln(_card(_e(summary['coverageGapCount'] ?? 0), 'COVERAGE GAPS'));
    b.writeln('</div>');
    b.writeln(
        '<div class="note">${_e(summary['includesRuntimeEvidence'] == true ? t.html_report.runtime_note : t.html_report.static_note)}</div>');

    b.writeln('<h2>${_e(t.html_report.findings)}</h2>');
    if (findings.isEmpty) {
      b.writeln('<p class="note">${_e(t.html_report.no_findings)}</p>');
    } else {
      b.writeln(
          '<table><thead><tr><th>严重度</th><th>规则</th><th>结论</th><th>证据</th></tr></thead><tbody>');
      for (final item in findings) {
        final f = _map(item);
        final sev = _e(f['severity'] ?? '');
        b.writeln('<tr><td class="$sev">${sev.toUpperCase()}</td>');
        b.writeln(
            '<td><code>${_e(f['ruleId'] ?? '—')}</code><br><span class="tag">${_e(f['confidence'] ?? '')}</span></td>');
        b.writeln('<td>${_e(f['finding'] ?? '')}</td>');
        b.writeln('<td>${_evidenceList(f['evidence'], t)}</td></tr>');
      }
      b.writeln('</tbody></table>');
    }

    b.writeln('<h2>${_e(t.html_report.coverage)}</h2>');
    final entries = _list(coverage['entries']);
    if (entries.isEmpty) {
      b.writeln('<p class="note">${_e(t.html_report.no_coverage)}</p>');
    } else {
      b.writeln(
          '<table><thead><tr><th>维度</th><th>状态</th><th>覆盖 / 上限</th><th>说明</th></tr></thead><tbody>');
      for (final item in entries) {
        final c = _map(item);
        b.writeln(
            '<tr><td><code>${_e(c['id'] ?? '')}</code></td><td>${_e(c['status'] ?? '')}</td>');
        b.writeln(
            '<td>${_e(c['covered'] ?? 0)} / ${_e(c['limit'] ?? '—')}</td><td>${_e(c['note'] ?? '')}</td></tr>');
      }
      b.writeln('</tbody></table>');
    }

    final clues = _list(network['clues']);
    b.writeln('<h2>${_e(t.html_report.network)}</h2>');
    if (clues.isEmpty) {
      b.writeln('<p class="note">${_e(t.html_report.no_network)}</p>');
    } else {
      b.writeln(
          '<table><thead><tr><th>类型</th><th>值</th><th>来源</th></tr></thead><tbody>');
      for (final item in clues) {
        final c = _map(item);
        b.writeln(
            '<tr><td><span class="tag">${_e(c['type'] ?? '')}</span></td>');
        b.writeln(
            '<td><code>${_e(c['value'] ?? '')}</code></td><td><code>${_e(c['sourcePath'] ?? '—')}</code></td></tr>');
      }
      b.writeln(
          '</tbody></table><div class="note">${_e(t.html_report.network_limitation)}</div>');
    }

    final inv = _map(artifacts);
    final g = _map(graph);
    b.writeln('<h2>${_e(t.html_report.structure)}</h2>');
    b.writeln('<div class="cards">');
    b.writeln(_card(_e(inv['totalEntries'] ?? 0), 'ZIP ENTRIES'));
    b.writeln(_card(_e(inv['inventoriedEntries'] ?? 0), 'SECURITY ARTIFACTS'));
    b.writeln(_card(_e(_list(g['nodes']).length), 'LOAD NODES'));
    b.writeln(_card(_e(_list(g['edges']).length), 'LOAD EDGES'));
    b.writeln('</div>');

    b.writeln('<footer>${_e(t.html_report.footer)}</footer>');
    b.writeln('</main></body></html>');
    return b.toString();
  }

  static String _card(String num, String label) =>
      '<div class="card"><div class="num">$num</div><div class="label">$label</div></div>';

  static String _evidenceList(Object? raw, Translations t) {
    final list = _list(raw);
    if (list.isEmpty) {
      return '<span class="note">${_e(t.html_report.no_evidence)}</span>';
    }
    final b = StringBuffer();
    for (final item in list.take(6)) {
      final e = _map(item);
      b.write('<div><code>${_e(e['source'] ?? '')}</code> ');
      b.write('<code>${_e(e['location'] ?? '')}</code>');
      final detail = e['detail'];
      if (detail != null && '$detail'.isNotEmpty) {
        b.write('<br><span class="note">${_e(detail)}</span>');
      }
      b.write('</div>');
    }
    if (list.length > 6) {
      b.write(
          '<div class="note">${_e(t.html_report.more_evidence(count: list.length - 6))}</div>');
    }
    return b.toString();
  }

  static String _fmtBytes(Object? raw) {
    final n = raw is num ? raw.toInt() : int.tryParse('$raw') ?? 0;
    if (n <= 0) return '—';
    if (n >= 1024 * 1024) return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
    if (n >= 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '$n B';
  }

  static Map<String, dynamic> _map(Object? raw) =>
      raw is Map ? raw.cast<String, dynamic>() : const {};

  static List<Object?> _list(Object? raw) => raw is List ? raw : const [];

  static String _e(Object? raw) => const HtmlEscape().convert('${raw ?? ''}');
}
