import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'der.dart';

/// 一张 X.509 证书的**公开信息**。
///
/// 取的是「读证书就能得到、不需要验证」的那部分：主体/签发者、有效期、
/// 序列号、公钥算法与长度、证书自身的三种常见指纹。目的只是回答
/// 「签名里带了哪些证书、它自称是谁签的、什么时候过期」——
/// **不是**验证证书。
///
/// 本包**不实现任何签名算法**，也不做链式信任判断（规范 5.5）。这里的
/// [issuerLooksLikeApple] 只是一个**字符串启发式**（签发者里是否含 `Apple`），
/// 它能回答「看起来是不是 Apple 签的」，**不能**回答「这张证书可信」。
class X509CertificateInfo {
  /// 主体 DN（RFC 4514 形式，例如 `CN=Android Debug, O=Android, C=US`）。
  ///
  /// 顺序与 DER 编码相反 —— 最具体的 RDN（通常是 CN）在最前，这样和
  /// `apksigner`、`openssl -nameopt RFC2253` 的输出一致。
  final String? subject;

  /// 签发者 DN，格式同 [subject]。
  final String? issuer;

  /// 主体 CN（`2.5.4.3`）；取不到时为 `null`。
  final String? subjectCommonName;

  /// 签发者 CN；取不到时为 `null`。
  final String? issuerCommonName;

  final DateTime? notBefore;
  final DateTime? notAfter;

  /// 序列号的十六进制形式（大写，无分隔）；读不出来时为 `null`。
  final String? serialNumberHex;

  /// 证书签名算法，例如 `SHA256withRSA`；未知 OID 时保留点分形式。
  final String? signatureAlgorithm;

  /// 公钥算法，例如 `RSA`、`EC`、`DSA`、`Ed25519`。
  final String? publicKeyAlgorithm;

  /// EC 公钥的命名曲线，例如 `prime256v1`；非 EC 或未知曲线时为 `null`。
  final String? publicKeyCurve;

  /// 公钥长度（位）。RSA 取模数位数，EC 取曲线位数，DSA 取 p 的位数。
  final int? publicKeyBits;

  /// 证书 DER 的 SHA-256 指纹（小写十六进制，无分隔）。
  ///
  /// 界面展示时按 `AA:BB:…` 分组（与 `apksigner` / `openssl` 一致），
  /// 存储保留原始形式，便于与其他工具的输出直接比对。
  final String? sha256Fingerprint;

  /// SHA-1 指纹（小写十六进制，无分隔）。
  final String? sha1Fingerprint;

  /// MD5 指纹（小写十六进制，无分隔）。**只作为历史对照** ——
  /// 它早已不适合用来判断碰撞，保留它是因为很多旧文档仍以 MD5 公布指纹。
  final String? md5Fingerprint;

  const X509CertificateInfo({
    this.subject,
    this.issuer,
    this.subjectCommonName,
    this.issuerCommonName,
    this.notBefore,
    this.notAfter,
    this.serialNumberHex,
    this.signatureAlgorithm,
    this.publicKeyAlgorithm,
    this.publicKeyCurve,
    this.publicKeyBits,
    this.sha256Fingerprint,
    this.sha1Fingerprint,
    this.md5Fingerprint,
  });

  /// 签发者里是否含 `Apple`。
  ///
  /// **这是启发式，不是结论**：真正的信任判断要看签名与系统信任链，
  /// 本包不做。用途仅限于「在报告里说清这张证书自称是谁签的」。
  bool get issuerLooksLikeApple {
    final value = issuer;
    return value != null && value.contains('Apple');
  }

  @override
  String toString() => 'X509CertificateInfo(subject: $subject, '
      'issuer: $issuer, notAfter: $notAfter)';
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

    // 顺序固定：serialNumber, signature, issuer, validity, subject,
    // subjectPublicKeyInfo。
    String? serialHex;
    if (index < fields.length && fields[index].isUniversalTag(DerTag.integer)) {
      serialHex = _serialHex(reader.content(fields[index]));
      index++;
    }

    String? signatureAlgorithm;
    if (index < fields.length) {
      signatureAlgorithm = _readAlgorithmName(reader, fields[index]);
    }
    index++; // signature AlgorithmIdentifier
    if (index >= fields.length) return null;

    final issuer = _readName(reader, fields[index]);
    index++;
    if (index >= fields.length) return null;

    final (notBefore, notAfter) = _readValidity(reader, fields[index]);
    index++;
    if (index >= fields.length) return null;

    final subject = _readName(reader, fields[index]);
    index++;
    if (index >= fields.length) return null;

