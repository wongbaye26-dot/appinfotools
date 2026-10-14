import 'dart:typed_data';
import 'binary_xml.dart';
import 'models.dart';

class ManifestParser {
  /// 从二进制 AndroidManifest.xml 解析。
  static ApkMeta parse(Uint8List manifestBytes) {
    final decompressor = BinaryXmlDecompressor();
    return fromDocument(decompressor.decompressToDocument(manifestBytes));
  }

  /// 从已反编译的文档树解析。
  ///
  /// 与 [parse] 拆开是为了让字段/组件提取逻辑可以脱离 AXML 二进制样本做
  /// 单元测试 —— 构造一个 [XmlDocument] 比手工拼二进制 manifest 可靠得多。
  static ApkMeta fromDocument(XmlDocument doc) {
    final meta = ApkMeta();

    // 布局异常要**先**取出来：下面有提前 return 的分支（找不到 <manifest>），
    // 而「这份文件布局非标准」这个事实与有没有 <manifest> 无关。
    meta.manifestLayoutAnomalies = doc.layoutAnomalies.evidence();

    final manifest = _findElement(doc, 'manifest');
    if (manifest == null) return meta;

    meta.packageName = manifest.attributes['package'];
    meta.versionCode = _parseInt(manifest.attributes['versionCode']);
    meta.versionName = manifest.attributes['versionName'];

    // 混淆 APK 可能无法通过属性名找到 package，
    // 启发式查找：在 manifest 属性中寻找类似包名的字符串值
    meta.packageName ??= _guessPackageName(manifest);
    // 混淆 APK: versionName 可能被藏匿在 ns 字段中
    meta.versionName ??= _guessVersionName(manifest);

    meta.compileSdkVersion =
        _parseInt(manifest.attributes['compileSdkVersion']);
    meta.compileSdkVersionCodename =
        manifest.attributes['compileSdkVersionCodename'];
    meta.platformBuildVersionName =
        manifest.attributes['platformBuildVersionName'];
    meta.platformBuildVersionCode =
        _parseInt(manifest.attributes['platformBuildVersionCode']);

    // <uses-sdk>
    final usesSdk = _findElement(manifest, 'uses-sdk');
    if (usesSdk != null) {
      meta.minSdkVersion = _parseInt(usesSdk.attributes['minSdkVersion']);
      meta.targetSdkVersion = _parseInt(usesSdk.attributes['targetSdkVersion']);
      meta.maxSdkVersion = _parseInt(usesSdk.attributes['maxSdkVersion']);
    }

    // <uses-permission>
    //
    // 同时保留两种形态：`permissions` 只要名字（应用层与既有测试的既有口径），
    // `permissionRequests` 额外记录 `maxSdkVersion` —— 权限审计需要按版本
    // 条件判断请求是否仍然生效，把条件丢掉会把旧版遗留声明误当成当前风险。
    for (final child in manifest.children) {
      if (child.name == 'uses-permission') {
        final name = child.attributes['name'];
        if (name != null && name.isNotEmpty) {
          meta.permissions.add(name);
          meta.permissionRequests.add(AndroidPermissionRequest(
            name,
            maxSdkVersion: _parseInt(child.attributes['maxSdkVersion']),
          ));
        }
      }
    }

    // <uses-permission-sdk-23>：该声明只在**设备 API < 23** 时授予。
    // 注意这与 maxSdkVersion 的条件口径不同（一个是设备版本、一个是声明上限），
    // 用 sdk23Only 标记，审计据此输出「无法从静态判定是否生效」。
    for (final child in manifest.children) {
      if (child.name != 'uses-permission-sdk-23') continue;
      final name = child.attributes['name'];
      if (name == null || name.isEmpty) continue;
      meta.permissionRequests.add(AndroidPermissionRequest(
        name,
        maxSdkVersion: _parseInt(child.attributes['maxSdkVersion']),
        sdk23Only: true,
      ));
      if (!meta.permissions.contains(name)) meta.permissions.add(name);
    }

    // <uses-feature>
    for (final child in manifest.children) {
      if (child.name == 'uses-feature') {
        final name = child.attributes['name'];
        if (name != null && name.isNotEmpty) {
          final required = child.attributes['required'];
          if (required == 'false') {
            meta.featuresNotRequired.add(name);
          } else {
            meta.features.add(name);
          }
        }
      }
    }

    // <supports-screens>
    final screens = _findElement(manifest, 'supports-screens');
    if (screens != null) {
      // 属性名映射：binary XML 中是 smallScreens 等，aapt2 格式是 small 等
      const screenNameMap = {
        'smallScreens': 'small',
        'normalScreens': 'normal',
        'largeScreens': 'large',
        'xlargeScreens': 'xlarge',
        'anyDensity': 'anyDensity',
        'resizeable': 'resizeable',
      };
      for (final attr in screens.attributes.entries) {
        if (attr.value == 'true') {
          final mapped = screenNameMap[attr.key];
          meta.screenSizes.add(mapped ?? attr.key);
        }
      }
    }
    // 没有解析到任何 screen 属性时（元素不存在或属性被混淆），
    // targetSdkVersion >= 4 默认支持所有屏幕尺寸
    if (meta.screenSizes.isEmpty && (meta.targetSdkVersion ?? 0) >= 4) {
      meta.screenSizes = ['small', 'normal', 'large', 'xlarge'];
    }

    // <application>
    final application = _findElement(manifest, 'application');
    if (application != null) {
      meta.applicationName = application.attributes['name'];
      meta.label = application.attributes['label'];
      meta.applicationIcon = application.attributes['icon'];
      meta.applicationDebuggable =
          _parseBool(application.attributes['debuggable']);

      // 明文流量开关（规则 D 的输入）。三态：未声明时系统按 targetSdk 给
      // 默认值（≥28 默认禁止），但那与「显式声明了 false」不是一回事，
      // 因此这里不把 null 折算成 true/false。
      meta.applicationUsesCleartextTraffic =
          _parseBool(application.attributes['usesCleartextTraffic']);
      meta.networkSecurityConfig =
          application.attributes['networkSecurityConfig'];

      // 混淆 APK: name/label 可能无法通过标准属性名找到
      meta.applicationName ??= _guessClassName(application);

      for (final child in application.children) {
        final type = ComponentType.fromElementName(child.name);
        if (type == null) continue;

        final isActivity = type == ComponentType.activity ||
            type == ComponentType.activityAlias;

        String? name = child.attributes['name'];
        // 混淆 APK: activity name 可能在非标准属性中。
        //
        // 只对 activity 做这个启发式：它会扫描属性值里「像包名」的字符串，
        // 对 service/receiver 而言很容易误取到 android:permission 之类的值，
        // 那等于凭空编造组件名。取不到就保持 null。
        if (name == null && isActivity) {
          name = _guessClassName(child);
        }

        meta.components.add(AndroidComponent(
          type: type,
          name: name,
          exported: _parseBool(child.attributes['exported']),
          permission: child.attributes['permission'],
          hasIntentFilter: child.children.any((c) => c.name == 'intent-filter'),
          authorities: child.attributes['authorities'],
        ));

        if (isActivity && _isLaunchableActivity(child)) {
          meta.launchableActivities.add(ActivityInfo(
            name: name,
            label: child.attributes['label'],
            icon: child.attributes['icon'],
          ));
        }
      }
    }

    return meta;
  }

