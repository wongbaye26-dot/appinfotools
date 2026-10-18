import 'package:analysis_model/analysis_model.dart';
// ignore_for_file: constant_identifier_names
// from: https://github.com/google/android-classyshark/blob/master/ClassySharkWS/src/com/google/classyshark/silverghost/translator/xml/XmlDecompressor.java

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'byte_data_reader.dart';

class XmlElement {
  String name = "";
  Map<String, String> attributes = {};
  List<XmlElement> children = [];

  /// 混淆属性中通过非标准字段（如 ns）恢复的额外字符串值，
  /// 供 ManifestParser 启发式查找使用
  List<String> extraStrings = [];
}

class XmlDocument extends XmlElement {
  /// 解析过程中观察到的**非标准布局**特征。
  ///
  /// 这不是「解析失败」，而是「这份文件故意不像标准 AXML」。两者必须分开：
  /// 前者说明我们读不出来，后者说明有人不想让我们读出来 —— 后者本身就是
  /// 一条值得告诉用户的事实。
  final AxmlLayoutAnomalies layoutAnomalies = AxmlLayoutAnomalies();
}

/// AXML 的非标准布局特征。
///
/// 只累计**可复现的结构事实**，不做任何厂商推断（规范 4.2）。
///
/// 各字段的含义见 [evidence] 产出的文本 —— 那也正是展示给用户的内容。
class AxmlLayoutAnomalies {
  /// 声明了非标准 `attributeStart` 的元素数。
  ///
  /// 标准 AXML 里它恒为 20（`attrExt` 结构体自身的大小）。大于 20 意味着
  /// 头与真正的属性之间有一段**谁也不会读的字节** —— 正常构建流程不会产出
  /// 这种文件，它的用处是让「按固定布局硬编码偏移」的解析器读到诱饵。
  int nonStandardAttributeStart = 0;

  /// 观察到的最大 `attributeStart`。
  int maxAttributeStart = 0;

  /// 最大 `attributeStart` 所属的元素名（便于定位）。
  String? maxAttributeStartElement;

  /// 声明了非标准 `attributeSize` 的元素数（标准值同样恒为 20）。
  int nonStandardAttributeSize = 0;

  /// 观察到的最大 `attributeSize`。
  int maxAttributeSize = 0;

  /// 未知 chunk 类型 → 出现次数。
  ///
  /// 标准 AXML 的元素区只有 `0x0100`–`0x0104` 与 `0x0180` 这几种。
  final Map<int, int> unknownChunks = {};

  /// 声明了非标准尺寸的命名空间 chunk 数。
  ///
  /// `START_NAMESPACE` / `END_NAMESPACE` 的尺寸恒为 24（16 字节头 + 4 字节
  /// 行号 + 4 字节注释）。实测样本里出现了一个 1220 字节的
  /// `END_NAMESPACE`，而且它出现在任何 `START_NAMESPACE` 之前 ——
  /// 正常流程不会产出这种序列。
  int nonStandardNamespaceChunks = 0;

  /// 观察到的最大命名空间 chunk 尺寸。
  int maxNamespaceChunkSize = 0;

  bool get isEmpty =>
      nonStandardAttributeStart == 0 &&
      nonStandardAttributeSize == 0 &&
      nonStandardNamespaceChunks == 0 &&
      unknownChunks.isEmpty;

  /// 标准 AXML 里 `attributeStart` 与 `attributeSize` 的值。
  static const int standardAttributeLayout = 20;

  /// 标准 AXML 里命名空间 chunk 的尺寸。
  static const int standardNamespaceChunkSize = 24;

  void observeElement({
    required String elementName,
    required int attributeStart,
    required int attributeSize,
  }) {
    if (attributeStart != standardAttributeLayout) {
      nonStandardAttributeStart++;
      if (attributeStart > maxAttributeStart) {
        maxAttributeStart = attributeStart;
        maxAttributeStartElement = elementName;
      }
    }
    if (attributeSize != standardAttributeLayout) {
      nonStandardAttributeSize++;
      if (attributeSize > maxAttributeSize) {
        maxAttributeSize = attributeSize;
      }
    }
  }

  void observeUnknownChunk(int type) {
    unknownChunks[type] = (unknownChunks[type] ?? 0) + 1;
  }

  void observeNamespaceChunk(int chunkSize) {
    if (chunkSize == standardNamespaceChunkSize) return;
    nonStandardNamespaceChunks++;
    if (chunkSize > maxNamespaceChunkSize) maxNamespaceChunkSize = chunkSize;
  }

