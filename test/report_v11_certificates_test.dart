// v11 报告契约：包内证书（序列号 / 有效期 / 算法 / 三种指纹）进导出结果。
//
// 为什么单独钉：这些字段此前**只在界面上**。界面能看到的证书细节，导出的
// JSON / Markdown 里没有 —— 归档后无法复现「当时这张证书长什么样」，
// 而证书会过期、包会被替换，事后补不回来。
//
// 两个层次分别验证：
// 1. `ReportExtras.collect` 能把 Android 本地证书搬进 extras；
// 2. `renderJson` 输出的字段名与空值语义（null = 没采集，[] = 采集到零张）。

import 'dart:convert';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:apk_info_tool/utils/report_extras.dart';
import 'package:apk_info_tool/utils/signature_analyzer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart' show X509CertificateInfo;

final DateTime _at = DateTime.utc(2026, 11, 28, 12, 0, 0);

/// 与 `test/fixtures/apk/signed-v2-v3.apk` 的 openssl 结果一致。
final _certificate = X509CertificateInfo(
  subject: 'CN=Fixture',
  issuer: 'CN=Fixture',
  subjectCommonName: 'Fixture',
  issuerCommonName: 'Fixture',
  notBefore: DateTime.utc(2026, 10, 18, 16, 31, 1),
  notAfter: DateTime.utc(2054, 3, 5, 16, 31, 1),
  serialNumberHex: 'DF5D287C71A19C67',
  signatureAlgorithm: 'SHA256withRSA',
  publicKeyAlgorithm: 'RSA',
  publicKeyBits: 2048,
  sha256Fingerprint:
      '3ffbedbaeb558314ee9532321acb12ffff1ac73a6eb3aad5ff76a909d1ab60dd',
  sha1Fingerprint: 'f03379ed9688b5aaa703029e45d1729702a9f085',
  md5Fingerprint: 'f378a57e06333a8588ff80ba308a0ea9',
);

PackageAnalysisResult _result({SignatureAnalysis? signature}) =>
    PackageAnalysisResult(
      platform: PackagePlatform.android,
      fileName: const FieldValue<String>.extracted(
        'example.apk',
        source: FieldSource.fileSystem,
      ),
      fileSize:
          const FieldValue<int>.extracted(2048, source: FieldSource.fileSystem),
      sha256: const FieldValue<String>.extracted('abc123',
          source: FieldSource.fileSystem),
      appName: const FieldValue<String>.extracted('Example',
          source: FieldSource.builtinParser),
      packageId: const FieldValue<String>.extracted('com.example.app',
          source: FieldSource.builtinParser),
      version: const FieldValue<String>.extracted('1.2.3',
          source: FieldSource.builtinParser),
      buildNumber: const FieldValue<String>.extracted('4',
          source: FieldSource.builtinParser),
      signatureVerdict: PackageAnalysisResult.verdictFrom(signature),
      android: AndroidPackageInfo(signature: signature),
    );

SignatureAnalysis _analysis({List<SignatureCertificate>? certificates}) =>
    SignatureAnalysis(
      status: SignatureStatus.toolUnavailable,
      verifiedSchemes: const {},
      signers: const [],
      exitCode: null,
      stdout: '',
      stderr: '',
      error: 'apksigner not found',
      toolExecuted: false,
      localCertificates: certificates ?? const [],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('collect 把 Android 本地证书搬进 extras', () async {
    final extras = await ReportExtras.collect(
      result: _result(
        signature: _analysis(certificates: [
          SignatureCertificate(
            scheme: 'v2',
            signerIndex: 0,
            details: _certificate,
          ),
        ]),
      ),
      includePermissions: false,
      includeLibraries: false,
    );

    expect(extras.certificates, isNotNull);
    expect(extras.certificates, hasLength(1));
    final fact = extras.certificates!.single;
    expect(fact.platform, 'android');
    expect(fact.scheme, 'v2');
    expect(fact.details.serialNumberHex, 'DF5D287C71A19C67');
  });

  test('没做签名分析时 certificates 是 null，不是空数组', () async {
    final extras = await ReportExtras.collect(
      result: _result(),
      includePermissions: false,
      includeLibraries: false,
    );
    expect(extras.certificates, isNull, reason: 'null 表示没采集，与「零张证书」不同');
  });

  test('renderJson 输出证书全字段', () {
    final extras = ReportExtras(
      certificates: [
        CertificateFact(
            platform: 'android',
            scheme: 'v2',
            signerIndex: 0,
            details: _certificate),
      ],
    );
    final json = jsonDecode(AnalysisReport.renderJson(
      _result(
          signature: _analysis(certificates: [
        SignatureCertificate(
            scheme: 'v2', signerIndex: 0, details: _certificate),
      ])),
      generatedAt: _at,
      t: AppLocale.en.buildSync(),
      extras: extras,
    )) as Map<String, dynamic>;

    final summary = json['signatureSummary'] as Map<String, dynamic>;
    final certificates = summary['certificates'] as List<dynamic>;
    final certificate = certificates.single as Map<String, dynamic>;
    expect(certificate['platform'], 'android');
    expect(certificate['scheme'], 'v2');
    expect(certificate['subject'], 'CN=Fixture');
    expect(certificate['issuer'], 'CN=Fixture');
    expect(certificate['serialNumber'], 'DF5D287C71A19C67');
    expect(certificate['notBefore'], '2026-10-18T16:31:01.000Z');
    expect(certificate['notAfter'], '2054-03-05T16:31:01.000Z');
    expect(certificate['signatureAlgorithm'], 'SHA256withRSA');
    expect(certificate['keyAlgorithm'], 'RSA');
    expect(certificate['keySizeBits'], 2048);
    expect(certificate['sha256'], startsWith('3ffbedba'));
    expect(certificate['sha1'], startsWith('f03379ed'));
    expect(certificate['md5'], startsWith('f378a57e'));
  });

  test('采集到零张证书时输出空数组，键仍然存在', () {
    final json = jsonDecode(AnalysisReport.renderJson(
      _result(signature: _analysis()),
      generatedAt: _at,
      t: AppLocale.en.buildSync(),
      extras: const ReportExtras(certificates: []),
    )) as Map<String, dynamic>;
    expect(
      (json['signatureSummary'] as Map<String, dynamic>)['certificates'],
      isEmpty,
    );
  });

  test('不给 extras 时 JSON 不出现 certificates 键', () {
    final json = jsonDecode(AnalysisReport.renderJson(
      _result(signature: _analysis()),
      generatedAt: _at,
      t: AppLocale.en.buildSync(),
    )) as Map<String, dynamic>;
    expect(
      (json['signatureSummary'] as Map<String, dynamic>)
          .containsKey('certificates'),
      isFalse,
    );
  });
}