  static bool _isLaunchableActivity(XmlElement activity) {
    for (final child in activity.children) {
      if (child.name != 'intent-filter') continue;
      bool hasMain = false;
      bool hasLauncher = false;
      for (final filterChild in child.children) {
        if (filterChild.name == 'action' &&
            filterChild.attributes['name'] == 'android.intent.action.MAIN') {
          hasMain = true;
        }
        if (filterChild.name == 'category' &&
            filterChild.attributes['name'] ==
                'android.intent.category.LAUNCHER') {
          hasLauncher = true;
        }
      }
      if (hasMain && hasLauncher) return true;
    }
    return false;
  }

  static XmlElement? _findElement(XmlElement parent, String name) {
    for (final child in parent.children) {
      if (child.name == name) return child;
    }
    return null;
  }

  static int? _parseInt(String? value) {
    if (value == null || value.isEmpty) return null;
    if (value.startsWith('0x')) {
      return int.tryParse(value.substring(2), radix: 16);
    }
    return int.tryParse(value);
  }

  /// 解析 AXML 中的布尔属性。
  ///
  /// 反编译器可能给出 `true`/`false`，也可能保留 `0xffffffff`/`0x0` 形式，
  /// 两种都接受；其余情况返回 `null` 表示**未声明或无法判定**，
  /// 不默认成 `false`。
  static bool? _parseBool(String? value) {
    if (value == null || value.isEmpty) return null;
    return switch (value.toLowerCase()) {
      'true' || '0xffffffff' || '0x1' => true,
      'false' || '0x0' => false,
      _ => null,
    };
  }

  // ========== 混淆 APK 启发式查找方法 ==========

  /// 启发式包名查找：在属性值中寻找符合 Java 包名格式的最短匹配
  static final _packageNamePattern =
      RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$');

  static String? _guessPackageName(XmlElement manifest) {
    String? shortest;
    for (final value in manifest.attributes.values) {
      if (_isPackageNameCandidate(value)) {
        if (shortest == null || value.length < shortest.length) {
          shortest = value;
        }
      }
    }
    return shortest;
  }

  static bool _isPackageNameCandidate(String value) {
    return value.contains('.') &&
        !value.startsWith('@') &&
        !value.startsWith('http') &&
        !value.contains(' ') &&
        _packageNamePattern.hasMatch(value);
  }

  /// 启发式版本名查找：在属性值和 extraStrings 中寻找版本号模式
  static final _versionPattern =
      RegExp(r'^\d+\.\d+(\.\d+)*([.\-_a-zA-Z0-9]*)$');

  static String? _guessVersionName(XmlElement manifest) {
    // 先搜索属性值
    for (final value in manifest.attributes.values) {
      if (_versionPattern.hasMatch(value)) return value;
    }
    // 搜索混淆属性中恢复的额外字符串
    for (final str in manifest.extraStrings) {
      if (_versionPattern.hasMatch(str)) return str;
    }
    return null;
  }

  /// 启发式类名查找：在属性值中寻找完全限定类名或以点开头的类名
  /// 如 "com.example.MainActivity" 或 ".MainActivity"
  static String? _guessClassName(XmlElement element) {
    for (final value in element.attributes.values) {
      if (value.contains('.') &&
          !value.startsWith('@') &&
          !value.startsWith('http') &&
          !value.contains(' ') &&
          _packageNamePattern.hasMatch(value)) {
        return value;
      }
    }
    return null;
  }
}
