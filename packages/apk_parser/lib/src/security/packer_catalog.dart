// 加固壳识别（**只识别，不脱壳**）。
//
// ## 为什么只做识别
//
// 真正的「脱壳」需要在 ART 里把应用跑起来、在 `DexClassLoader` 加载之后把
// 内存里的 DEX dump 出来 —— 那是动态分析，跟本项目「静态、不解包执行」的
// 边界直接冲突。静态侧能做的、也确实有用的是**认出这是哪个壳**：
//
// - 用户拿到一个分析结果不完整的包，第一件想知道的事就是「它是不是加固了、
//   哪个壳」；
// - 认出壳之后，报告里那些「没扫到 DEX 内容」的维度才有解释；
// - 壳的特征非常稳定（库文件名 + 包名），识别成本极低。
//
// 所以这里给的是**结论 + 边界**：认出来了就说认出来了，并且明确写
// 「本工具不做脱壳，DEX 与字符串类结论可能不完整」。
//
// ## 判据
//
// 只看**原生库文件名**：壳必须把解密器编译成 `.so` 并随包分发，名字是
// 各家自己定的、极少改动（`libjiagu.so`、`libshella-*.so`…）。相比之下
// 「DEX 里出现某个类名」既可能是壳，也可能是业务代码里提了一句。

/// 一个加固壳的特征。
class PackerSignature {
  /// 稳定 id，例如 `jiagu`。
  final String id;

  /// 厂商 / 产品名（英文回退，本地化文案按 [id] 取）。
  final String displayName;

  /// 原生库文件名的**子串**（不含 `lib` 前缀与 `.so` 后缀，小写比较）。
  ///
  /// 用子串而不是全等：同一家壳会带版本号（`libshella-2.10.so`）或 ABI 后缀
  /// （`libjiagu_a64.so`）。
  final List<String> libraryMarkers;

  const PackerSignature({
    required this.id,
    required this.displayName,
    required this.libraryMarkers,
  });
}

/// 一次识别命中的壳。
class PackerHit {
  final PackerSignature signature;

  /// 命中的库文件名（证据）。
  final List<String> libraries;

  const PackerHit({required this.signature, required this.libraries});

  String get id => signature.id;
  String get displayName => signature.displayName;
}

/// 已知加固壳的特征表。
///
/// 收录标准：**国内有实际分发的商业壳**，且特征库名足够独特。
/// 加固方案迭代很快，这张表一定会过时 —— 过时的表现是「没认出来」，
/// 那只是少一条信息，不会造成误报。
const List<PackerSignature> packerCatalog = [
  PackerSignature(
    id: 'jiagu',
    displayName: '360 Jiagu',
    libraryMarkers: ['libjiagu'],
  ),
  PackerSignature(
    id: 'legu',
    displayName: 'Tencent Legu',
    libraryMarkers: ['libshella', 'libshellx', 'libtup'],
  ),
  PackerSignature(
    id: 'bangcle',
    displayName: 'Bangcle (SecNeo)',
    libraryMarkers: ['libsecexe', 'libsecmain', 'libsecshell'],
  ),
  PackerSignature(
    id: 'ijiami',
    displayName: 'ijiami',
    libraryMarkers: ['libexecmain', 'libexec.so', 'libijiami'],
  ),
  PackerSignature(
    id: 'mobisec',
    displayName: 'Alibaba MobiSec',
    libraryMarkers: ['libmobisec'],
  ),
  PackerSignature(
    id: 'netease',
    displayName: 'NetEase Yidun',
    libraryMarkers: ['libnesec'],
  ),
  PackerSignature(
    id: 'baidu',
    displayName: 'Baidu Protect',
    libraryMarkers: ['libbaiduprotect'],
  ),
  PackerSignature(
    id: 'dingxiang',
    displayName: 'Dingxiang',
    libraryMarkers: ['libx3g'],
  ),
  PackerSignature(
    id: 'kiwisec',
    displayName: 'KiwiSec',
    libraryMarkers: ['libkwscmm', 'libkwscr'],
  ),
  PackerSignature(
    id: 'nagain',
    displayName: 'Nagain (DexHelper)',
    libraryMarkers: ['libdexhelper'],
  ),
];

/// 按原生库文件名识别加固壳。
class PackerDetector {
  PackerDetector._();

  /// [libraryNames] 是归档内的完整路径（`lib/arm64-v8a/libjiagu.so`）。
  static List<PackerHit> detect(Iterable<String> libraryNames) {
    final hits = <PackerHit>[];
    for (final signature in packerCatalog) {
      final matched = <String>[];
      for (final name in libraryNames) {
        final lower = name.toLowerCase();
        if (!lower.endsWith('.so')) continue;
        final base = lower.split('/').last;
        for (final marker in signature.libraryMarkers) {
          if (base.contains(marker)) {
            matched.add(name);
            break;
          }
        }
      }
      if (matched.isEmpty) continue;
      hits.add(PackerHit(signature: signature, libraries: matched..sort()));
    }
    return hits;
  }
}
