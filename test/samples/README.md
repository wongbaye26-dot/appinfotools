# Fixed sample manifest

Real install packages are usually not redistributable, so the regression input is
described by a manifest instead of being committed.

```bash
APPINFOTOOL_SAMPLE_MANIFEST=/path/to/manifest.json \
APPINFOTOOL_SAMPLES=/path/to/samples \
flutter test test/sample_regression_test.dart
```

`APPINFOTOOL_SAMPLES` is optional; without it the manifest directory is used.

## CI: public samples from `manifest.json`

`test/samples/manifest.json` lists **redistributable** public samples (currently
two F-Droid apps: the F-Droid client and FFUpdater, a Flutter app). Each entry
carries a pinned `url` and `sha256`, so CI can download the exact bytes the
assertions were written against:

- the `external-samples` job fetches them when no private archive is configured,
  verifies SHA-256, and exports `APPINFOTOOL_SAMPLES`;
- a download or checksum mismatch **fails the job** — the gate never degrades
  silently;
- `APPINFOTOOL_REQUIRED_SAMPLE_PLATFORMS` scopes which platforms the gate
  enforces. CI sets `android` (public samples only exist for Android today) and
  prints a warning that iOS is not covered; when an `.ipa` is present it requires
  `android,ios` instead.

Private / non-redistributable samples still use `APPINFOTOOL_SAMPLES_ARCHIVE_URL`
(a secret) or a local directory, and the manifest file name stays the same.

## Auto-discovery (real-sample tests)

The real-sample tests (`test/real_samples_test.dart`,
`test/real_samples_smoke_test.dart`, `test/security_baseline_test.dart`) accept
`APPINFOTOOL_SAMPLES`, and when it is unset they probe, in order:

1. `samples/` (repository root)
2. `test/samples/`
3. `~/Downloads/AppInfoTool Samples`
4. `~/Documents/AppInfoTool Samples`
5. `~/Desktop/AppInfoTool Samples`

The first directory that contains at least one supported package wins. An
explicit `APPINFOTOOL_SAMPLES` always takes precedence — if it points at a
missing directory the tests skip with that path in the reason instead of
silently falling back, so a typo is visible. When nothing is found the skip
reason lists every probed location.

## Format

```json
{
  "samples": [
    {
      "file": "sample.apk",
      "kind": "android",
      "sha256": "64 hex characters",
      "expectedFindingRules": ["ANDROID-PERM-COMBINATION"],
      "expectedEvidenceSources": ["manifest"],
      "expectedCoverageIds": ["android.manifest", "android.dex.strings"]
    }
  ]
}
```

- `file` must be a bare file name, not a path.
- `kind` is `android` or `ios`.
- `sha256` is required and checked before parsing.
- The three expectation arrays are optional. Empty arrays still verify SHA,
  parse and report generation; non-empty arrays additionally assert that the
  sample still produces the expected rule/evidence/coverage IDs.

The test skips when `APPINFOTOOL_SAMPLE_MANIFEST` is absent. A release gate
should provide both the manifest and `APPINFOTOOL_REQUIRE_SAMPLES=1` (the latter
is enforced by `test/real_samples_smoke_test.dart`).
