# IPA 测试样本

## embedded.mobileprovision

一个**真实的 CMS/PKCS#7 SignedData**，用 macOS 自带的 `security cms` 生成：

```sh
# 自签身份（临时钥匙串，用完即删）
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 2 -nodes -subj "/CN=Probe"
openssl pkcs12 -export -out id.p12 -inkey key.pem -in cert.pem -passout pass:probe
security create-keychain -p probe tmp.keychain
security import id.p12 -k tmp.keychain -P probe -T /usr/bin/security
security cms -S -N "Probe" -k tmp.keychain -i provision.plist -o embedded.mobileprovision
```

内容是一个典型的描述文件 plist：`Name` / `TeamIdentifier` /
`ApplicationIdentifierPrefix` / `UUID` / `CreationDate` / `ExpirationDate` /
`Entitlements`（含 `application-identifier`、`get-task-allow`、`aps-environment`）。

用 `security cms` 生成而不是手工拼字节：手工拼的 CMS 会带着与提取器相同的
错误假设。参照值取自 `security cms -D -i embedded.mobileprovision`。

**注意**：样本由自签证书签名，因此 `codesign` / `security` 的**信任链**校验会失败。
这是刻意的 —— 本项目**不做**签名验证（规范 5.5 禁止自行实现并宣称权威结论），
只做静态提取，所以自签样本足以覆盖被测逻辑。