  /// 面向用户与报告的**结构化**说明（V2.4.11）。
  ///
  /// 与 [evidence] 一一对应，但每条带**稳定 code + 参数**，界面按 code 查
  /// 本地化模板 —— 否则中文界面上会是「容器/解析异常可能影响覆盖完整性：
  /// 21 elements declare a non-standard attributeStart…」这种半中半英。
  List<AnalysisNote> notes() {
    final out = <AnalysisNote>[];

    if (nonStandardAttributeStart > 0) {
      out.add(AnalysisNote(
        'android.manifest.attribute_start_nonstandard',
        '$nonStandardAttributeStart elements declare a non-standard '
            'attributeStart (largest $maxAttributeStart on '
            '<${maxAttributeStartElement ?? '?'}>), the standard value is '
            '$standardAttributeLayout',
        {
          'count': nonStandardAttributeStart,
          'largest': maxAttributeStart,
          'element': maxAttributeStartElement ?? '?',
          'standard': standardAttributeLayout,
        },
      ));
    }

    if (nonStandardAttributeSize > 0) {
      out.add(AnalysisNote(
        'android.manifest.attribute_size_nonstandard',
        '$nonStandardAttributeSize elements declare a non-standard '
            'attributeSize (largest $maxAttributeSize, the standard value is '
            '$standardAttributeLayout)',
        {
          'count': nonStandardAttributeSize,
          'largest': maxAttributeSize,
          'standard': standardAttributeLayout,
        },
      ));
    }

    if (nonStandardNamespaceChunks > 0) {
      out.add(AnalysisNote(
        'android.manifest.namespace_chunk_nonstandard',
        '$nonStandardNamespaceChunks namespace chunk(s) declare a '
            'non-standard size (largest $maxNamespaceChunkSize, the standard '
            'size is $standardNamespaceChunkSize)',
        {
          'count': nonStandardNamespaceChunks,
          'largest': maxNamespaceChunkSize,
          'standard': standardNamespaceChunkSize,
        },
      ));
    }

    if (unknownChunks.isNotEmpty) {
      final described = unknownChunks.entries
          .map(
              (e) => '0x${e.key.toRadixString(16).padLeft(4, '0')} x${e.value}')
          .join(', ');
      out.add(AnalysisNote(
        'android.manifest.unknown_chunk',
        '${unknownChunks.length} chunk type(s) are not part of the standard '
            'AXML element range: $described',
        {'count': unknownChunks.length, 'chunks': described},
      ));
    }

    return out;
  }

  /// 面向用户与报告的说明。
  ///
  /// 每一条都说清「看到了什么」与「这意味着什么」，而不是只丢一个数字。
  ///
  /// **保留它是为了英文回退与日志**：界面走 [notes]，`note.fallback` 就是
  /// 这里同一句话。
  List<String> evidence() {
    final lines = <String>[];

    if (nonStandardAttributeStart > 0) {
      final where = maxAttributeStartElement == null
          ? ''
          : ' (largest $maxAttributeStart on <$maxAttributeStartElement>)';
      lines.add(
        '$nonStandardAttributeStart elements declare a non-standard '
        'attributeStart$where, the standard value is '
        '$standardAttributeLayout; bytes between the element header and its '
        'attributes are skipped by a compliant reader but mislead one that '
        'assumes a fixed layout',
      );
    }

    if (nonStandardAttributeSize > 0) {
      lines.add(
        '$nonStandardAttributeSize elements declare a non-standard '
        'attributeSize (largest $maxAttributeSize, the standard value is '
        '$standardAttributeLayout)',
      );
    }

    if (nonStandardNamespaceChunks > 0) {
      lines.add(
        '$nonStandardNamespaceChunks namespace chunk(s) declare a '
        'non-standard size (largest $maxNamespaceChunkSize, the standard '
        'size is $standardNamespaceChunkSize)',
      );
    }

    if (unknownChunks.isNotEmpty) {
      final described = unknownChunks.entries
          .map(
              (e) => '0x${e.key.toRadixString(16).padLeft(4, '0')} x${e.value}')
          .join(', ');
      lines.add(
        '${unknownChunks.length} chunk type(s) are not part of the standard '
        'AXML element range: $described',
      );
    }

    return lines;
  }
}

/// Android 框架属性资源 ID → 属性名。
///
/// **这张表是「读得到」与「读错」的分界线，绝不能凭印象写。**
/// 资源 ID 由 AOSP 固定，唯一可信来源是 android.jar 的资源表：
///
/// ```
/// aapt2 dump resources $ANDROID_HOME/platforms/android-34/android.jar \
///   | grep -oE 'resource 0x[0-9a-f]+ attr/[A-Za-z0-9_]+'
/// ```
///
/// 该命令的完整输出快照在 `test/fixtures/android_34_attrs.txt`，
/// `test/framework_attr_names_test.dart` 逐条比对，防止再次写错。
///
/// 历史教训：V2.4.14 之前这里是一份 63 条的表，其中 **51 条 ID 对应错了名字**
/// （`0x01010010` 写成 `resource` 实为 `exported`、`0x01010280` 写成
/// `screenSize` 实为 `allowBackup`……）。后果是 `android:exported` /
/// `debuggable` / `allowBackup` / `usesCleartextTraffic` 在**真实包上全部读不到**，
/// 相关安全规则长期静默失效，而单元测试因为自己造 AXML 而一直绿。
///
/// 只收录解析器真正消费的属性；不在此表内的属性走字符串池回退
/// （aapt2 一定会把属性名写进字符串池，回退在正常包上是正确的）。
const Map<int, String> kFrameworkAttrNames = {
  0x01010001: 'label',
  0x01010002: 'icon',
  0x01010003: 'name',
  0x01010006: 'permission',
  0x0101000e: 'enabled',
  0x0101000f: 'debuggable',
  0x01010010: 'exported',
  0x01010018: 'authorities',
  0x01010027: 'scheme',
  0x0101020c: 'minSdkVersion',
  0x0101021b: 'versionCode',
  0x0101021c: 'versionName',
  0x01010270: 'targetSdkVersion',
  0x01010271: 'maxSdkVersion',
  0x01010280: 'allowBackup',
  0x0101028e: 'required',
  0x010104ec: 'usesCleartextTraffic',
  0x01010527: 'networkSecurityConfig',
  0x01010572: 'compileSdkVersion',
  0x01010573: 'compileSdkVersionCodename',
};

class BinaryXmlDecompressor {
  // Identifiers for XML Chunk Types
  static const int PACKED_XML_IDENTIFIER = 0x00080003;
  static const int START_NAMESPACE_TAG = 0x0100;
  static const int END_NAMESPACE_TAG = 0x0101;
  static const int START_ELEMENT_TAG = 0x0102;
  static const int END_ELEMENT_TAG = 0x0103;
  static const int CDATA_TAG = 0x0104;
  static const int ATTRS_MARKER = 0x00140014;

