import 'dart:typed_data';
import 'byte_data_reader.dart';
import 'arsc/string_pool.dart';
import 'arsc/resource_value.dart';
import 'arsc/type_spec.dart';
import 'arsc/reference_graph.dart';
import 'models.dart';

/// resources.arsc 完整解析器
///
/// 解析 Android 资源表二进制格式，支持按资源 ID 查询字符串值、
/// 文件路径，以及获取所有 locale 和 density 变体。
///
/// 资源 ID 结构: 0xPPTTEEEE
/// - PP: package id
/// - TT: type id (1-based)
/// - EEEE: entry index
class ArscParser {
  /// 全局字符串池。解析失败时为 `null`（见 [parseFailure]）。
  ///
  /// 刻意不是 `late final`：构造里解析失败时它不会被赋值，而
  /// `getStringValue` 这类读取方仍可能被调用（例如调用方在失败后顺手读一下
  /// label）。`late final` 会在那里抛 `LateInitializationError` —— 那等于把
  /// 「构造不抛」换成了「下一次读才抛」，问题只是被推迟。
  StringPool? _globalStringPool;
  final List<_Package> _packages = [];

  /// 解析失败的原因；成功时为 `null`。
  ///
  /// 与「资源表里什么都没有」是两件事：后者是事实，前者意味着**我们没读到**。
  /// 覆盖率的 `android.arsc` 维度据此给出「缺失」还是「解析失败」。
  String? parseFailure;

  /// 构造即解析，**但不抛异常**。
  ///
  /// 畸形字节（空输入、截断、根本不是资源表）只会让 [parseFailure] 非空、
  /// 内部状态保持为空。理由与 `ManifestParser.parse` 相同：调用方需要
  /// 「读不到」这条事实本身，而不是一个只能整体放弃的异常。
  ArscParser(Uint8List data) {
    try {
      _parse(ByteDataReader.wrapUint8List(data, endian: Endian.little));
    } catch (e) {
      parseFailure = e.toString();
      _globalStringPool = null;
      _packages.clear();
    }
  }

  /// 通过资源 ID 获取字符串值
  /// [resourceId] 格式: 0xPPTTEEEE
  /// [locale] 可选的 locale 过滤 (如 "zh-CN", "en")
  String? getStringValue(int resourceId, {String? locale}) {
    final packageId = (resourceId >> 24) & 0xFF;
    final typeId = (resourceId >> 16) & 0xFF;
    final entryIndex = resourceId & 0xFFFF;

    final package = _findPackage(packageId);
    if (package == null) return null;

    final typeSpec = package.findTypeSpec(typeId);
    if (typeSpec == null) return null;

    // 优先查找匹配 locale 的配置，否则查找默认配置
    for (final config in typeSpec.configs) {
      final configLocale = config.config.locale;
      if (locale != null && locale.isNotEmpty) {
        if (configLocale != locale) continue;
      } else {
        if (configLocale.isNotEmpty) continue;
      }

      final entry = config.entries[entryIndex];
      if (entry == null || entry.value == null) continue;

      if (entry.value!.isString) {
        return _globalStringPool?.get(entry.value!.data);
      }
    }

    // 如果没有找到默认配置的值，尝试任意配置
    if (locale == null || locale.isEmpty) {
      for (final config in typeSpec.configs) {
        final entry = config.entries[entryIndex];
        if (entry == null || entry.value == null) continue;
        if (entry.value!.isString) {
          return _globalStringPool?.get(entry.value!.data);
        }
      }
    }

    return null;
  }

