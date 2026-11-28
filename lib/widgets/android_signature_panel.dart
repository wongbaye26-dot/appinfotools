import 'package:flutter/material.dart';
import 'package:ipa_parser/ipa_parser.dart' show X509CertificateInfo, X509Parser;

import '../gen/strings.g.dart';
import '../utils/signature_analyzer.dart';
import 'copy_icon_button.dart';

/// Android 签名证据面板。
///
/// 数据有两路来源，界面上必须分开呈现：
/// * **本地读取**：证书字节直接从 v2/v3/v3.1 签名块或 META-INF/*.RSA 里解出，
///   不需要 apksigner。它证明「包里是哪张证书」，**不**证明签名有效。
/// * **apksigner 校验**：只有装了 Android SDK Build Tools 才有结论；没装时
///   状态是「未验证」，不能写成「无效」。
///
/// 因此每个证书卡片都标注了来源方案（v1 / v2 / v3 / v3.1），摘要卡上写清
/// 「本地读取，未验证」，避免把结构事实误读成安全结论。
class AndroidSignaturePanel extends StatelessWidget {
  const AndroidSignaturePanel({
    super.key,
    required this.signature,
    this.computing = false,
  });

  final SignatureAnalysis? signature;
  final bool computing;

  @override
  Widget build(BuildContext context) {
    final t = TranslationProvider.of(context).translations;
    final theme = Theme.of(context);
    final analysis = signature;

    if (computing) {
      return Card(
        child: ListTile(
          leading: const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          title: Text(t.apk_info.signature_info),
          subtitle: Text(t.file_info.computing_hash),
        ),
      );
    }
    if (analysis == null) {
      return Card(
        child: ListTile(
          leading: Icon(Icons.verified_outlined,
              color: theme.colorScheme.onSurfaceVariant),
          title: Text(t.apk_info.signature_info),
          subtitle: Text(t.signature.no_signature),
        ),
      );
    }

    final certificates = analysis.localCertificates;
    final schemes = <String>{
      for (final certificate in certificates) certificate.scheme,
      ...analysis.verifiedSchemes,
    }.toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SummaryCard(
          signature: analysis,
          certificates: certificates,
          schemes: schemes,
          t: t,
        ),
        if (certificates.isEmpty && analysis.signers.isNotEmpty)
          // 没有本地证书（例如设置里关了本地读取），但 apksigner 给出了
          // 证书字段：仍然展示，来源写清楚。
          for (final signer in analysis.signers)
            _ToolSignerCard(signer: signer, t: t),
        for (final certificate in certificates)
          _CertificateCard(certificate: certificate, t: t),
        if (analysis.status == SignatureStatus.verificationFailed)
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.signature.failed_generic_hint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                      height: 1.5,
                    ),
                  ),
                  if ((analysis.error ?? '').isNotEmpty) ...[
                    const SizedBox(height: 8),
                    SelectableText(
                      analysis.error!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        if (analysis.status == SignatureStatus.toolUnavailable)
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Text(
                t.signature.tool_hint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.signature,
    required this.certificates,
    required this.schemes,
    required this.t,
  });

  final SignatureAnalysis signature;
  final List<SignatureCertificate> certificates;
  final List<String> schemes;
  final Translations t;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.verified_user_outlined,
                    size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    t.apk_info.signature_info,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                _StatusChip(status: signature.status, t: t),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 132,
                  child: Text(
                    t.signature.schemes,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(
                  child: schemes.isEmpty
                      ? Text(t.signature.no_signature,
                          style: theme.textTheme.bodyMedium)
                      : Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final name in schemes)
                              _MonoChip(label: name.toUpperCase()),
                          ],
                        ),
                ),
              ],
            ),
            if (certificates.isNotEmpty) ...[
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 132,
                    child: Text(
                      t.signature.local_certificates(
                          count: '${certificates.length}'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      t.signature.local_certificate_hint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status, required this.t});

  final SignatureStatus status;
  final Translations t;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (label, color) = switch (status) {
      SignatureStatus.verified => (t.signature.status_verified, scheme.primary),
      SignatureStatus.verificationFailed =>
        (t.signature.status_failed, scheme.error),
      SignatureStatus.toolUnavailable => (
          t.signature.status_tool_unavailable,
          scheme.tertiary
        ),
      SignatureStatus.unknown => (
          t.signature.status_unknown,
          scheme.onSurfaceVariant
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _CertificateCard extends StatelessWidget {
  const _CertificateCard({required this.certificate, required this.t});

  final SignatureCertificate certificate;
  final Translations t;

  @override
  Widget build(BuildContext context) {
    final details = certificate.details;
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    t.signature.signer(index: '${certificate.signerIndex + 1}'),
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                _MonoChip(
                  label: certificate.scheme.toUpperCase(),
                  highlight: true,
                ),
              ],
            ),
            const SizedBox(height: 8),
            _SignatureRow(label: t.signature.subject, value: details.subject),
            _SignatureRow(label: t.signature.issuer, value: details.issuer),
            _SignatureRow(
              label: t.signature.serial_number,
              value: details.serialNumberHex,
            ),
            _SignatureRow(
              label: t.signature.valid_from,
              value: _timestamp(details.notBefore),
            ),
            _SignatureRow(
              label: t.signature.valid_until,
              value: _timestamp(details.notAfter),
            ),
            _SignatureRow(
              label: t.signature.key_algorithm,
              value: _keyDescription(details),
            ),
            _SignatureRow(
              label: t.signature.signature_algorithm,
              value: details.signatureAlgorithm,
            ),
            _SignatureRow(
              label: t.signature.sha256,
              value: _fingerprint(details.sha256Fingerprint),
              monospace: true,
            ),
            _SignatureRow(
              label: t.signature.sha1,
              value: _fingerprint(details.sha1Fingerprint),
              monospace: true,
            ),
            _SignatureRow(
              label: t.signature.md5,
              value: _fingerprint(details.md5Fingerprint),
              monospace: true,
            ),
          ],
        ),
      ),
    );
  }

  static String _fingerprint(String? hex) =>
      hex == null ? '-' : X509Parser.formatFingerprint(hex);

  static String _timestamp(DateTime? value) {
    if (value == null) return '-';
    final utc = value.toUtc();
    return '${utc.toIso8601String().split('.').first}Z';
  }

  static String _keyDescription(X509CertificateInfo details) {
    final algorithm = details.publicKeyAlgorithm ?? '-';
    final bits = details.publicKeyBits;
    if (bits == null) return algorithm;
    final curve = details.publicKeyCurve;
    return curve == null
        ? '$algorithm ($bits bits)'
        : '$algorithm ($bits bits, $curve)';
  }
}