  static const int RES_XML_RESOURCE_MAP_TYPE = 0x180;
  static const int RES_XML_FIRST_CHUNK_TYPE = 0x100;
  static const int RES_XML_STRING_TABLE = 0x0001;

  // Resource Types
  static const int RES_TYPE_NULL = 0x00;
  static const int RES_TYPE_REFERENCE = 0x01;
  static const int RES_TYPE_ATTRIBUTE = 0x02;
  static const int RES_TYPE_STRING = 0x03;
  static const int RES_TYPE_FLOAT = 0x04;
  static const int RES_TYPE_DIMENSION = 0x05;
  static const int RES_TYPE_FRACTION = 0x06;
  static const int RES_TYPE_DYNAMIC_REFERENCE = 0x07;
  static const int RES_TYPE_INT_DEC = 0x10;
  static const int RES_TYPE_INT_HEX = 0x11;
  static const int RES_TYPE_INT_BOOLEAN = 0x12;

  // Color Types
  static const int RES_TYPE_INT_COLOR_ARGB8 = 0x1c;
  static const int RES_TYPE_INT_COLOR_RGB8 = 0x1d;
  static const int RES_TYPE_INT_COLOR_ARGB4 = 0x1e;
  static const int RES_TYPE_INT_COLOR_RGB4 = 0x1f;

  // Complex Types
  static const int COMPLEX_UNIT_SHIFT = 0;
  static const int COMPLEX_UNIT_MASK = 0xf;
  static const int COMPLEX_MANTISSA_SHIFT = 8;
  static const int COMPLEX_MANTISSA_MASK = 0xffffff;
  static const int COMPLEX_RADIX_SHIFT = 4;
  static const int COMPLEX_RADIX_MASK = 0x3;
  static const int COMPLEX_UNIT_FRACTION = 0;
  static const int COMPLEX_UNIT_FRACTION_PARENT = 1;
  static const List<double> RADIX_MULTS = [
    1.0,
    1.0 / (1 << 7),
    1.0 / (1 << 15),
    1.0 / (1 << 23),
  ];

  static const int RES_VALUE_TRUE = 0xffffffff;
  static const int RES_VALUE_FALSE = 0x00000000;

  // Print Defeine
  static const int IDENT_SIZE = 2;
  static const int ATTR_IDENT_SIZE = 4;

  static const int UTF8_FLAG = 0x100;

  bool appendNamespaces = false;
  bool appendCData = true;

  String decompressXml(Uint8List bytes) {
    final reader = ByteDataReader.wrapUint8List(bytes, endian: Endian.little);
    StringBuffer result =
        StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n');

    // Getting and checking the marker for a valid XML file
    int fileMarker = reader.readInt32();
    if (fileMarker != PACKED_XML_IDENTIFIER) {
      throw FormatException(
          'Invalid packed XML identifier. Expecting 0x${PACKED_XML_IDENTIFIER.toRadixString(16)}, found 0x${fileMarker.toRadixString(16)}');
    }

    reader.skipBytes(4);

    List<String> packedStrings = parseStrings(reader);

    // Resource ID Map: 字符串池索引 → 框架资源 ID
    List<int> resourceIdMap = [];

    int ident = 0;
    while (reader.remain >= 8) {
      final chunkStart = reader.position;
      int tag = reader.readInt16();
      int headerSize = reader.readInt16();
      int chunkSize = reader.readInt32();
      if (chunkSize < 8) {
        throw FormatException('Invalid chunk size: $chunkSize');
      }
      final chunkEnd = chunkStart + chunkSize;
      if (chunkEnd > reader.length) {
        throw FormatException(
            'Chunk out of bounds: start=$chunkStart size=$chunkSize total=${reader.length}');
      }

      switch (tag) {
        case START_NAMESPACE_TAG:
        case END_NAMESPACE_TAG:
          break;
        case RES_XML_RESOURCE_MAP_TYPE:
          resourceIdMap =
              _parseResourceIdMap(reader, chunkStart, headerSize, chunkSize);
          break;
        case START_ELEMENT_TAG:
          parseStartTag(result, reader, packedStrings, resourceIdMap, ident);
          ident++;
          break;
        case END_ELEMENT_TAG:
          ident = math.max(ident - 1, 0);
          parseEndTag(result, reader, packedStrings, ident);
          break;
        case CDATA_TAG:
          parseCDataTag(result, reader, packedStrings, ident);
          break;
        default:
          break;
      }

      // Always align to chunk boundary, even if parse consumed fewer bytes.
      if (reader.position != chunkEnd) {
        reader.position = chunkEnd;
      }
    }

    return result.toString();
  }