  /// 通过资源 ID 获取文件路径
  /// [resourceId] 格式: 0xPPTTEEEE
  /// [density] 可选的 density 过滤 (如 160, 240, 320, 480)
  String? getFilePath(int resourceId, {int? density}) {
    final packageId = (resourceId >> 24) & 0xFF;
    final typeId = (resourceId >> 16) & 0xFF;
    final entryIndex = resourceId & 0xFFFF;

    final package = _findPackage(packageId);
    if (package == null) return null;

    final typeSpec = package.findTypeSpec(typeId);
    if (typeSpec == null) return null;

    // 优先匹配指定 density
    if (density != null) {
      for (final config in typeSpec.configs) {
        if (config.config.density != density) continue;
        final entry = config.entries[entryIndex];
        if (entry == null || entry.value == null) continue;
        if (entry.value!.isString) {
          return _globalStringPool?.get(entry.value!.data);
        }
      }
    }

    // 回退到默认（density=0）或任意配置
    for (final config in typeSpec.configs) {
      if (density != null && config.config.density != 0) continue;
      final entry = config.entries[entryIndex];
      if (entry == null || entry.value == null) continue;
      if (entry.value!.isString) {
        return _globalStringPool?.get(entry.value!.data);
      }
    }

    // 最后尝试任意
    for (final config in typeSpec.configs) {
      final entry = config.entries[entryIndex];
      if (entry == null || entry.value == null) continue;
      if (entry.value!.isString) {
        return _globalStringPool?.get(entry.value!.data);
      }
    }

    return null;
  }

  /// 获取资源 ID 对应的所有 density 变体文件路径
  List<MapEntry<int, String>> getAllFilePaths(int resourceId) {
    final packageId = (resourceId >> 24) & 0xFF;
    final typeId = (resourceId >> 16) & 0xFF;
    final entryIndex = resourceId & 0xFFFF;

    final package = _findPackage(packageId);
    if (package == null) return [];

    final typeSpec = package.findTypeSpec(typeId);
    if (typeSpec == null) return [];

    final results = <MapEntry<int, String>>[];
    for (final config in typeSpec.configs) {
      final entry = config.entries[entryIndex];
      if (entry == null || entry.value == null) continue;
      if (entry.value!.isString) {
        final path = _globalStringPool?.get(entry.value!.data);
        if (path != null && _isValidResourcePath(path)) {
          results.add(MapEntry(config.config.density, path));
        }
      }
    }
    return results;
  }

  /// 获取资源表中所有的 locale 列表
  Set<String> getLocales() {
    final locales = <String>{};
    for (final package in _packages) {
      for (final typeSpec in package.typeSpecs.values) {
        for (final config in typeSpec.configs) {
          final locale = config.config.locale;
          if (locale.isNotEmpty) {
            locales.add(locale);
          }
        }
      }
    }
    return locales;
  }

  /// 获取资源表中所有的 density 列表
  Set<int> getDensities() {
    final densities = <int>{};
    for (final package in _packages) {
      for (final typeSpec in package.typeSpecs.values) {
        for (final config in typeSpec.configs) {
          final d = config.config.density;
          // 过滤无效值: 0 表示默认, >= 0xFFFE (65534) 为 sentinel 值
          if (d > 0 && d < 0xFFFE) {
            densities.add(d);
          }
        }
      }
    }
    return densities;
  }

  /// 资源表里是否有**夜间模式**变体（`values-night` / `drawable-night` 等）。
  ///
  /// 判据是配置的 `uiMode` 里夜间位为 `0x20`。注意 `0x10` 是显式的「非夜间」
  /// 变体、`0x00` 是未指定 —— 后两者都不算夜间资源，只有 `0x20` 才算。
  ///
  /// 这与 [getLocales] / [getDensities] 是同一类事实：**文件里声明了什么**，
  /// 不是「应用运行时会怎样」。用户把系统切到深色模式时是否真的变暗，还取决于
  /// 主题与代码，静态资源只能说明「随附了夜间资源」。
  bool get hasNightModeResources {
    for (final package in _packages) {
      for (final typeSpec in package.typeSpecs.values) {
        for (final config in typeSpec.configs) {
          if (config.config.isNightMode) return true;
        }
      }
    }
    return false;
  }

  /// 资源表中出现过的 `uiMode` 设备类型，已排序。
  ///
  /// 返回**稳定标识符**（`car` / `television` / `watch` …）而不是原始数字：
  /// 与加固线索的枚举名同理，它们要能与代码和日志对照。未指定（0）不返回 ——
  /// 它是「没写」而不是一种设备类型。
  List<String> getUiModeTypes() {
    final types = <String>{};
    for (final package in _packages) {
      for (final typeSpec in package.typeSpecs.values) {
        for (final config in typeSpec.configs) {
          final t = config.config.uiModeType;
          if (t != 0) types.add(ResourceConfig.uiModeTypeName(t));
        }
      }
    }
    return types.toList()..sort();
  }

