// 共享的端点提取（Android 与 iOS 用同一份）。
//
// 背景：域名提取原本只存在于 `DexClueScanner` 里，iOS 侧从不产出
// `NetworkFacts`（2026-10-19 审计 P2-6）。下沉到 `analysis_model` 后两边共用，
// 但立刻暴露了一个新问题：Mach-O 里塞着大量 Web 资源，`something://` 后面
// 跟的常常不是主机名 —— 实测会产出 `.css`、`In`、`UA-Compatible`、`according`
// 这类垃圾。一条「域名清单」里混进英文单词，比没有清单更糟。
//
// 所以这里同时钉住两件事：**能认出真域名**，**不把单词当域名**。

import 'package:analysis_model/analysis_model.dart';
import 'package:test/test.dart';

void main() {
  group('URL 主机名', () {
    test('带 scheme 的只保留主机名，不带路径', () {
      final facts = NetworkEndpoints.fromStrings([
        'https://api.example.com/v1/upload',
        'wss://socket.example.org/ws',
      ]);
      expect(facts.domains, contains('api.example.com'));
      expect(facts.domains, contains('socket.example.org'));
      expect(facts.domains.any((d) => d.contains('/')), isFalse);
    });

    test('主机名不像域名时**不收录**（Mach-O 里的 Web 资源会这么干）', () {
      final facts = NetworkEndpoints.fromStrings([
        'data:text/css://.css',
        'see://In',
        'x://UA-Compatible',
        'y://according',
      ]);
      expect(facts.domains, isEmpty, reason: '实际：${facts.domains}');
    });
  });

  group('裸域名', () {
    test('常见 TLD 认得出，端口与路径被剥掉', () {
      final facts = NetworkEndpoints.fromStrings([
        'sub.domain.org.cn',
        'example.com:8080/callback',
      ]);
      expect(facts.domains, contains('sub.domain.org.cn'));
      expect(facts.domains, contains('example.com'));
    });

    test('随机英文串不是域名', () {
      final facts = NetworkEndpoints.fromStrings(['abcdefghij', 'hello world']);
      expect(facts.domains, isEmpty);
    });
  });

  group('IP 与边界', () {
    test('IPv4 进 ips，不进 domains', () {
      final facts = NetworkEndpoints.fromStrings(['http://10.0.0.7:8080/cb']);
      expect(facts.ips, contains('10.0.0.7'));
      expect(facts.domains, isEmpty);
    });

    test('超过上限就停，不无限增长', () {
      final many = [
        for (var i = 0; i < NetworkEndpoints.maxEndpoints + 30; i++)
          'host$i.example.com',
      ];
      final facts = NetworkEndpoints.fromStrings(many);
      expect(facts.domains.length, NetworkEndpoints.maxEndpoints);
    });

    test('空输入返回空事实，不抛异常', () {
      final facts = NetworkEndpoints.fromStrings(const []);
      expect(facts.isEmpty, isTrue);
    });
  });
}