/// apksigner 给出的签名者（没有本地证书时使用）。
class _ToolSignerCard extends StatelessWidget {
  const _ToolSignerCard({required this.signer, required this.t});

  final SignatureSigner signer;
  final Translations t;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.signature.signer(index: '${signer.index}'),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            _SignatureRow(label: t.signature.subject, value: signer.subjectDn),
            _SignatureRow(
              label: t.signature.sha256,
              value: signer.sha256Digest,
              monospace: true,
            ),
            if (signer.sha1Digest != null)
              _SignatureRow(
                label: t.signature.sha1,
                value: signer.sha1Digest,
                monospace: true,
              ),
            _SignatureRow(
              label: t.signature.key_algorithm,
              value: [
                signer.keyAlgorithm ?? '-',
                if (signer.keySizeBits != null) '${signer.keySizeBits} bits',
              ].join(' · '),
            ),
            if (signer.validity != null)
              _SignatureRow(
                label: t.signature.validity,
                value: signer.validity,
              ),
          ],
        ),
      ),
    );
  }
}

class _SignatureRow extends StatelessWidget {
  const _SignatureRow({
    required this.label,
    required this.value,
    this.monospace = false,
  });

  final String label;
  final String? value;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = value == null || value!.isEmpty ? '-' : value!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 132,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: monospace ? 'monospace' : null,
                fontSize: monospace ? 12 : null,
              ),
            ),
          ),
          CopyIconButton(text: text, iconSize: 14),
        ],
      ),
    );
  }
}

class _MonoChip extends StatelessWidget {
  const _MonoChip({required this.label, this.highlight = false});

  final String label;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = highlight ? scheme.primary : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: color,
        ),
      ),
    );
  }
}