  /// 导出所有资源条目信息，供外部使用（如图标渲染器）
  /// 按资源 ID 聚合所有 config 变体的值
  Map<int, ResourceInfo> getAllResources() {
    final results = <int, ResourceInfo>{};
    for (final package in _packages) {
      for (final typeEntry in package.typeSpecs.entries) {
        final typeId = typeEntry.key;
        final typeName =
            package.typeStringPool.get(typeId - 1) ?? 'type$typeId';
        for (final config in typeEntry.value.configs) {
          for (final entryKV in config.entries.entries) {
            final entryIndex = entryKV.key;
            final entry = entryKV.value;
            final resourceId = (package.id << 24) | (typeId << 16) | entryIndex;
            final keyName =
                package.keyStringPool.get(entry.keyIndex) ?? 'key$entryIndex';

            final info = results.putIfAbsent(
              resourceId,
              () => ResourceInfo(
                resourceId: resourceId,
                typeName: typeName,
                keyName: keyName,
              ),
            );

            if (entry.value != null) {
              if (entry.value!.isString) {
                final str = _globalStringPool?.get(entry.value!.data);
                if (str != null && !info.filePaths.contains(str)) {
                  info.filePaths.add(str);
                }
              } else if (entry.value!.isColor) {
                final color = entry.value!.colorHex;
                if (color != null && !info.colors.contains(color)) {
                  info.colors.add(color);
                }
              } else if (entry.value!.isReference) {
                final refId = entry.value!.data;
                if (refId != 0 && !info.references.contains(refId)) {
                  info.references.add(refId);
                }
              }
            }
          }
        }
      }
    }
    return results;
  }

  /// 在资源引用图里查找环。
  ///
  /// **为什么要查**：环上那几个资源互相定义、谁也没有真正的值，涉及它们的
  /// 取值在运行时会失败。这是一条实打实的缺陷信号。
  ///
  /// **但环不等于篡改**（实测结论）：`aapt2 link` 会接受环状的颜色别名并
  /// 原样写进资源表 —— 夹具 `cyclic-color-alias.apk` 就是 `aapt2` 产出的。
  /// 所以只能据此说「这些资源解析不了」，不能说「这个包被动过手脚」。
  ///
  /// 与图标渲染器的深度上限（`_kMaxDepth`）是两件事：那个上限只是防无限递归，
  /// 对所有深度超限一视同仁、也**不留说明**；这里把环本身找出来并描述清楚，
  /// 让「图标为什么画不出来」有据可查。
  ///
  /// 覆盖局限（经由 style / array 的间接引用查不到）见
  /// `ResourceReferenceGraph.findCycles` 的文档。
  ///
  /// 惰性调用：它要遍历整张表，因此不放进 `parse` 的热路径，由调用方按需触发。
  ReferenceCycleReport findReferenceCycles() =>
      ResourceReferenceGraph.findCycles(getAllResources());

  /// 跳过混淆器注入的非 StringPool chunk（如 type=0x0000 NULL chunk），
  /// 直到找到 StringPool (type=0x0001) 或到达边界。
  void _skipNullChunks(ByteDataReader reader, int boundary) {
    while (reader.position + 8 <= boundary) {
      final peekPos = reader.position;
      final chunkType = reader.readUint16();
      reader.readUint16(); // header size
      final chunkSize = reader.readUint32();
      reader.position = peekPos;

      if (chunkType == 0x0001) break; // 找到 StringPool
      if (chunkSize < 8 || peekPos + chunkSize > boundary) break;
      reader.skipBytes(chunkSize);
    }
  }

  /// 验证路径是否为合法的 Android 资源路径
  ///
  /// 混淆 APK 的资源表可能包含垃圾路径（如 `AndroidManifest.xml/uF.xml`、
  /// `classes.dex.png`），需要过滤掉。
  static bool _isValidResourcePath(String path) {
    if (!path.startsWith('res/')) return false;
    final lower = path.toLowerCase();
    // 排除系统文件名
    if (lower.contains('classes.dex') ||
        lower.contains('androidmanifest.xml') ||
        lower.contains('resources.arsc')) {
      return false;
    }
    // 必须以合法资源扩展名结尾
    return lower.endsWith('.png') ||
        lower.endsWith('.9.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.xml');
  }

