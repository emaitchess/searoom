# Contributing to Searoom

Thanks for helping make Mac telemetry quieter and more trustworthy.

## Development

Searoom requires macOS 14 or later and Swift 6. Build and validate it with:

```sh
Scripts/run-dev.sh
swift build --disable-sandbox
swift test --disable-sandbox
.build/debug/Searoom --self-test
```

Some Command Line Tools installations do not ship XCTest. If that module is
unavailable, run the build and framework-independent self-test and report that
XCTest did not execute.

Create and verify an ad-hoc signed app bundle with:

```sh
Scripts/build-app.sh
dist/Searoom.app/Contents/MacOS/Searoom --self-test
codesign --verify --deep --strict --verbose=2 dist/Searoom.app
plutil -lint dist/Searoom.app/Contents/Info.plist
```

When visual rules change, update `DESIGN.md` and run:

```sh
npx --yes @google/design.md lint DESIGN.md
```

## Expectations

- Keep the runtime dependency-free unless a dependency has a compelling,
  measured benefit.
- Prefer stable public macOS APIs. Isolate best-effort hardware access, fail
  closed, and document unsupported hardware.
- Do not add analytics, remote configuration, crash uploading, or any network
  request to the running app.
- Avoid subprocess collectors in the sample loop.
- Add tests for thresholds, persistence formats, formatting, and derived metrics.
- Measure idle CPU and resident memory for changes that affect sampling or UI.
- Preserve VoiceOver labels, system appearance support, and Reduce Motion.
- Keep `README.md`, `DESIGN.md`, and `AGENTS.md` synchronized with behavior.

## Brand assets

`Scripts/render-icon.swift` is the source of truth for the shared app-icon
geometry. It stages `AppIcon-1024.png`, `searoom-mark.svg`, and `AppIcon.icns`
before publishing them together. Do not hand-edit one format in isolation or
restore retired artwork under `Brand/`.

## Pull requests

Keep pull requests focused. Explain any formula used for a derived metric and
include the Mac model and macOS version used to verify hardware-sensor changes.
Search [existing issues](https://github.com/emaitchess/searoom/issues) before
opening a new report, and submit changes through a
[GitHub pull request](https://github.com/emaitchess/searoom/pulls).