  /// Decompress binary XML to a structured [XmlDocument] tree.
  XmlDocument decompressToDocument(Uint8List bytes) {
    final reader = ByteDataReader.wrapUint8List(bytes, endian: Endian.little);
    int fileMarker = reader.readInt32();
    if (fileMarker != PACKED_XML_IDENTIFIER) {
      throw FormatException('Invalid packed XML identifier');
    }
    reader.skipBytes(4);
    List<String> packedStrings = parseStrings(reader);

    // Resource ID Map: 字符串池索引 → 框架资源 ID
    List<int> resourceIdMap = [];

    final doc = XmlDocument();
    final anomalies = doc.layoutAnomalies;
    final stack = <XmlElement>[doc];

    while (reader.remain >= 8) {
      final chunkStart = reader.position;
      int tag = reader.readInt16();
      int headerSize = reader.readInt16();
      int chunkSize = reader.readInt32();
      if (chunkSize < 8) break;
      final chunkEnd = chunkStart + chunkSize;
      if (chunkEnd > reader.length) break;

      switch (tag) {
        case START_NAMESPACE_TAG:
        case END_NAMESPACE_TAG:
          // 标准尺寸恒为 24。尺寸异常说明这一段被塞了别的东西 ——
          // 实测样本里有一个 1220 字节的 END_NAMESPACE，且出现在任何
          // START_NAMESPACE 之前。
          anomalies.observeNamespaceChunk(chunkSize);
          break;
        case RES_XML_RESOURCE_MAP_TYPE:
          resourceIdMap =
              _parseResourceIdMap(reader, chunkStart, headerSize, chunkSize);
          break;
        case START_ELEMENT_TAG:
          final element = _parseStartElement(
              reader, packedStrings, resourceIdMap, chunkEnd, anomalies);
          stack.last.children.add(element);
          stack.add(element);
          break;
        case END_ELEMENT_TAG:
          reader.skipBytes(8);
          reader.readInt32(); // namespace
          reader.readInt32(); // name
          if (stack.length > 1) stack.removeLast();
          break;
        case CDATA_TAG:
          // Skip CDATA in document mode
          reader.skipBytes(8);
          reader.readInt32();
          reader.skipBytes(8);
          break;
        default:
          // 标准 AXML 的元素区只有上面几种 chunk。出现别的类型说明这份文件
          // 被构造过 —— 如实记下来，而不是当作没看见（跳过未知 chunk 本身
          // 是对的，但「跳过了什么」必须留下痕迹）。
          anomalies.observeUnknownChunk(tag);
          break;
      }
      if (reader.position != chunkEnd) reader.position = chunkEnd;
    }
    return doc;
  }

  /// Parse a START_ELEMENT_TAG into an [XmlElement] with name and attributes.
  /// [chunkEnd] 是当前 chunk 的结束位置，用于读取移位属性的溢出数据。
  XmlElement _parseStartElement(
      ByteDataReader reader,
      List<String> packedStrings,
      List<int> resourceIdMap,
      int chunkEnd,
      AxmlLayoutAnomalies anomalies) {
    final element = XmlElement();

    // Skip line number and comment
    reader.skipBytes(8);
    reader.readInt32(); // namespace
    int nameStringIndex = reader.readInt32();
    element.name = _resolveStringOrResourceId(
        packedStrings, resourceIdMap, nameStringIndex);
    if (element.name.isEmpty) element.name = 'unknown';

    // Parse attributes
    int marker = reader.readInt32();
    // marker 包含 attrStart (低16位) 和 attrSize (高16位)
    // 标准值: attrStart=20, attrSize=20 → marker=0x00140014
    // 混淆 APK 可能修改 attrSize（如 24），需按实际大小跳过额外字节
    final attrStart = marker & 0xFFFF;
    final attrSize = (marker >> 16) & 0xFFFF;
    final attrExtraBytes = (attrSize > 20) ? attrSize - 20 : 0;

    int numAttributes = reader.readUint16();
    reader.skipBytes(6);

    // 属性的起点由 `attributeStart` 决定，**不是**紧跟在 attrExt 头之后。
    //
    // 这里曾经忽略 `attributeStart` 直接往后读。标准 AXML 里它恒为 20
    // （attrExt 结构体自身的大小），所以一直没暴露；而加固器会在头与真正的
    // 属性之间塞一段**诱饵字节**，并把 `attributeStart` 指到诱饵之后。
    // 结果是：属性名与值全部读成诱饵内容，`package`、`versionName`、
    // `uses-permission` 这些字段整体丢失 —— 而组件名却还能读对（那些元素的
    // `attributeStart` 仍是 20），于是表现为「组件有、基本信息全空」这种
    // 很难解释的现象。
    //
    // 实测样本（test/fixtures/apk/hardened-manifest.axml）里 `<manifest>` 的
    // attributeStart 是 181，诱饵区长达 161 字节。
    final attrGap = (attrStart > 20) ? attrStart - 20 : 0;
    if (attrGap > 0) {
      reader.skipBytes(attrGap);
    }

    // 记下这份元素的布局是否非标准。**不影响解析结果**，只作为一条可解释的
    // 事实告诉用户：这份 manifest 被刻意做得不像标准 AXML。
    anomalies.observeElement(
      elementName: element.name,
      attributeStart: attrStart,
      attributeSize: attrSize,
    );

    // 缓冲所有原始属性数据（标准 20 字节 + 可能的额外填充）
    final rawAttrs = <List<int>>[];
    for (int i = 0; i < numAttributes; i++) {
      rawAttrs.add([
        reader.readInt32(), // 0: ns
        reader.readInt32(), // 1: name
        reader.readInt32(), // 2: rawValue
        reader.readUint16(), // 3: tvSize
        reader.readUint8(), // 4: tvRes0
        reader.readUint8(), // 5: tvType
        reader.readInt32(), // 6: tvData
      ]);
      // 跳过混淆器注入的额外填充字节
      if (attrExtraBytes > 0) {
        reader.skipBytes(attrExtraBytes);
      }
    }

    // 读取溢出字节（移位属性在最后一个时，值在 chunk 末尾填充区）
    int overflowValue = 0;
    bool hasOverflow = false;
    if (reader.position + 4 <= chunkEnd) {
      overflowValue = reader.readInt32();
      hasOverflow = true;
    }

    // 处理属性：检测移位属性模式并恢复值
    for (int i = 0; i < rawAttrs.length; i++) {
      final attr = rawAttrs[i];
      int attrNs = attr[0];
      int attrName = attr[1];
      int attrRawValue = attr[2];
      int attrType = attr[5];
      int attrData = attr[6];

      // 检测移位属性：type=0xFF 且 data 看起来像 typedValue header
      if (_isShiftedAttribute(attrType, attrData)) {
        final shiftedType = (attrData >> 24) & 0xFF;
        // 真实属性名在 rawValue 位置
        final realNameIdx = attrRawValue;
        // 真实值在下一个属性的 ns 字段或溢出区
        int? realValue;
        if (i + 1 < rawAttrs.length) {
          realValue = rawAttrs[i + 1][0]; // 下一个属性的 ns 字段
        } else if (hasOverflow) {
          realValue = overflowValue;
        }

        if (realValue != null) {
          String attributeName = _resolveStringOrResourceId(
              packedStrings, resourceIdMap, realNameIdx);
          if (attributeName.isEmpty) attributeName = "attr_$realNameIdx";

          String attributeValue = _resolveAttributeValue(
              shiftedType, realValue, -1, packedStrings,
              resIdMapLength: resourceIdMap.length);

          if (attributeValue != '<empty>' && attributeValue != '<undefined>') {
            // 移位属性恢复的值优先级高
            element.attributes[attributeName] = attributeValue;
          }
        }
        continue;
      }

      // 普通属性处理
      String attributeName =
          _resolveStringOrResourceId(packedStrings, resourceIdMap, attrName);
      if (attributeName.isEmpty) attributeName = "attr_$attrName";

      String attributeValue = _resolveAttributeValue(
          attrType, attrData, attrRawValue, packedStrings,
          resIdMapLength: resourceIdMap.length);

      // 不用空值覆盖已有的有效值（混淆 APK 可能有重复属性名）
      final existing = element.attributes[attributeName];
      if (existing != null &&
          existing.isNotEmpty &&
          existing != '<empty>' &&
          existing != '<undefined>' &&
          (attributeValue == '<empty>' || attributeValue == '<undefined>')) {
        if (attrType == RES_TYPE_NULL || attrType == 0xFF) {
          _rescueNsValue(element, packedStrings, resourceIdMap, attrNs);
        }
        continue;
      }
      element.attributes[attributeName] = attributeValue;

      // 对于混淆属性，也检查 ns 字段中是否有被藏匿的值
      if (attrType == RES_TYPE_NULL || attrType == 0xFF) {
        _rescueNsValue(element, packedStrings, resourceIdMap, attrNs);
      }
    }

    return element;
  }

