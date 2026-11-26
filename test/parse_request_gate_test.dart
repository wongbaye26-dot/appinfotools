// 解析请求去重闸门。
//
// 对应一个实测缺陷：双击包启动应用时，路径从命令行参数与文件关联事件
// 两条入口同时到达，同一个 75 MB 的包被并行解析两遍（各约 19 s），
// 前一份结果被代际号丢弃。

import 'package:apk_info_tool/utils/parse_request_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('同一个文件重复触发被拦下，不同文件不拦', () {
    final gate = ParseRequestGate();

    expect(gate.isDuplicate('/a.apk'), isFalse);
    gate.begin('/a.apk');

    expect(gate.isDuplicate('/a.apk'), isTrue);
    expect(gate.isDuplicate('/b.apk'), isFalse);
  });

  test('结束后可以再次打开同一个文件', () {
    final gate = ParseRequestGate();
    gate.begin('/a.apk');
    gate.finish('/a.apk');

    expect(gate.inFlight, isNull);
    expect(gate.isDuplicate('/a.apk'), isFalse);
  });

  test('旧请求的 finish 不会清掉新请求的占用', () {
    final gate = ParseRequestGate();
    gate.begin('/a.apk');
    // 用户切到另一个文件：新请求立刻占用闸门。
    gate.begin('/b.apk');

    // 旧请求的 await 这时才返回，它的 finish 随后到达。
    gate.finish('/a.apk');

    expect(gate.inFlight, '/b.apk', reason: '按路径清理，旧请求不能把新请求的占用一起清掉');
    expect(gate.isDuplicate('/b.apk'), isTrue);
    expect(gate.isDuplicate('/a.apk'), isFalse,
        reason: '旧文件此刻可以重新打开（新请求是另一个文件）');
  });

  test('同一路径的两次 finish 是幂等的', () {
    final gate = ParseRequestGate();
    gate.begin('/a.apk');
    gate.finish('/a.apk');
    gate.finish('/a.apk');

    expect(gate.inFlight, isNull);
  });
}