  _Package? _findPackage(int id) {
    for (final package in _packages) {
      if (package.id == id) return package;
    }
    return null;
  }

  void _parse(ByteDataReader reader) {
    // ResTable_header
    reader.readUint16(); // type 0x0002
    final headerSize = reader.readUint16();
    reader.readUint32(); // total size
    final packageCount = reader.readUint32();

    if (headerSize > 12) {
      reader.skipBytes(headerSize - 12);
    }

    // 跳过混淆器注入的 NULL chunk，寻找 Global string pool
    _skipNullChunks(reader, reader.length);

    // Global string pool
    _globalStringPool = StringPool.parse(reader);

    // Parse packages
    for (var i = 0; i < packageCount && reader.remain > 0; i++) {
      try {
        _packages.add(_parsePackage(reader));
      } catch (_) {
        // 跳过解析失败的 package，继续解析剩余部分
        break;
      }
    }
  }

  _Package _parsePackage(ByteDataReader reader) {
    final packageStart = reader.position;

    final type = reader.readUint16(); // RES_TABLE_PACKAGE_TYPE = 0x0200
    final headerSize = reader.readUint16();
    final totalSize = reader.readUint32();
    final packageEnd = packageStart + totalSize;
    final packageId = reader.readUint32();

    assert(type == type); // suppress warning

    // Package name: 128 uint16 chars = 256 bytes
    final nameBytes = reader.readUint8List(256);
    final nameCodeUnits =
        Uint16List.view(nameBytes.buffer, nameBytes.offsetInBytes, 128);
    var packageName = String.fromCharCodes(nameCodeUnits);
    final nullIndex = packageName.indexOf('\x00');
    if (nullIndex >= 0) {
      packageName = packageName.substring(0, nullIndex);
    }

    final typeStringsOffset = reader.readUint32();
    reader.readUint32(); // lastPublicType
    final keyStringsOffset = reader.readUint32();
    reader.readUint32(); // lastPublicKey

    // Skip to end of header
    final headerRead = reader.position - packageStart;
    if (headerSize > headerRead) {
      reader.skipBytes(headerSize - headerRead);
    }

    // Parse type string pool（跳过混淆器注入的 NULL chunk）
    reader.position = packageStart + typeStringsOffset;
    _skipNullChunks(reader, packageEnd);
    final typeStringPool = StringPool.parse(reader);

    // Parse key string pool（跳过混淆器注入的 NULL chunk）
    reader.position = packageStart + keyStringsOffset;
    _skipNullChunks(reader, packageEnd);
    final keyStringPool = StringPool.parse(reader);

    final package = _Package(
      id: packageId,
      name: packageName,
      typeStringPool: typeStringPool,
      keyStringPool: keyStringPool,
    );

    // Parse remaining chunks (TypeSpec and Type)
    while (reader.position < packageEnd && reader.remain >= 8) {
      final chunkStart = reader.position;
      final chunkType = reader.readUint16();
      final chunkHeaderSize = reader.readUint16();
      final chunkSize = reader.readUint32();

      if (chunkSize < 8) break; // invalid chunk

      try {
        switch (chunkType) {
          case 0x0202: // RES_TABLE_TYPE_SPEC_TYPE
            _parseTypeSpec(reader, chunkHeaderSize, package);
            break;
          case 0x0201: // RES_TABLE_TYPE_TYPE
            _parseType(reader, chunkStart, chunkHeaderSize, chunkSize, package);
            break;
          default:
            // Skip unknown chunk
            break;
        }
      } catch (_) {
        // 跳过解析失败的 chunk，继续解析剩余部分
      }

      // Ensure we move to the next chunk
      reader.position = chunkStart + chunkSize;
    }

    reader.position = packageEnd;
    return package;
  }