  /// 检测移位属性：type=0xFF 且 data 字段包含有效的 typedValue header
  bool _isShiftedAttribute(int type, int data) {
    if (type != 0xFF) return false;
    // 提取移位 header 中的字段
    final shiftedSize = data & 0xFFFF;
    final shiftedType = (data >> 24) & 0xFF;
    // 有效的 Res_value size 通常是 8 或 12
    if (shiftedSize != 0x0008 && shiftedSize != 0x000c) return false;
    // 有效的类型值
    return shiftedType == RES_TYPE_REFERENCE ||
        shiftedType == RES_TYPE_STRING ||
        shiftedType == RES_TYPE_INT_DEC ||
        shiftedType == RES_TYPE_INT_HEX ||
        shiftedType == RES_TYPE_INT_BOOLEAN ||
        shiftedType == RES_TYPE_INT_COLOR_ARGB8 ||
        shiftedType == RES_TYPE_INT_COLOR_RGB8;
  }

  /// Resolve an attribute's typed value to a string representation.
  /// Handles all the same type cases as [parseAttributes].
  /// [resIdMapLength] 用于过滤 rawValue 回退（Resource ID Map 范围内是属性名）
  String _resolveAttributeValue(int attrValueType, int attributeResourceId,
      int attributeValueIndex, List<String> packedStrings,
      {int resIdMapLength = 0}) {
    switch (attrValueType) {
      case RES_TYPE_NULL:
        // 混淆 APK 可能将 typed value 置空，但 rawValue 仍有效
        // 仅在 rawValue 索引超出 Resource ID Map 范围时使用
        // (Resource ID Map 范围内的字符串是属性名，不是属性值)
        if (attributeValueIndex >= resIdMapLength &&
            attributeValueIndex >= 0 &&
            attributeValueIndex < packedStrings.length) {
          final rawStr = packedStrings[attributeValueIndex];
          if (rawStr.isNotEmpty &&
              !rawStr.startsWith('http://') &&
              !rawStr.startsWith('https://')) {
            return rawStr;
          }
        }
        return (attributeResourceId == 0) ? "<undefined>" : "<empty>";
      case RES_TYPE_REFERENCE:
        return '@res/0x${attributeResourceId.toRadixString(16)}';
      case RES_TYPE_ATTRIBUTE:
        return '@attr/0x${attributeResourceId.toRadixString(16)}';
      case RES_TYPE_STRING:
        return _safeGet(packedStrings, attributeValueIndex);
      case RES_TYPE_FLOAT:
        final buf = Uint8List(4);
        buf[0] = attributeResourceId & 0xff;
        buf[1] = (attributeResourceId >> 8) & 0xff;
        buf[2] = (attributeResourceId >> 16) & 0xff;
        buf[3] = (attributeResourceId >> 24) & 0xff;
        final value = ByteData.sublistView(buf).buffer.asFloat32List().first;
        return value.toString();
      case RES_TYPE_DIMENSION:
        double value = resValue(attributeResourceId);
        String type = getDimensionType(attributeResourceId);
        return '$value$type';
      case RES_TYPE_FRACTION:
        final value = resValue(attributeResourceId);
        final type = getFractionType(attributeResourceId);
        return '$value$type';
      case RES_TYPE_DYNAMIC_REFERENCE:
        return '@dyn/0x${attributeResourceId.toRadixString(16)}';
      case RES_TYPE_INT_DEC:
        return attributeResourceId.toString();
      case RES_TYPE_INT_HEX:
        return '0x${(attributeResourceId & 0xffffffff).toRadixString(16)}';
      case RES_TYPE_INT_BOOLEAN:
        return _boolText(attributeResourceId);
      case RES_TYPE_INT_COLOR_ARGB8:
      case RES_TYPE_INT_COLOR_ARGB4:
        return '#${(attributeResourceId & 0xffffffff).toRadixString(16).padLeft(8, '0')}';
      case RES_TYPE_INT_COLOR_RGB8:
      case RES_TYPE_INT_COLOR_RGB4:
        return '#ff${(attributeResourceId & 0x00ffffff).toRadixString(16).padLeft(6, '0')}';
      default:
        return '0x${(attributeResourceId & 0xffffffff).toRadixString(16)}';
    }
  }

