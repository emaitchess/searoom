# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Authoritative documents

- `AGENTS.md` is the contributor contract: product invariants, metric semantics, the per-change-type verification table, and packaging rules. Read it before any broad change.
- `DESIGN.md` is the source of truth for the visual system, as machine-readable tokens plus prose. `SearoomStyle.swift`, `DashboardView.swift`, Settings, and brand assets implement it rather than inventing local variants.
- `README.md` documents the user-facing metric semantics and their limitations.

This file covers the commands and the cross-file architecture you would otherwise have to reconstruct by reading half the source.

## Commands

Run everything from the repository root.

```sh
Scripts/run-dev.sh                      # build and run attached to the terminal; Ctrl-C to stop
swift build --disable-sandbox
swift test --disable-sandbox
swift test --disable-sandbox --filter testCollectorReturnsBoundedValues   # single test (regex match)
.build/debug/Searoom --self-test       # framework-independent; works without XCTest
.build/debug/Searoom --dump-sample     # one JSON sample on stdout
```

`--dump-sample` and `--self-test` both take two samples internally, because delta-based metrics (CPU, network, disk, self CPU) have no previous counter on the first read and are intentionally zero.

Packaging and asset generation:

```sh
Scripts/release.sh                      # signed, notarized, stapled dist/Searoom.zip (add --publish to tag and release)
Scripts/build-app.sh                    # ad-hoc signed dist/Searoom.app
swift Scripts/render-icon.swift Brand   # regenerates AppIcon-1024.png, searoom-mark.svg, AppIcon.icns
npx --yes @google/design.md lint DESIGN.md   # must report zero errors and zero warnings
```

Regenerating the mark also requires re-copying `AppIcon-1024.png` and
`searoom-mark.svg` into the website repository's `assets/`, which keeps its own
copies so it can deploy standalone.

Focused checks worth running when you touch the matching area:

```sh
clang -Wall -Wextra -Werror -fsyntax-only -I Sources/CSearoomSensors/include Sources/CSearoomSensors/SearoomSensors.c
bash -n Scripts/build-app.sh Scripts/notarize.sh Scripts/release.sh
plutil -lint Support/Info.plist
codesign --verify --deep --strict --verbose=2 dist/Searoom.app
```

If Swift cannot write its default module cache, redirect only the caches:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/searoom-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/searoom-swiftpm-cache \
swift build --disable-sandbox
```

## Architecture

### One sampling pipeline

`MetricsEngine` (defined at the bottom of `Metrics/SystemMetricsCollector.swift`, not its own file) owns a single serial utility-QoS `DispatchSourceTimer` on `app.searoom.metrics`. It drives one `SystemMetricsCollector`, which owns every stateful subcollector, produces an immutable `SystemSample`, and hops to the main queue.

```
MetricsEngine timer -> SystemMetricsCollector -> SystemSample -> @MainActor AppModel
    -> NotificationCenter -> AppDelegate -> status item + visible DashboardView
