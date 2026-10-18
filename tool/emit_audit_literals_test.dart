import 'dart:io';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';

String _suffix(String path) {
  if (path.contains('nsc-fixture')) return 'Nsc';
  if (path.contains('attr-fixture')) return 'Attr';
  return 'Big';
}

String _s(Object? v) {
  if (v == null) return 'null';
  if (v is String) {
    return "'${v.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";
  }
  if (v is num || v is bool) return '$v';
  if (v is List) return '[${v.map(_s).join(', ')}]';
  if (v is Map) {
    return '{${v.entries.map((e) => '${_s(e.key)}: ${_s(e.value)}').join(', ')}}';
  }
  return "'$v'";
}

String _ev(SecurityEvidence e) =>
    'SecurityEvidence(source: SecurityEvidenceSource.${e.source.name}, '
    'location: ${_s(e.location)}, detail: ${_s(e.detail)}'
    '${e.detailCode == null ? '' : ', detailCode: ${_s(e.detailCode)}'}'
    '${e.detailArgs.isEmpty ? '' : ', detailArgs: ${_s(e.detailArgs)}'})';

void main() {
  test('emit', () async {
    final out = StringBuffer();
    final big = Platform.environment['BIG_APK'];
    for (final path in [
      'test/fixtures/apk/nsc-fixture.apk',
      'test/fixtures/apk/attr-fixture.apk',
      if (big != null) big,
    ]) {
      final reader = ApkReader();
      await reader.open(path);
      final meta = await reader.parse();
      final r = AndroidSecurityAudit.audit(meta: meta!, dexEntries: const []);
      reader.close();
      out.writeln('// ===== $path =====');
      out.writeln('const _findings${_suffix(path)} = <SecurityFinding>[');
      for (final f in r.findings) {
        out.writeln('  SecurityFinding(');
        out.writeln('    ruleId: ${_s(f.ruleId)},');
        out.writeln('    platform: SecurityPlatform.${f.platform.name},');
        out.writeln('    category: SecurityCategory.${f.category.name},');
        out.writeln('    severity: SecuritySeverity.${f.severity.name},');
        out.writeln('    confidence: SecurityConfidence.${f.confidence.name},');
        out.writeln('    finding: ${_s(f.finding)},');
        if (f.messageCode != null) {
          out.writeln('    messageCode: ${_s(f.messageCode)},');
        }
        out.writeln('    messageArgs: ${_s(f.messageArgs)},');
        out.writeln(
            '    evidence: [${f.evidence.map(_ev).join(',\n      ')}],');
        out.writeln('    limitation: ${_s(f.limitation)},');
        out.writeln('    recommendation: ${_s(f.recommendation)},');
        if (f.limitationCode != null) {
          out.writeln('    limitationCode: ${_s(f.limitationCode)},');
        }
        if (f.recommendationCode != null) {
          out.writeln('    recommendationCode: ${_s(f.recommendationCode)},');
        }
        out.writeln('  ),');
      }
      out.writeln('];');
      out.writeln();
      out.writeln('const _coverage${_suffix(path)} = <CoverageEntry>[');
      for (final c in r.coverage.entries) {
        out.writeln('  CoverageEntry(id: ${_s(c.id)}, '
            'status: CoverageStatus.${c.status.name}, '
            'covered: ${c.covered}, limit: ${c.limit}, '
            'note: ${_s(c.note)}, noteCode: ${_s(c.noteCode)}, '
            'noteArgs: ${_s(c.noteArgs)}),');
      }
      out.writeln('];');
      out.writeln();
    }
    File('/tmp/findings.dart').writeAsStringSync(out.toString());
    // ignore: avoid_print
    print('wrote ${out.length} chars');
  });
}
