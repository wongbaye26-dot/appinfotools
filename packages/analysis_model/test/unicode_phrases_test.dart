// 共享中文话术词表的漂移守卫。
//
// 这张表同时喂 Android DEX（MUTF-8）与 iOS（UTF-8 / UTF-16）。写一条永远
// 命中不了的字面量，两个平台会一起静默漏检 —— 所以约束在表所在的包里钉住，
// 而不是靠某一侧的测试顺带看着。

import 'package:analysis_model/analysis_model.dart';
import 'package:test/test.dart';

void main() {
  test('词表本身：全非 ASCII、长度 ≥2、无重复、互不嵌套', () {
    expect(unicodePhraseMarkers, isNotEmpty);
    final ids = <String>[];
    final literals = <String>[];
    for (final marker in unicodePhraseMarkers) {
      expect(marker.id, isNotEmpty);
      expect(marker.literal.length, greaterThanOrEqualTo(2),
          reason: '${marker.id} 太短，会被提取器的 minLength 挡掉');
      expect(
        marker.literal.runes.every((r) => r >= 0x80),
        isTrue,
        reason: '${marker.id} 含 ASCII —— 那该写进 ASCII 标记表',
      );
      ids.add(marker.id);
      literals.add(marker.literal);
    }
    expect(ids.toSet(), hasLength(ids.length), reason: '标记 id 重复');
    expect(literals.toSet(), hasLength(literals.length), reason: '字面量重复');
    for (final a in unicodePhraseMarkers) {
      for (final b in unicodePhraseMarkers) {
        if (identical(a, b)) continue;
        expect(b.literal.contains(a.literal), isFalse,
            reason: '${a.literal} 是 ${b.literal} 的子串，同一句会重复命中');
      }
    }
  });

  test('三组分类齐全，且派生 id 集合与表一致', () {
    final byKind = <UnicodePhraseKind, int>{
      for (final kind in UnicodePhraseKind.values) kind: 0,
    };
    for (final marker in unicodePhraseMarkers) {
      byKind[marker.kind] = byKind[marker.kind]! + 1;
    }
    for (final kind in UnicodePhraseKind.values) {
      expect(byKind[kind], greaterThan(0), reason: '$kind 一组词都没有');
    }
    expect(socialPhraseIds.length, byKind[UnicodePhraseKind.social]);
    expect(seedPhraseIds.length, byKind[UnicodePhraseKind.seed]);
    expect(
      socialPhraseIds.every((id) => unicodePhraseMarkers
          .any((m) => m.id == id && m.kind == UnicodePhraseKind.social)),
      isTrue,
    );
  });
}