  void _parseTypeSpec(ByteDataReader reader, int headerSize, _Package package) {
    final typeId = reader.readUint8();
    reader.readUint8(); // res0
    reader.readUint16(); // res1
    final entryCount = reader.readUint32();

    // Read entry flags
    if (entryCount > reader.remain ~/ 4) {
      return;
    }
    final entryFlags =
        List<int>.generate(entryCount, (_) => reader.readUint32());

    // Get type name
    final typeName = package.typeStringPool.get(typeId - 1) ?? 'type$typeId';

    // Create or update TypeSpec
    if (!package.typeSpecs.containsKey(typeId)) {
      package.typeSpecs[typeId] = TypeSpec(
        id: typeId,
        name: typeName,
        entryFlags: entryFlags,
        configs: [],
      );
    }
  }

  void _parseType(ByteDataReader reader, int chunkStart, int headerSize,
      int chunkSize, _Package package) {
    final typeId = reader.readUint8();
    reader.readUint8(); // res0
    reader.readUint16(); // res1
    final entryCount = reader.readUint32();
    final entriesStart = reader.readUint32();

    // Parse config
    final config = ResourceConfig.read(reader);

    // Jump to entry offsets (right after header)
    reader.position = chunkStart + headerSize;

    // Read entry offsets
    if (entryCount > reader.remain ~/ 4) {
      return;
    }
    final entryOffsets =
        List<int>.generate(entryCount, (_) => reader.readUint32());

    // Parse entries
    final entriesDataStart = chunkStart + entriesStart;
    final entries = <int, ResourceEntry>{};

    for (var i = 0; i < entryCount; i++) {
      if (entryOffsets[i] == 0xFFFFFFFF) continue; // NO_ENTRY

      reader.position = entriesDataStart + entryOffsets[i];

      // Parse entry header
      final entrySize = reader.readUint16();
      final entryFlags = reader.readUint16();
      final keyIndex = reader.readUint32();

      final isComplex = (entryFlags & 0x0001) != 0;

      if (isComplex) {
        // Complex/bag entry: ResTable_map_entry
        final parentRef = reader.readUint32();
        final mapCount = reader.readUint32();

        assert(parentRef == parentRef);
        assert(entrySize == entrySize);

        final mapValues = <int, ResourceValue>{};
        if (mapCount > reader.remain ~/ 12) {
          // 声明的 map 数量超过剩余数据能容纳的上限（损坏/恶意数据），
          // 仅解析可安全读取的部分后放弃该 chunk。
          for (var j = 0; j < mapCount && reader.remain >= 12; j++) {
            reader.readUint32();
            ResourceValue.read(reader);
          }
          entries[i] = ResourceEntry(
            flags: entryFlags,
            keyIndex: keyIndex,
            mapValues: mapValues,
          );
          continue;
        }
        for (var j = 0; j < mapCount; j++) {
          final mapName = reader.readUint32();
          final mapValue = ResourceValue.read(reader);
          mapValues[mapName] = mapValue;
        }

        entries[i] = ResourceEntry(
          flags: entryFlags,
          keyIndex: keyIndex,
          mapValues: mapValues,
        );
      } else {
        // Simple entry: Res_value
        final value = ResourceValue.read(reader);
        entries[i] = ResourceEntry(
          flags: entryFlags,
          keyIndex: keyIndex,
          value: value,
        );
      }
    }

    // Ensure TypeSpec exists
    if (!package.typeSpecs.containsKey(typeId)) {
      final typeName = package.typeStringPool.get(typeId - 1) ?? 'type$typeId';
      package.typeSpecs[typeId] = TypeSpec(
        id: typeId,
        name: typeName,
        entryFlags: [],
        configs: [],
      );
    }

    package.typeSpecs[typeId]!.configs.add(
      TypeConfig(config: config, entries: entries),
    );
  }
}

class _Package {
  final int id;
  final String name;
  final StringPool typeStringPool;
  final StringPool keyStringPool;
  final Map<int, TypeSpec> typeSpecs = {};

  _Package({
    required this.id,
    required this.name,
    required this.typeStringPool,
    required this.keyStringPool,
  });

  TypeSpec? findTypeSpec(int typeId) => typeSpecs[typeId];
}