```

Never add a second timer, a `Task.detached`, or a parallel collector. Rate collectors (`CPUCollector`, `NetworkCollector`, `DiskCollector`, `ProcessCollector`) hold previous counters and a `ContinuousClock` instant, so they are correct only while confined to that serial queue. The C sensor bridge also caches its SMC connection and key discovery process-wide, so it must be reached only through this pipeline.

### Cadence is tiered by API cost

`SystemMetricsCollector.collect()` reads CPU, memory, and network every tick. It caches disk, thermal/fan, and GPU behind staggered monotonic deadlines of five, six, and seven seconds so their expensive work does not land in one burst. Two collectors gate themselves internally: `BatteryCollector` at 30 seconds and `ProcessCollector`'s process count at 60 seconds. `GPUCollector` retains discovered IORegistry services and backs off discovery for 60 seconds when telemetry is unsupported. Adding a metric means choosing a tier — do not put an expensive read on the per-tick path.

### State ownership

`AppModel` is `@MainActor` and is the sole owner of the current sample, bounded history, and settings. History is stored in the dependency-free `RingBuffer`, which provides constant-time append and front expiry. Convert it to a contiguous array only for explicit persistence or interoperability boundaries.

`AppModel` broadcasts `.searoomSampleUpdated` and `.searoomSettingsUpdated` with `object: model`. `AppDelegate` is the sample observer: it always updates the status item, but refreshes the dashboard only while `popover.isShown` is true. `DashboardView` must not observe or poll the model independently. The popover, dashboard controller, and Settings window are created lazily and released after closing; `viewWillAppear()` forces one fresh dashboard/trend presentation when the popover opens.

Keep collectors free of AppKit and views free of system calls.

### Persistence and the migration contract

- Settings: JSON in `UserDefaults` under `Searoom.Settings.v1`.
- History: binary plist at `~/Library/Application Support/Searoom/history.plist`, written atomically on the `app.searoom.history` queue at most once per 60 seconds, wrapped in `Archive(version: 1)`. Persistence receives a deliberate contiguous snapshot of the ring rather than retaining its live storage. Any other version or unreadable data fails closed to an empty history rather than blocking launch.

Both `AppSettings` and `SystemSample` hand-write `init(from:)` and `CodingKeys` rather than relying on the synthesized decoder. `AppSettings` defaults every field. `SystemSample` uses plain `decode` for fields that version-1 archives already contain and `decodeIfPresent` with a default only for fields added since — `swapInPerSecond`, `swapOutPerSecond`, `isLowPowerModeEnabled`. Follow that pattern: a plain `decode` for a key absent from existing archives rejects the entire history. Adding a field requires all five of stored property, initializer default, coding key, decode fallback, and encoder entry.

`AppSettings.customMenuBarMetrics` decodes as `[String]` and then `compactMap`s into `MenuBarMetric`, so metric names written by a future build are dropped instead of throwing. `MenuBarMetric.normalized(_:)` preserves the first three unique metrics and falls back to `MenuBarMetric.defaults` when empty; call it on any path that accepts user-chosen metrics. Sampling intervals and history durations are also normalized against their supported whitelists before they can affect timers or memory bounds. `hasCompletedLaunchAtLoginPrompt` defaults to false for a fresh `AppSettings()` but decodes missing legacy values as true, preventing upgrades from being prompted as new installs.

### Menu-bar rendering

The status item does not compute a width from a worst-case string. Stability comes from `MetricFormat.fixedField` (right-pads) and `fixedLabel` (left-pads), which pad each value to a fixed column count that, in monospaced Departure Mono, keeps the rendered string a constant width as values change. `.minimal` is the only preset that shows the Searoom mark (`imagePosition = .imageOnly`, `squareLength`). Text presets use `imageLeading` with a fixed-size, non-template semantic pressure dot and `variableLength`; they never show the Searoom mark. `updateStatusItem()` rewrites the title only when its components change and regenerates imagery only when its pressure, preset, or appearance presentation changes.

### Unavailable is never zero

Absent telemetry is `nil` (`temperatureCelsius`, `gpuUsage`, `batteryPercent`) or `PressureLevel.unavailable`. Because unavailable has the lowest raw pressure value, `SystemSample.overallPressureLevel` takes the nested maximum without allocating a temporary array; four unavailable inputs still produce unavailable. `TemperatureSource` travels with the temperature so a battery-pack fallback is never presented as CPU/package temperature. Do not substitute a fabricated zero, and do not log on every failed best-effort read — unsupported sensors are an expected steady state.

Thresholds live in one place, `PressureLevel.from(utilization:)` (70/85/95). Changing them requires tests plus matching updates to `README.md` and UI help.

### Drawing

`DashboardView` custom-draws the dashboard without a view hierarchy per metric. Its only drawing subview is a graph-sized transparent hover overlay, which must move without invalidating or rebuilding the chart beneath it. `DashboardTrendRefreshPolicy` keeps graph projection/redraw work on a five-second cadence while live numeric sections remain sample-rate responsive; `DashboardTrendSampleLocator` snaps hover to a real retained timestamp. Both pure helpers live in `UI/DashboardRefreshPolicy.swift` and have direct XCTest and self-test coverage.

`DitherPattern` caches `NSColor` pattern images by compact color/density keys, `SearoomIcon` caches one template image per `PressureLevel`, and `SearoomStatusDot` caches the light/dark semantic dot used by text menu-bar modes. These assume determinism, so dither must never be randomized or animated. Minimal remains the only mode that displays the Searoom mark; the text-mode dot is a pressure marker, not a logo. Text-mode titles are assembled from `MenuBarComponent` values separated by a compact unspaced `·`; pressure components use semantic health colors, active I/O uses the cool color without implying distress, idle I/O is subdued, and non-health values stay neutral.

### Brand assets are generated

`Scripts/render-icon.swift` declares the mark's geometry once, in SVG's y-down space on a 1024 grid, and emits the PNG, the SVG, and every PNG-backed ICNS representation from it; the AppKit renderer flips into that space rather than restating coordinates. It stages all three outputs and publishes them only after the complete ICNS container is assembled, so a failure cannot leave the PNG and SVG updated against a stale ICNS — preserve that fail-closed behavior. Regenerate with the script instead of hand-editing anything in `Brand/`, and do not check retired logo artwork into `Brand/`.

## Environment notes

- `swift test` needs XCTest, which some Command Line Tools installations omit; it then fails with `unable to resolve module dependency: 'XCTest'`. When that happens, say the tests did not run, and fall back to `--self-test`, which is deliberately framework-independent. CI runs on `macos-15` with full Xcode.
- `dist/` and `.build/` are generated. Do not hand-edit or commit them.
- The canonical website is `https://searoom.app`, the repository is `https://github.com/emaitchess/searoom`, and the permanent bundle identifier is `app.searoom.Searoom`; keep public links and packaging metadata aligned with them.
- The website is a **separate repository**, served by a Cloudflare Worker with static assets (not Cloudflare Pages). This repository holds no website code. Release-bearing copy on the site (version number, macOS floor, requirements, sensor-availability claims) has to be updated there when it changes here.
