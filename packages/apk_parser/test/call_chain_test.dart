// 调用链：把「识别」与「上传」从「同方法体」扩到「1–2 跳」。
//
// ## 为什么
//
// `firstCoOccurrenceAcross` 只能回答「两个调用点是否在同一个方法体里」。
// 不在同一方法体时，此前直接掉到「整包层面共现」—— 那等于说「两个词都
// 出现在这个包里」，信息量接近零。而真实代码里更常见的形态是：
//
//   Pipeline.run()      → doOcr()        （识别）
//   Pipeline.run()      → buildRequest() → upload()   （上传）
//
// 这两种形态都能用调用图说清，且**仍然不是数据流** —— 跨调用传的参数没有跟踪。
// 这里的断言就是守住这条界线：能说路径，不能说是同一条数据流。
//
// ## 为什么直接构造结果对象
//
// 图算法与 DEX 解析是两件事。造一个带指定调用图的 DEX 需要 d8（本机没有），
// 而这里要测的只是「给定边，能否找到 1/2 跳」。解析侧的边由
// `android_security_e2e_test` 在真实 DEX 上覆盖。

import 'package:apk_parser/apk_parser.dart';
import 'package:test/test.dart';

DexMethodScanResult _scan({
  required List<CodeCoOccurrence> occurrences,
  Map<String, Set<String>> callers = const {},
  Map<String, Set<String>> edges = const {},
}) =>
    DexMethodScanResult(
      coOccurrences: occurrences,
      callersOfMarkerMethods: callers,
      edgesFromMarkerCallers: edges,
    );

CodeCoOccurrence _occ(String caller, List<String> markers) => CodeCoOccurrence(
      callerDisplayName: caller,
      markerIds: markers,
      dexNames: const ['classes.dex'],
    );

const _ocr = 'ocr-recognizetext';
const _upload = 'uploadimage';

void main() {
  test('直接调用：A(识别) → B(上传) 是 1 跳', () {
    final scan = _scan(
      occurrences: [
        _occ('LA;.doOcr()V', [_ocr]),
        _occ('LB;.upload()V', [_upload]),
      ],
      callers: {
        'LB;.upload()V': {'LA;.doOcr()V'},
      },
    );
    final chain = scan.firstChainBetween([_ocr], [_upload]);
    expect(chain, isNotNull);
    expect(chain!.hops, 1);
    expect(chain.path, 'LA;.doOcr()V → LB;.upload()V');
  });

  test('经由一个中间方法是 2 跳，路径里带出中间方法', () {
    final scan = _scan(
      occurrences: [
        _occ('LA;.doOcr()V', [_ocr]),
        _occ('LB;.upload()V', [_upload]),
      ],
      edges: {
        'LA;.doOcr()V': {'LX;.build()V'},
      },
      callers: {
        'LB;.upload()V': {'LX;.build()V'},
      },
    );
    final chain = scan.firstChainBetween([_ocr], [_upload]);
    expect(chain, isNotNull);
    expect(chain!.hops, 2);
    expect(chain.via, 'LX;.build()V');
    expect(chain.path, 'LA;.doOcr()V → LX;.build()V → LB;.upload()V');
  });

  test('1 跳优先于 2 跳（同一份输入里两条路径都在）', () {
    final scan = _scan(
      occurrences: [
        _occ('LA;.doOcr()V', [_ocr]),
        _occ('LB;.upload()V', [_upload]),
        _occ('LC;.alsoOcr()V', [_ocr]),
      ],
      edges: {
        'LC;.alsoOcr()V': {'LX;.build()V'},
      },
      callers: {
        'LB;.upload()V': {'LA;.doOcr()V', 'LX;.build()V'},
      },
    );
    final chain = scan.firstChainBetween([_ocr], [_upload]);
    expect(chain!.hops, 1);
  });

  test('没有边时返回 null —— 不能说「有调用链」', () {
    final scan = _scan(
      occurrences: [
        _occ('LA;.doOcr()V', [_ocr]),
        _occ('LB;.upload()V', [_upload]),
      ],
    );
    expect(scan.firstChainBetween([_ocr], [_upload]), isNull);
  });

  test('maxHops=1 时不返回 2 跳的结果', () {
    final scan = _scan(
      occurrences: [
        _occ('LA;.doOcr()V', [_ocr]),
        _occ('LB;.upload()V', [_upload]),
      ],
      edges: {
        'LA;.doOcr()V': {'LX;.build()V'},
      },
      callers: {
        'LB;.upload()V': {'LX;.build()V'},
      },
    );
    expect(scan.firstChainBetween([_ocr], [_upload], maxHops: 1), isNull);
  });

  test('空输入返回 null，不抛异常', () {
    final scan = _scan(occurrences: const []);
    expect(scan.firstChainBetween([_ocr], [_upload]), isNull);
    expect(scan.firstChainBetween(const [], [_upload]), isNull);
  });
}