  void parseCDataTag(
      StringBuffer sb, ByteDataReader reader, List<String> strings, int ident) {
    //Skipping 3 unknowns integers:
    reader.skipBytes(8);
    int nameStringIndex = reader.readInt32();
    //Skipping 2 more unknown integers.
    reader.skipBytes(8);
    if (appendCData) {
      sb.write(' ' * (ident * IDENT_SIZE));
      sb.write('<![CDATA[\n');
      sb.write(' ' * (ident * IDENT_SIZE + 1));
      sb.write(_safeGet(strings, nameStringIndex));
      sb.write(' ' * (ident * IDENT_SIZE));
      sb.write(']]>\n');
    }
  }

  void parseEndTag(
      StringBuffer sb, ByteDataReader reader, List<String> strings, int ident) {
    sb.write(' ' * (ident * IDENT_SIZE));
    sb.write('</');
    //Skipping 3 integers:
    // 1 - a flag?, like 38000000
    // 2 - Line of where this tag appeared in the original source file
    // 3 - Unknown: always FFFFFFFF?
    reader.skipBytes(8);
    int namespaceStringIndex = reader.readInt32();
    if (appendNamespaces && namespaceStringIndex >= 0) {
      sb.write(_safeGet(strings, namespaceStringIndex));
      sb.write(':');
    }

    int nameStringIndex = reader.readInt32();
    sb.write(_safeGet(strings, nameStringIndex));
    sb.write('>\n');
  }

  void parseStartTag(StringBuffer sb, ByteDataReader reader,
      List<String> strings, List<int> resourceIdMap, int ident) {
    sb.write(' ' * (ident * IDENT_SIZE));
    sb.write('<');
    //Skipping 3 integers:
    // 1 - a flag?, like 38000000
    // 2 - Line of where this tag appeared in the original source file
    // 3 - Unknown: always FFFFFFFF?
    reader.skipBytes(8);
    int namespaceStringIndex = reader.readInt32();
    if (appendNamespaces && namespaceStringIndex >= 0) {
      sb.write(_safeGet(strings, namespaceStringIndex));
      sb.write(':');
    }

    int nameStringIndex = reader.readInt32();
    final tagName =
        _resolveStringOrResourceId(strings, resourceIdMap, nameStringIndex);
    sb.write(tagName.isNotEmpty ? tagName : 'unknown');
    parseAttributes(sb, reader, strings, resourceIdMap, ident);
    sb.write('>\n');
  }

  void parseAttributes(StringBuffer sb, ByteDataReader reader,
      List<String> strings, List<int> resourceIdMap, int ident) {
    int marker = reader.readInt32();
    if (marker != ATTRS_MARKER) {
      // Non-fatal marker mismatch
    }

    // ResXMLTree_attrExt:
    // uint16 attributeCount, uint16 idIndex, uint16 classIndex, uint16 styleIndex
    int numAttributes = reader.readUint16();
    reader.skipBytes(6);

    for (int i = 0; i < numAttributes; i++) {
      sb.write('\n');
      sb.write(' ' * (ident * IDENT_SIZE + ATTR_IDENT_SIZE));

      int attributeNamespaceIndex = reader.readInt32();
      int attributeNameIndex = reader.readInt32();
      int attributeValueIndex = reader.readInt32();

      // typedValue header: size(uint16), res0(uint8), dataType(uint8)
      reader.readUint16(); // size, usually 8
      reader.readUint8(); // res0
      int attrValueType = reader.readUint8();
      int attributeResourceId = reader.readInt32();

      if (appendNamespaces && attributeNamespaceIndex >= 0) {
        sb.write(_safeGet(strings, attributeNamespaceIndex));
        sb.write(":");
      }

      String attributeName = _resolveStringOrResourceId(
          strings, resourceIdMap, attributeNameIndex);
      if (attributeName.isEmpty) attributeName = "attr_$attributeNameIndex";

      String attributeValue;
      switch (attrValueType) {
        case RES_TYPE_NULL:
          // 混淆 APK: typed value 为空时尝试 rawValue
          // 仅在 rawValue 索引超出 Resource ID Map 范围时使用
          if (attributeValueIndex >= resourceIdMap.length &&
              attributeValueIndex >= 0 &&
              attributeValueIndex < strings.length) {
            final rawStr = strings[attributeValueIndex];
            if (rawStr.isNotEmpty &&
                !rawStr.startsWith('http://') &&
                !rawStr.startsWith('https://')) {
              attributeValue = rawStr;
              break;
            }
          }
          attributeValue =
              (attributeResourceId == 0) ? "<undefined>" : "<empty>";
          break;
        case RES_TYPE_REFERENCE:
          attributeValue = '@res/0x${attributeResourceId.toRadixString(16)}';
          break;
        case RES_TYPE_ATTRIBUTE:
          attributeValue = '@attr/0x${attributeResourceId.toRadixString(16)}';
          break;
        case RES_TYPE_STRING:
          attributeValue = _safeGet(strings, attributeValueIndex);
          break;
        case RES_TYPE_FLOAT:
          final buf = Uint8List(4);
          buf[0] = attributeResourceId & 0xff;
          buf[1] = (attributeResourceId >> 8) & 0xff;
          buf[2] = (attributeResourceId >> 16) & 0xff;
          buf[3] = (attributeResourceId >> 24) & 0xff;
          final value = ByteData.sublistView(buf).buffer.asFloat32List().first;
          attributeValue = value.toString();
          break;
        case RES_TYPE_DIMENSION:
          double value = resValue(attributeResourceId);
          String type = getDimensionType(attributeResourceId);
          attributeValue = '$value$type';
          break;
        case RES_TYPE_FRACTION:
          final value = resValue(attributeResourceId);
          final type = getFractionType(attributeResourceId);
          attributeValue = '$value$type';
          break;
        case RES_TYPE_DYNAMIC_REFERENCE:
          attributeValue = '@dyn/0x${attributeResourceId.toRadixString(16)}';
          break;
        case RES_TYPE_INT_DEC:
          attributeValue = attributeResourceId.toString();
          break;
        case RES_TYPE_INT_HEX:
          attributeValue =
              '0x${(attributeResourceId & 0xffffffff).toRadixString(16)}';
          break;
        case RES_TYPE_INT_BOOLEAN:
          attributeValue = _boolText(attributeResourceId);
          break;
        case RES_TYPE_INT_COLOR_ARGB8:
        case RES_TYPE_INT_COLOR_ARGB4:
          // ARGB: output all 4 channels as-is with # prefix
          attributeValue =
              '#${(attributeResourceId & 0xffffffff).toRadixString(16).padLeft(8, '0')}';
          break;
        case RES_TYPE_INT_COLOR_RGB8:
        case RES_TYPE_INT_COLOR_RGB4:
          // RGB: alpha is implicitly 0xFF
          attributeValue =
              '#ff${(attributeResourceId & 0x00ffffff).toRadixString(16).padLeft(6, '0')}';
          break;
        default:
          attributeValue =
              '0x${(attributeResourceId & 0xffffffff).toRadixString(16)}';
      }

      sb.write('$attributeName="$attributeValue"');
    }
  }

