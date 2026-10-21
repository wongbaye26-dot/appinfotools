// 链上地址字面量的识别。
//
// 这条信号用来支撑「盗 U」风险分析：地址替换型恶意代码必然在包里写死一个
// 收款地址。判宽的代价是**每个应用都被报**（哈希、颜色值、内存地址都会被
// 当成地址），所以边界条件要逐条钉住。

import 'package:analysis_model/analysis_model.dart';
import 'package:test/test.dart';

void main() {
  group('EVM', () {
    test('标准 40 位十六进制命中', () {
      final hits =
          findCryptoAddresses('to=0x52908400098527886E0F7030069857D2E4169EE7');
      expect(hits, hasLength(1));
      expect(hits.single.format, CryptoAddressFormat.evm);
      expect(hits.single.address, '0x52908400098527886E0F7030069857D2E4169EE7');
    });

    test('39 位或 41 位不命中', () {
      expect(findCryptoAddresses('0x52908400098527886E0F7030069857D2E4169EE'),
          isEmpty);
      expect(findCryptoAddresses('0x52908400098527886E0F7030069857D2E4169EE77'),
          isEmpty);
    });

    test('长十六进制串（哈希）里的片段不命中', () {
      // 前后紧邻十六进制字符时是更长串的一部分，不能切一段出来当地址。
      final hash = '0x${'a' * 64}';
      expect(findCryptoAddresses(hash), isEmpty);
    });

    test('非十六进制字符紧跟其后也算边界', () {
      final hits = findCryptoAddresses(
          'addr:0x52908400098527886E0F7030069857D2E4169EE7,"symbol":"USDT"');
      expect(hits, hasLength(1));
    });
  });

  group('TRON', () {
    test('T + 33 位 base58 命中', () {
      final hits = findCryptoAddresses('TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t');
      expect(hits, hasLength(1));
      expect(hits.single.format, CryptoAddressFormat.tron);
    });

    test('含 0/O/I/l 的串不是合法 base58，不命中', () {
      expect(
        findCryptoAddresses('T0OIlHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t'),
        isEmpty,
      );
    });

    test('长度不足不命中', () {
      expect(findCryptoAddresses('TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6'), isEmpty);
    });
  });

  group('Bitcoin bech32', () {
    test('bc1 开头命中', () {
      final hits =
          findCryptoAddresses('bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq');
      expect(hits, hasLength(1));
      expect(hits.single.format, CryptoAddressFormat.bitcoin);
    });
  });

  group('不该命中的东西', () {
    test('短字符串直接返回空（不跑正则）', () {
      expect(findCryptoAddresses('0x1234'), isEmpty);
    });

    test('包名、URL、普通文本都不命中', () {
      expect(
        findCryptoAddresses(
            'https://api.example.com/v1/wallet/transfer?chain=tron'),
        isEmpty,
      );
      expect(
          findCryptoAddresses('com.example.wallet.TransferActivity'), isEmpty);
    });

    test('空串不崩', () {
      expect(findCryptoAddresses(''), isEmpty);
    });
  });

  test('同一地址重复出现只保留一条', () {
    const address = '0x52908400098527886E0F7030069857D2E4169EE7';
    final hits = findCryptoAddresses('$address $address');
    expect(hits, hasLength(1));
  });

  group('公开合约地址不算「写死的收款地址」', () {
    test('USDT-TRC20 合约地址被过滤', () {
      // 正规 TRON 钱包都会写死这个常量。不过滤的话，「钱包 + 剪贴板 + 写死
      // 地址」会在每个正规钱包上命中。
      const usdt = 'TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t';
      expect(findCryptoAddresses(usdt), hasLength(1), reason: '识别本身不受影响');
      final out = <CryptoAddressHit>{};
      collectCryptoAddresses(usdt, out);
      expect(out, isEmpty);
    });

    test('EVM 合约地址按小写比较（大小写不敏感）', () {
      final out = <CryptoAddressHit>{};
      collectCryptoAddresses(
        '0xDAC17F958D2ee523a2206206994597C13D831ec7',
        out,
      );
      expect(out, isEmpty);
    });

    test('零地址与销毁地址被过滤', () {
      final out = <CryptoAddressHit>{};
      collectCryptoAddresses(
        '0x0000000000000000000000000000000000000000',
        out,
      );
      collectCryptoAddresses(
        '0x000000000000000000000000000000000000dEaD',
        out,
      );
      expect(out, isEmpty);
    });

    test('普通收款地址仍然保留', () {
      final out = <CryptoAddressHit>{};
      collectCryptoAddresses(
        'TXk9W1FpvF9PCw8c5wLKr6vH7Wq3vJ9dKt',
        out,
      );
      expect(out, hasLength(1));
    });

    test('includeKnown 时连常量一起收（诊断用）', () {
      final out = <CryptoAddressHit>{};
      collectCryptoAddresses(
        'TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t',
        out,
        includeKnown: true,
      );
      expect(out, hasLength(1));
    });
  });

  test('collectCryptoAddresses 遵守上限', () {
    final out = <CryptoAddressHit>{};
    for (var i = 0; i < 10; i++) {
      collectCryptoAddresses(
        '0x${i.toRadixString(16).padLeft(2, '0')}${'a' * 38}',
        out,
        max: 3,
      );
    }
    expect(out, hasLength(3));
  });
}
