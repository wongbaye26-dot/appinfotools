# AppInfoTool 2.11.0 — Stage 1 AnalysisRun 实施记录

## 结论

Stage 1 完成：每次 Android/iOS 分析都会创建一条 AnalysisRun，完成后保存真实报告 JSON 快照；应用重启后 run 文件仍存在。

## 数据模型

`lib/models/analysis/analysis_run.dart`

- `AnalysisRunStatus`：queued / running / success / partial / failed / cancelled。
- `AnalysisRun`：id、toolVersion、appName、platform、packagePath、packageSha256、startedAt、completedAt、status、snapshot、limitations。
- `AnalysisRunSummary`：历史列表轻量摘要。
- JSON schemaVersion = 1；坏字段抛 `FormatException`。
- `snapshot` 只在真实结果存在且 `renderJson` 成功时写入；失败记录 `report.snapshot.failed` limitation。

## 仓库

`lib/utils/analysis_run_repository.dart`

- 目录：`ApplicationSupportDirectory/analysis_runs/<id>.json` + `index.json`。
- 原子写：临时文件 + rename。
- 索引损坏/缺失时从 run 文件重建；单个损坏 run 跳过并保留文件。
- id 白名单，拒绝 `../`。
- maxRuns = 100；只删除最旧的非 running run；遇到 running 停止裁剪。
- `list()` 按 startedAt 倒序，默认 50 条。

## 接入

- `lib/providers/analysis_run_provider.dart`：生产仓库 + `package_info_plus` 版本。
- `FileState` 增加 `analysisRunId` / `analysisRunStatus`。
- `lib/pages/info_page.dart`：
  - Android / iOS 解析开始：`_beginAnalysisRun` 写 running。
  - 成功/部分/失败/取消：`_finishAnalysisRun` 更新状态并保存真实快照。
  - 快照只在当前文件仍匹配 run.packagePath 时写入；切文件不会把新结果写进旧 run。
  - run 写入失败只记日志，不阻断解析。

## 真实运行证据

打开 `sun_signed.ipa` 后：

```text
~/Library/Application Support/to.feng.app.apkinfotool.apkInfoTool/analysis_runs/
  index.json
  analysis_1795793230570326_unknown.json   # 99,733 bytes
```

JSON 中：

- status = success
- appName = SUN
- platform = ios
- packageSha256 = 736fa5d3...903
- snapshot.reportSchemaVersion = 8
- snapshot 含 platformFacts/application/signatureSummary/security/network/findings/coverage

打开 `217_0919155004.apk` 后新增一条 Android success run（52,576 bytes，schema 8）。

## 验证

```bash
flutter analyze --fatal-infos --fatal-warnings   # No issues found
dart format --output=none --set-exit-if-changed . # 463 files, 0 changed
flutter test                                     # 1888 passed / 19 skipped
flutter build bundle                             # exit 0
flutter test test/analysis_run_test.dart          # 10 passed
flutter test test/analysis_run_recorder_test.dart # 3 passed
```

## 未做 / 下一步

- 历史 UI 列表、重新打开历史 run、删除 run 的界面尚未接入（Stage 1 只做存储与生命周期）。
- run id 在哈希未完成时使用 `_unknown` 后缀；后续可改为文件路径短哈希。
- snapshot 仍使用报告 schema 8 的整包 JSON，Stage 2–5 再拆 Evidence/Graph/Network 顶层结构。
- Stage 2：独立 Evidence 实体、Finding→evidenceIds、Coverage failed/notScanned 执行状态。
