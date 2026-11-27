# Fixed sample manifest

Real install packages are usually not redistributable, so the regression input is
described by a manifest instead of being committed.

```bash
APPINFOTOOL_SAMPLE_MANIFEST=/path/to/manifest.json \
APPINFOTOOL_SAMPLES=/path/to/samples \
flutter test test/sample_regression_test.dart
```

`APPINFOTOOL_SAMPLES` is optional; without it the manifest directory is used.

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
