import 'dart:typed_data';

import 'der.dart';

/// 一张 X.509 证书的**公开信息**。
///
/// 只取四样东西：主体 CN、签发者 CN、有效期、序列号。取它们的目的是回答
/// 「签名里带了哪些证书、是谁签的、什么时候过期」—— **不是**验证证书。
///
/// 本包**不实现任何签名算法**，也不做链式信任判断（规范 5.5）。这里的
/// [isAppleIssued] 只是一个**字符串启发式**（签发者 CN 里是否含 `Apple`），
/// 它能回答「看起来是不是 Apple 签的」，**不能**回答「这张证书可信」。
class X509CertificateInfo {
  /// 主体 CN（`2.5.4.3`）；取不到时为 `null`。
  final String? subjectCommonName;

  /// 签发者 CN；取不到时为 `null`。
  final String? issuerCommonName;

  final DateTime? notBefore;
  final DateTime? notAfter;

  /// 序列号的十六进制形式（大写，无分隔）；读不出来时为 `null`。
  final String? serialNumberHex;

  const X509CertificateInfo({
    this.subjectCommonName,
    this.issuerCommonName,
    this.notBefore,
    this.notAfter,
    this.serialNumberHex,
  });

  /// 签发者 CN 里是否含 `Apple`。
  ///
  /// **这是启发式，不是结论**：真正的信任判断要看签名与系统信任链，
  /// 本包不做。用途仅限于「在报告里说清这张证书自称是谁签的」。
  bool get issuerLooksLikeApple {
    final issuer = issuerCommonName;
    return issuer != null && issuer.contains('Apple');
  }

  @override
  String toString() => 'X509CertificateInfo(subject: $subjectCommonName, '
      'issuer: $issuerCommonName, notAfter: $notAfter)';
}

/// X.509 解析的入口。
class X509Parser {
  X509Parser._();

  /// `id-at-commonName`。
  static const String _commonNameOid = '2.5.4.3';

  /// 解析一张 DER 编码的证书。**畸形输入返回 `null`，不抛异常**。
  static X509CertificateInfo? parse(Uint8List der) {
    final reader = DerReader(der);
    final certificate = reader.at(0);
    if (certificate == null || !certificate.isUniversalTag(DerTag.sequence)) {
      return null;
    }

    final certChildren = reader.children(certificate);
    if (certChildren.isEmpty) return null;
    final tbs = certChildren.first;
    if (!tbs.isUniversalTag(DerTag.sequence)) return null;

    final fields = reader.children(tbs);
    if (fields.isEmpty) return null;

    // 可选的前导 `[0] version`：有就跳过。
    var index = 0;
    if (fields[index].tagClass == 2 && fields[index].tagNumber == 0) {
      index++;
    }

    // 顺序固定：serialNumber, signature, issuer, validity, subject。
    String? serialHex;
    if (index < fields.length && fields[index].isUniversalTag(DerTag.integer)) {
      serialHex = _serialHex(reader.content(fields[index]));
      index++;
    }
    index++; // signature AlgorithmIdentifier
    if (index >= fields.length) return null;

    final issuer = _readCommonName(reader, fields[index]);
    index++;
    if (index >= fields.length) return null;

    final (notBefore, notAfter) = _readValidity(reader, fields[index]);
    index++;
    if (index >= fields.length) return null;

    final subject = _readCommonName(reader, fields[index]);

    return X509CertificateInfo(
      subjectCommonName: subject,
      issuerCommonName: issuer,
      notBefore: notBefore,
      notAfter: notAfter,
      serialNumberHex: serialHex,
    );
  }

  /// 从 `Name` 里取 CN。
  ///
  /// `Name ::= SEQUENCE OF SET OF SEQUENCE { type OID, value ANY }` ——
  /// 多值 RDN 是合法的，这里取**第一个** CN，不做拼接。
  static String? _readCommonName(DerReader reader, DerElement name) {
    if (!name.isUniversalTag(DerTag.sequence)) return null;
    for (final rdn in reader.children(name, max: 64)) {
      if (!rdn.isUniversalTag(DerTag.set)) continue;
      for (final attribute in reader.children(rdn, max: 64)) {
        if (!attribute.isUniversalTag(DerTag.sequence)) continue;
        final parts = reader.children(attribute, max: 8);
        if (parts.length < 2) continue;
        if (!parts[0].isUniversalTag(DerTag.oid)) continue;
        if (reader.oid(parts[0]) != _commonNameOid) continue;
        final value = reader.text(parts[1]);
        if (value.isNotEmpty) return value;
      }
    }
    return null;
  }

  /// 读 `Validity ::= SEQUENCE { notBefore Time, notAfter Time }`。
  static (DateTime?, DateTime?) _readValidity(
    DerReader reader,
    DerElement validity,
  ) {
    if (!validity.isUniversalTag(DerTag.sequence)) return (null, null);
    final times = reader.children(validity, max: 4);
    if (times.length < 2) return (null, null);
    return (_readTime(reader, times[0]), _readTime(reader, times[1]));
  }

  /// 读 UTCTime（`YYMMDDHHMMSSZ`）或 GeneralizedTime（`YYYYMMDDHHMMSSZ`）。
  ///
  /// 只接受 `Z`（UTC）结尾的形式 —— 带时区偏移的写法在证书里极少见，
  /// 猜错了会把有效期算错，宁可返回 `null` 让它显示成「读不出来」。
  static DateTime? _readTime(DerReader reader, DerElement element) {
    final raw = reader.text(element).trim();
    if (!raw.endsWith('Z')) return null;
    final digits = raw.substring(0, raw.length - 1);
    if (!RegExp(r'^\d+$').hasMatch(digits)) return null;

    int year;
    int rest;
    if (element.isUniversalTag(DerTag.generalizedTime) && digits.length >= 14) {
      year = int.parse(digits.substring(0, 4));
      rest = 4;
    } else if (digits.length >= 12) {
      // UTCTime：两位年。`00`–`49` 是 2000 年代，`50`–`99` 是 1900 年代
      //（RFC 5280 的规定）。
      final two = int.parse(digits.substring(0, 2));
      year = two < 50 ? 2000 + two : 1900 + two;
      rest = 2;
    } else {
      return null;
    }

    final month = int.parse(digits.substring(rest, rest + 2));
    final day = int.parse(digits.substring(rest + 2, rest + 4));
    final hour = int.parse(digits.substring(rest + 4, rest + 6));
    final minute = int.parse(digits.substring(rest + 6, rest + 8));
    final second = int.parse(digits.substring(rest + 8, rest + 10));

    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    if (hour > 23 || minute > 59 || second > 60) return null;

    try {
      return DateTime.utc(year, month, day, hour, minute, second);
    } catch (_) {
      return null;
    }
  }

  /// 序列号的十六进制形式。
  ///
  /// **去掉 DER 的前导补零**：INTEGER 的最高位为 1 时会补一个 `0x00`，
  /// 以免被读成负数，因此原始字节比数值多一位。用户与 `openssl` 看到的是
  /// **数值**（`9D872EE17763407E`，而不是 `009D872EE17763407E`）。
  /// 只留至少一个字节，避免序列号恰为 0 时输出空串。
  static String _serialHex(Uint8List content) {
    var start = 0;
    while (start < content.length - 1 && content[start] == 0) {
      start++;
    }
    final buffer = StringBuffer();
    for (var i = start; i < content.length; i++) {
      buffer.write(content[i].toRadixString(16).padLeft(2, '0').toUpperCase());
    }
    return buffer.toString();
  }
}