    final publicKey = _readPublicKey(reader, fields[index]);

    return X509CertificateInfo(
      subject: subject.dn,
      issuer: issuer.dn,
      subjectCommonName: subject.commonName,
      issuerCommonName: issuer.commonName,
      notBefore: notBefore,
      notAfter: notAfter,
      serialNumberHex: serialHex,
      signatureAlgorithm: signatureAlgorithm,
      publicKeyAlgorithm: publicKey?.algorithm,
      publicKeyCurve: publicKey?.curve,
      publicKeyBits: publicKey?.bits,
      sha256Fingerprint: sha256.convert(der).toString(),
      sha1Fingerprint: sha1.convert(der).toString(),
      md5Fingerprint: md5.convert(der).toString(),
    );
  }

  /// 把存储的指纹（小写十六进制、无分隔）格式化成 `AA:BB:…`。
  ///
  /// 直接与 `apksigner` / `openssl` 的输出对照时不需要再手抄一遍。
  static String formatFingerprint(String hex) {
    final upper = hex.toUpperCase();
    final buffer = StringBuffer();
    for (var i = 0; i < upper.length; i += 2) {
      if (i > 0) buffer.write(':');
      buffer.write(upper.substring(i, i + 2));
    }
    return buffer.toString();
  }

  /// OID → 人类可读的**签名算法**名称。
  ///
  /// 未知 OID 原样返回点分形式：猜一个名字比给出 OID 更容易误导。
  static String? _readAlgorithmName(DerReader reader, DerElement element) {
    if (!element.isUniversalTag(DerTag.sequence)) return null;
    final children = reader.children(element, max: 4);
    if (children.isEmpty) return null;
    final oid = reader.oid(children[0]);
    if (oid == null) return null;
    return _signatureAlgorithmNames[oid] ?? oid;
  }

  /// 从 `Name` 里取 DN 与 CN。
  ///
  /// `Name ::= SEQUENCE OF SET OF SEQUENCE { type OID, value ANY }`。
  /// 多值 RDN 用 `+` 连接；RDN 之间用 `,` 连接，并且**反序**输出
  ///（DER 里从最上层到最具体，用户看到的是从具体到最上层）。
  static _Name _readName(DerReader reader, DerElement name) {
    if (!name.isUniversalTag(DerTag.sequence)) return const _Name(null, null);
    final rdns = reader.children(name, max: 64);
    final parts = <String>[];
    String? commonName;
    for (final rdn in rdns.reversed) {
      if (!rdn.isUniversalTag(DerTag.set)) continue;
      final attributes = <String>[];
      for (final attribute in reader.children(rdn, max: 64)) {
        if (!attribute.isUniversalTag(DerTag.sequence)) continue;
        final pair = reader.children(attribute, max: 8);
        if (pair.length < 2) continue;
        if (!pair[0].isUniversalTag(DerTag.oid)) continue;
        final oid = reader.oid(pair[0]);
        if (oid == null) continue;
        final value = _readNameValue(reader, pair[1]);
        if (value == null) continue;
        if (oid == _commonNameOid && commonName == null && value.isNotEmpty) {
          commonName = value;
        }
        final label = _nameAttributeLabels[oid] ?? oid;
        attributes.add('$label=${_escapeDnValue(value)}');
      }
      if (attributes.isNotEmpty) parts.add(attributes.join('+'));
    }
    return _Name(parts.isEmpty ? null : parts.join(','), commonName);
  }

  /// 读一个 `AttributeValue`。
  ///
  /// `DirectoryString` 常见的编码有 UTF8String / PrintableString / IA5String /
  /// BMPString / UniversalString。前三种按对应编码解，后两种按 UTF-16/32 BE
  /// 解 —— 统一按 Latin-1 读会把中文名字和 emoji 变成乱码。
  static String? _readNameValue(DerReader reader, DerElement element) {
    final content = reader.content(element);
    if (element.isUniversalTag(DerTag.utf8String)) {
      return utf8.decode(content, allowMalformed: true);
    }
    // BMPString（UCS-2，大端）。
    if (element.isUniversalTag(0x1E)) {
      return _decodeUtf16Be(content);
    }
    // UniversalString（UCS-4，大端）。
    if (element.isUniversalTag(0x1C)) {
      return _decodeUtf32Be(content);
    }
    // PrintableString / IA5String / TeletexString / VisibleString 都是
    // 单字节，按 Latin-1 解即可（ASCII 子集完全一致）。
    return latin1.decode(content, allowInvalid: true);
  }

  static String _decodeUtf16Be(Uint8List bytes) {
    final units = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      units.add((bytes[i] << 8) | bytes[i + 1]);
    }
    return String.fromCharCodes(units);
  }

  static String _decodeUtf32Be(Uint8List bytes) {
    final runes = <int>[];
    for (var i = 0; i + 3 < bytes.length; i += 4) {
      runes.add((bytes[i] << 24) |
          (bytes[i + 1] << 16) |
          (bytes[i + 2] << 8) |
          bytes[i + 3]);
    }
    return String.fromCharCodes(runes);
  }

  /// RFC 4514 的转义规则（只覆盖 `,` `+` `"` `\` `<` `>` `;`、首尾空格、
  /// 开头的 `#` 与控制字符）。`=` 在值里是合法字符，不转义。
  static String _escapeDnValue(String value) {
    final buffer = StringBuffer();
    for (var i = 0; i < value.length; i++) {
      final unit = value.codeUnitAt(i);
      final char = value[i];
      if (unit == 0x00) {
        buffer.write(r'\00');
      } else if (unit == 0x0A) {
        buffer.write(r'\0A');
      } else if (unit == 0x0D) {
        buffer.write(r'\0D');
      } else if (char == ',' ||
          char == '+' ||
          char == '"' ||
          char == r'\' ||
          char == '<' ||
          char == '>' ||
          char == ';') {
        buffer.write(r'\');
        buffer.write(char);
      } else if ((i == 0 && (char == '#' || char == ' ')) ||
          (i == value.length - 1 && char == ' ')) {
        buffer.write(r'\');
        buffer.write(char);
      } else {
        buffer.write(char);
      }
    }
    return buffer.toString();
  }

  /// 读 `SubjectPublicKeyInfo ::= SEQUENCE { algorithm, subjectPublicKey }`。
  ///
  /// 只需要回答「什么算法、多少位」，因此 RSA 只读模数长度、EC 只读曲线、
  /// DSA 只读 p —— 不解析任何密钥参数。
  static _PublicKey? _readPublicKey(DerReader reader, DerElement spki) {
    if (!spki.isUniversalTag(DerTag.sequence)) return null;
    final children = reader.children(spki, max: 4);
    if (children.length < 2) return null;

    final algorithm = reader.children(children[0], max: 4);
    if (algorithm.isEmpty) return null;
    final oid = reader.oid(algorithm[0]);
    if (oid == null) return null;

    final bitString = children[1];
    if (!bitString.isUniversalTag(DerTag.bitString) || bitString.length < 2) {
      return _PublicKey(oid: oid, algorithm: _keyAlgorithmNames[oid] ?? oid);
    }
    // BIT STRING 的首字节是「未使用位数」，公钥编码里恒为 0。
    final keyBytes = Uint8List.sublistView(
      reader.bytes,
      bitString.contentStart + 1,
      bitString.contentEnd,
    );

    switch (oid) {
      case '1.2.840.113549.1.1.1': // rsaEncryption
        return _readRsaPublicKey(keyBytes);
      case '1.2.840.10045.2.1': // id-ecPublicKey
        final curveOid =
            algorithm.length > 1 && algorithm[1].isUniversalTag(DerTag.oid)
                ? reader.oid(algorithm[1])
                : null;
        final curve = curveOid == null ? null : _curveNames[curveOid];
        // 曲线未知时用未压缩点长度反推位数：0x04 || X || Y。
        final inferredBits = keyBytes.isNotEmpty && keyBytes[0] == 0x04
            ? (keyBytes.length - 1) * 4
            : null;
        return _PublicKey(
          oid: oid,
          algorithm: 'EC',
          curve: curve?.$1 ?? curveOid,
          bits: curve?.$2 ?? inferredBits,
        );
      case '1.2.840.10040.4.1': // id-dsa
        final bits = _readDsaBits(reader, algorithm);
        return _PublicKey(oid: oid, algorithm: 'DSA', bits: bits);
      case '1.3.101.112': // Ed25519
        return _PublicKey(oid: oid, algorithm: 'Ed25519', bits: 256);
      case '1.3.101.113': // Ed448
        return _PublicKey(oid: oid, algorithm: 'Ed448', bits: 456);
      default:
        return _PublicKey(oid: oid, algorithm: _keyAlgorithmNames[oid] ?? oid);
    }
  }

  static _PublicKey _readRsaPublicKey(Uint8List keyBytes) {
    const algorithm = 'RSA';
    final reader = DerReader(keyBytes);
    final sequence = reader.at(0);
    if (sequence == null || !sequence.isUniversalTag(DerTag.sequence)) {
      return const _PublicKey(
          oid: '1.2.840.113549.1.1.1', algorithm: algorithm);
    }
    final fields = reader.children(sequence, max: 4);
    if (fields.isEmpty || !fields[0].isUniversalTag(DerTag.integer)) {
      return const _PublicKey(
          oid: '1.2.840.113549.1.1.1', algorithm: algorithm);
    }
    return _PublicKey(
      oid: '1.2.840.113549.1.1.1',
      algorithm: algorithm,
      bits: _integerBitLength(reader.content(fields[0])),
    );
  }

  static int? _readDsaBits(DerReader reader, List<DerElement> algorithm) {
    if (algorithm.length < 2) return null;
    final parameters = reader.children(algorithm[1], max: 4);
    if (parameters.isEmpty) return null;
    if (!parameters[0].isUniversalTag(DerTag.integer)) return null;
    return _integerBitLength(reader.content(parameters[0]));
  }

  /// INTEGER 内容的实际位数（去掉符号位带来的前导 `0x00`）。
  static int? _integerBitLength(Uint8List content) {
    var start = 0;
    while (start < content.length && content[start] == 0) {
      start++;
    }
    if (start >= content.length) return null;
    var bits = (content.length - start - 1) * 8;
    var byte = content[start];
    while (byte != 0) {
      bits++;
      byte >>= 1;
    }
    return bits;
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

  /// DN 属性类型 OID → 缩写。
  static const _nameAttributeLabels = <String, String>{
    '2.5.4.3': 'CN',
    '2.5.4.4': 'SN',
    '2.5.4.5': 'serialNumber',
    '2.5.4.6': 'C',
    '2.5.4.7': 'L',
    '2.5.4.8': 'ST',
    '2.5.4.9': 'street',
    '2.5.4.10': 'O',
    '2.5.4.11': 'OU',
    '2.5.4.12': 'title',
    '2.5.4.13': 'description',
    '2.5.4.17': 'postalCode',
    '2.5.4.42': 'GN',
    '2.5.4.43': 'initials',
    '2.5.4.46': 'dnQualifier',
    '0.9.2342.19200300.100.1.1': 'UID',
    '0.9.2342.19200300.100.1.25': 'DC',
    '1.2.840.113549.1.9.1': 'emailAddress',
    '1.2.840.113549.1.9.2': 'unstructuredName',
  };

  /// 签名算法 OID → 名称。
  static const _signatureAlgorithmNames = <String, String>{
    '1.2.840.113549.1.1.2': 'MD2withRSA',
    '1.2.840.113549.1.1.4': 'MD5withRSA',
    '1.2.840.113549.1.1.5': 'SHA1withRSA',
    '1.2.840.113549.1.1.14': 'SHA224withRSA',
    '1.2.840.113549.1.1.11': 'SHA256withRSA',
    '1.2.840.113549.1.1.12': 'SHA384withRSA',
    '1.2.840.113549.1.1.13': 'SHA512withRSA',
    '1.2.840.10045.4.1': 'SHA1withECDSA',
    '1.2.840.10045.4.3.1': 'SHA224withECDSA',
    '1.2.840.10045.4.3.2': 'SHA256withECDSA',
    '1.2.840.10045.4.3.3': 'SHA384withECDSA',
    '1.2.840.10045.4.3.4': 'SHA512withECDSA',
    '1.3.101.112': 'Ed25519',
    '1.3.101.113': 'Ed448',
  };

  /// 公钥算法 OID → 名称。
  static const _keyAlgorithmNames = <String, String>{
    '1.2.840.113549.1.1.1': 'RSA',
    '1.2.840.10045.2.1': 'EC',
    '1.2.840.10040.4.1': 'DSA',
    '1.3.101.112': 'Ed25519',
    '1.3.101.113': 'Ed448',
  };

  /// EC 命名曲线 OID → (名称, 位数)。
  static const _curveNames = <String, (String, int)>{
    '1.2.840.10045.3.1.1': ('prime192v1', 192),
    '1.3.132.0.33': ('secp224r1', 224),
    '1.2.840.10045.3.1.7': ('prime256v1', 256),
    '1.3.132.0.10': ('secp256k1', 256),
    '1.3.132.0.34': ('secp384r1', 384),
    '1.3.132.0.35': ('secp521r1', 521),
  };
}

class _Name {
  final String? dn;
  final String? commonName;

  const _Name(this.dn, this.commonName);
}

class _PublicKey {
  final String oid;
  final String algorithm;
  final String? curve;
  final int? bits;

  const _PublicKey({
    required this.oid,
    required this.algorithm,
    this.curve,
    this.bits,
  });
}