  List<String> parseStrings(ByteDataReader reader) {
    int stringMarker = reader.readInt16();
    if (stringMarker != RES_XML_STRING_TABLE) {
      throw FormatException(
          'Invalid String table identifier. Expecting 0x${RES_XML_STRING_TABLE.toRadixString(16)}, found 0x${stringMarker.toRadixString(16)}');
    }
    // All fields below are unsigned in the AOSP string-pool layout; reading
    // them as signed lets hostile high-bit values masquerade as small/negative
    // counts, so use readUint32 and validate.
    int headerSize = reader.readInt16();
    int chunkSize = reader.readUint32();
    if (chunkSize < headerSize || chunkSize > reader.remain + headerSize) {
      return [];
    }
    int numStrings = reader.readUint32();
    int numStyles = reader.readUint32();
    int flags = reader.readUint32();
    int stringStart = reader.readUint32();
    reader.readUint32(); // stylesStart

    bool isUtf8Encoded = (flags & UTF8_FLAG) != 0;

    return parseUsingByteBuffer(
      chunkSize,
      headerSize,
      numStrings,
      numStyles,
      isUtf8Encoded,
      stringStart,
      reader,
    );
  }

  List<String> parseUsingByteBuffer(
      int chunkSize,
      int headerSize,
      int numStrings,
      int numStyles,
      bool isUtf8Encoded,
      int stringStart,
      ByteDataReader reader) {
    int dataSize = chunkSize - headerSize;
    if (dataSize < 0) return [];
    Uint8List buffer = Uint8List(dataSize);
    reader.readFully(buffer);
    ByteDataReader bdr = ByteDataReader.wrapUint8List(buffer);

    // Guard against hostile numStrings causing unbounded allocation.
    // Each string needs at least a 4-byte offset entry in the buffer.
    if (numStrings < 0 ||
        numStrings > (dataSize ~/ 4) ||
        numStrings > (1 << 20)) {
      return [];
    }
    List<String> packedStrings = List<String>.filled(numStrings, '');
    List<int> offsets = List<int>.filled(numStrings, 0);

    for (int i = 0; i < numStrings; i++) {
      offsets[i] = bdr.readInt32();
    }

    // Skip style offsets table if present.
    if (numStyles > 0) {
      bdr.skipBytes(numStyles * 4);
    }

    final stringsStart = stringStart - headerSize;
    if (stringsStart < 0 || stringsStart >= dataSize) {
      throw FormatException(
          'Invalid string pool start: stringStart=$stringStart headerSize=$headerSize dataSize=$dataSize');
    }

    // Read the strings from each offset
    for (int i = 0; i < numStrings; i++) {
      final stringPos = stringsStart + offsets[i];
      if (stringPos < 0 || stringPos >= bdr.length) continue;
      bdr.position = stringPos;
      try {
        if (isUtf8Encoded) {
          _readLength8(bdr); // utf16 length, not needed for decoding.
          final utf8Len = _readLength8(bdr);
          if (utf8Len < 0 || utf8Len > bdr.remain) continue;
          final bytes = bdr.readUint8List(utf8Len);
          packedStrings[i] = utf8.decode(bytes, allowMalformed: true);
        } else {
          final utf16Len = _readLength16(bdr);
          final byteLen = utf16Len * 2;
          if (utf16Len < 0 || byteLen > bdr.remain) continue;
          final bytes = bdr.readUint8List(byteLen);
          final codeUnits = Uint16List.view(
            bytes.buffer,
            bytes.offsetInBytes,
            utf16Len,
          );
          packedStrings[i] = String.fromCharCodes(codeUnits);
        }
      } catch (_) {
        // 跳过解析失败的字符串
      }
    }
    return packedStrings;
  }

  int _readLength8(ByteDataReader reader) {
    final first = reader.readUint8();
    if ((first & 0x80) == 0) {
      return first;
    }
    final second = reader.readUint8();
    return ((first & 0x7f) << 8) | second;
  }

  int _readLength16(ByteDataReader reader) {
    final first = reader.readUint16();
    if ((first & 0x8000) == 0) {
      return first;
    }
    final second = reader.readUint16();
    return ((first & 0x7fff) << 16) | second;
  }

  /// 从混淆属性的 ns 字段中恢复可能被藏匿的值字符串
  void _rescueNsValue(XmlElement element, List<String> packedStrings,
      List<int> resourceIdMap, int nsIndex) {
    if (nsIndex >= resourceIdMap.length &&
        nsIndex >= 0 &&
        nsIndex < packedStrings.length) {
      final nsStr = packedStrings[nsIndex];
      if (nsStr.isNotEmpty &&
          !nsStr.startsWith('http://') &&
          !nsStr.startsWith('https://')) {
        element.extraStrings.add(nsStr);
      }
    }
  }

  /// 解析 Resource ID Map chunk (0x0180)
  /// 返回一个列表，索引对应字符串池索引，值为 Android 框架资源 ID
  List<int> _parseResourceIdMap(
      ByteDataReader reader, int chunkStart, int headerSize, int chunkSize) {
    final dataStart = chunkStart + headerSize;
    final dataSize = chunkSize - headerSize;
    final count = dataSize ~/ 4;
    reader.position = dataStart;
    return List<int>.generate(count, (_) => reader.readUint32());
  }

  /// 通过字符串池索引获取名称。
  ///
  /// 优先级：**Resource ID Map（框架属性）> 字符串池**。
  ///
  /// 为什么表优先：混淆/加固包会重写字符串池里的属性名，而 Resource ID Map
  /// 里的 32 位资源 ID 是结构化的、改不动 —— 前提是 [kFrameworkAttrNames]
  /// 本身正确。表一旦写错，这里就会**用错名字覆盖正确的名字**，而且编译、
  /// 单测、静态分析都发现不了（V2.4.14 实测：63 条里 51 条 ID 错位）。
  /// 所以这张表由 `test/fixtures/android_34_attrs.txt`（aapt2 输出快照）
  /// 逐条守着，改表必须先改夹具。
  ///
  /// 表里没有的 ID（非框架属性、或我们暂不消费的属性）回退字符串池 ——
  /// aapt2 一定会把属性名写进池里，这条回退在正常包上是可靠的。
  String _resolveStringOrResourceId(
      List<String> strings, List<int> resourceIdMap, int index) {
    if (index >= 0 && index < resourceIdMap.length) {
      final resId = resourceIdMap[index];
      final name = kFrameworkAttrNames[resId];
      if (name != null) return name;
    }

    // 回退到字符串池
    return _safeGet(strings, index);
  }

  /// AXML 布尔值的文本形式。
  ///
  /// `tvData` 是**有符号** 32 位读出来的（见 `_parseStartElement` 里的
  /// `readInt32`），而 `true` 的规范编码是 `0xffffffff`，即 `-1`。
  /// 曾经这里直接写 `data == 0xffffffff`，于是**每一个 `true` 都变成 `false`**：
  /// `android:debuggable="true"` 读成 `false`、`android:exported="true"`
  /// 读成 `false`。比「读不到」更糟 —— 读不到至少是 `null`，能被发现；
  /// 读成 `false` 是一个**看起来很正常的具体值**，没人会怀疑。
  ///
  /// 平台侧（`TypedArray.getBoolean`）的判据就是「非 0 即真」，这里照办，
  /// 顺带兼容把 `true` 写成 `1` 的构建工具。
  static String _boolText(int data) =>
      (data & 0xffffffff) == 0 ? 'false' : 'true';

  /// 安全访问字符串列表，越界时返回空字符串
  static String _safeGet(List<String> strings, int index) {
    if (index < 0 || index >= strings.length) return '';
    return strings[index];
  }

  static int getUnsignedShort(ByteData data, int position,
      [Endian endian = Endian.little]) {
    return data.getInt16(position, endian) & 0xffff;
  }

  static int getUnsignedByte(ByteData data, int position) {
    return data.getInt8(position) & 0xff;
  }

  static int getUnsignedInt(ByteData data, int position,
      [Endian endian = Endian.little]) {
    return data.getInt32(position, endian) & 0xffffffff;
  }

  static String getDimensionType(int data) {
    switch ((data >> COMPLEX_UNIT_SHIFT) & COMPLEX_UNIT_MASK) {
      case 0:
        return "px";
      case 1:
        return "dp";
      case 2:
        return "sp";
      case 3:
        return "pt";
      case 4:
        return "in";
      case 5:
        return "mm";
      default:
        return " (unknown unit)";
    }
  }

  static String getFractionType(int data) {
    switch ((data >> COMPLEX_UNIT_SHIFT) & COMPLEX_UNIT_MASK) {
      case COMPLEX_UNIT_FRACTION:
        return "%%";
      case COMPLEX_UNIT_FRACTION_PARENT:
        return "%%p";
      default:
        return "(unknown unit)";
    }
  }

  static double resValue(int data) {
    double value = (data & (COMPLEX_MANTISSA_MASK << COMPLEX_MANTISSA_SHIFT)) *
        RADIX_MULTS[(data >> COMPLEX_RADIX_SHIFT) & COMPLEX_RADIX_MASK];
    return value;
  }
}
