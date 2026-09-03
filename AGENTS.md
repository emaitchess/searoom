# Searoom contributor and agent guide

This file applies to the entire repository. It records the constraints that are easy to miss when changing a small native menu-bar app. Read `README.md` for product behavior, `DESIGN.md` for the visual system, and `CONTRIBUTING.md` for the public contribution policy before making broad changes.

The canonical project website is `https://searoom.app`, the repository is
`https://github.com/emaitchess/searoom`, and the permanent application bundle
identifier is `app.searoom.Searoom`.

## Product contract

Searoom is a local-only macOS 14+ menu-bar instrument for understanding remaining system capacity during sustained workloads such as local LLM inference. Its usefulness depends on being substantially cheaper than the work it observes.

Preserve these non-negotiable properties:

- Keep the runtime native, small, and dependency-free unless a new dependency has a compelling measured benefit.
- Do not add analytics, crash uploading, remote configuration, accounts, or any network activity Searoom starts by itself. The single exception is the update check behind the Check for Updates menu item: it runs only when the user chooses it, fetches one static version manifest, sends nothing describing the Mac, and downloads and installs nothing. It must never gain a schedule, a background trigger, a payload, or the ability to install an update.
- Do not add a privileged helper or require root, Accessibility, or Input Monitoring permission.
- Prefer public macOS APIs. Treat SMC and undocumented IORegistry values as read-only, best-effort sources.
- Represent an unavailable sensor as unavailable (`nil` or `.unavailable`), never as a fabricated zero.
- Keep all preferences and bounded history on the Mac.
- Keep Searoom's own CPU and memory visible in the product.
- Preserve useful behavior when temperature, fan, battery, or GPU telemetry is absent.

## Repository map

| Path | Responsibility |
| --- | --- |
| `Package.swift` | SwiftPM executable, C sensor target, resources, frameworks, and test target |
| `Sources/Searoom/App` | Process entry point, AppKit lifecycle, status item, app menu, global shortcut, CLI diagnostics |
| `Sources/Searoom/Metrics` | Stateful metric collectors and the single sampling engine |
| `Sources/Searoom/Models` | Codable settings and sampled telemetry contracts |
| `Sources/Searoom/Store` | Main-actor application state and bounded local persistence |
| `Sources/Searoom/UI` | Direct AppKit rendering, design primitives, Settings, and shortcut recorder |
| `Sources/Searoom/Utilities` | `MetricFormat`, the single home for user-visible numeric and column formatting |
| `Sources/CSearoomSensors` | Narrow C bridge for best-effort, read-only AppleSMC access |
| `Sources/Searoom/Resources` | Bundled runtime assets, including Departure Mono |
| `Tests/SearoomTests` | XCTest coverage for pure behavior and hardware-safe collector bounds |
| `Support/Info.plist` | Bundle identity, version, minimum OS, and `LSUIElement` behavior |
| `.env.release.example` | Template for the untracked `.env.release` read by `Scripts/release.sh`; names the signing identity and keychain profile, never a secret |
| `Scripts` | Foreground development launch, app packaging, notarization, release automation, and brand asset generation |
| `.github/workflows` | `ci.yml` builds and tests every push; `release.yml` audits a published release against the bytes actually attached to it |
| `Sources/Searoom/Models/DashboardSection.swift` | The nine movable dashboard sections, their geometry, and order normalization |
| `Sources/Searoom/UI/DashboardLayout.swift` | Pure layout engine resolving a section order into rectangles |
| `commitlint.config.js` | Conventional Commits rules, read by `.githooks/commit-msg` |
| `.githooks` | Tracked git hooks; enabled per clone with `git config core.hooksPath .githooks` |
| `Brand` | Current generated app icon and source vector artwork; do not add retired-logo archives |
| `DESIGN.md` | Machine-readable tokens and human-readable design rules |
| `CLAUDE.md` | Commands and cross-file architecture orientation; defers to this file for the contract |

`dist/` and `.build/` are generated. Do not hand-edit or commit them.

The website for `searoom.app` is a separate repository served by a Cloudflare
Worker with static assets, not Cloudflare Pages; no website code belongs here.
When a release changes the version, the macOS floor, requirements, or any
sensor-availability claim, the corresponding copy on the site has to be updated
in that repository.

## Runtime architecture

The intended data flow is deliberately short:

```text
MetricsEngine utility queue
  -> SystemMetricsCollector and stateful subcollectors
  -> immutable SystemSample
  -> main queue / @MainActor AppModel
  -> bounded circular history + notifications
  -> status item and visible DashboardView
```

- `MetricsEngine` owns one serial utility-QoS `DispatchSourceTimer`. Do not create a timer per metric.
- The sample interval is clamped to at least one second and uses timer leeway to avoid unnecessary wakeups.
- `SystemMetricsCollector` and its subcollectors are stateful. Rate metrics require previous counters and a monotonic timestamp, so they must stay on the engine's serial queue.
- Disk, thermal/fan, and GPU reads are cached on staggered five-, six-, and seven-second monotonic deadlines. Battery data and disk capacity are cached for 30 seconds; process count for 60 seconds. GPU service discovery is retained across reads and negatively cached for 60 seconds when unavailable.
- `AppModel` is `@MainActor`. It is the sole owner of current UI state, settings, and in-memory history.
- Trend history uses the dependency-free `RingBuffer`, with constant-time front expiry and append. Convert it to a contiguous array only at explicit persistence or interoperability boundaries.
- AppKit work remains on the main actor. Do not draw, mutate views, or touch `NSStatusItem` from the metrics queue.
- Existing `@unchecked Sendable` annotations document queue-confined objects; they are not permission to access those objects concurrently.
- The C sensor bridge contains process-wide cached connection and key-discovery state. Call it only through the serial collector pipeline.

When restarting sampling after a settings change, cancel the old timer before replacing it. Avoid `Task.detached`, parallel collectors, or extra polling loops unless measurements demonstrate a need and state ownership remains explicit.

## Performance rules

Performance is a product feature, not a cleanup task.

- Never launch `powermetrics`, `ioreg`, `vm_stat`, `top`, or another subprocess from the sample loop.
- Do not continuously animate graphs, dither, status icons, or pressure state.
- Chart hover uses the existing history only: snap to a real sample, show its timestamp, and update only the graph-sized transparent overlay when the selected sample changes. Do not invalidate the chart beneath it, add a hover timer, or display interpolated values.
- `DashboardView` must not observe sample notifications directly. `AppDelegate` gates refreshes on `popover.isShown`; the closed popover must not redraw for background samples.
- Refresh once in `viewWillAppear()` so skipped hidden updates appear immediately on open, and release the dashboard controller and popover backing resources after close.
- Use `needsToDraw(_:)`, invalidate only visible live sections whose rendered presentation changed, and keep trend projection/redraw work on the existing five-second cadence. Live numeric labels must remain responsive at the selected sample interval.
- Cache generated dither colors and menu-bar images. Dither must be deterministic between frames.
- Update menu-bar text or imagery only when the rendered value or pressure level changes.
- Keep persistence off the main actor, atomic, bounded, and no more frequent than the existing once-per-minute cadence.
- Use `ContinuousClock` for counter rates; wall-clock changes must not create throughput spikes.
- Release Mach allocations and IOKit/Core Foundation objects with the matching ownership operation.

For changes to collection, drawing, persistence, or menu-bar formatting, measure the packaged app with the popover both open and closed. Record the Mac model, macOS version, sample interval, observation window, CPU result, resident memory, and preferably physical footprint. Closed-popover CPU should settle near zero; investigate sustained usage around or above one percent or a material memory regression.

## Metric semantics

All fractional utilization and pressure values use the closed range `0...1`. Clamp data at collector boundaries.

- CPU usage is the delta of aggregate Mach CPU ticks. The first read is intentionally zero because no prior counter exists.
- CPU pressure is derived, not macOS PSI: `max(CPU usage, 1-minute load / active logical CPUs)`.
- Memory used is active + wired + compressed memory, capped at physical memory.
- Memory available includes reclaimable pages; it is not merely the VM free-page count.
- Memory pressure combines the macOS pressure level, when available, with the working-set ratio used by trends.
- GPU pressure is derived, not an Apple pressure API: the greater of GPU utilization and the ratio of in-use GPU system memory to the Metal-recommended working-set size. Utilization and in-use memory come from read-only IORegistry values; the working-set budget comes from the public Metal API. When a supported utilization key is absent, utilization, pressure, working-set memory, and working-set pressure all remain unavailable.
- Thermal pressure comes from `ProcessInfo.thermalState`; a battery-temperature fallback is not CPU/package temperature and must retain its source label.
- Temperature selection prefers a validated CPU/package SMC reading. If that is unavailable, `BatteryCollector` may use the AppleSmartBattery pack sensor; dashboard detail and compact/menu-bar output must identify it as `BAT`.
- `kIOPSTemperatureKey` values may already be Celsius, while AppleSmartBattery registry values can use hundredths of a degree Celsius (`2759` means `27.59°C`). Keep this normalization in `BatteryCollector.normalizeTemperature`; do not restore the former deci-Kelvin conversion.
- Reject non-finite and implausible temperature representations instead of showing them. Any temperature conversion change needs regression cases for direct Celsius, hundredths Celsius, and invalid values in both the framework-independent self-test and XCTest source.
- Network I/O aggregates active, non-loopback interfaces. Counter rollback yields zero for that interval.
- Disk I/O is a delta of IORegistry byte counters.
- Swap I/O is a delta of Mach swap-in and swap-out page counters converted to bytes per second. The first read is a zero baseline and counter rollback yields zero for that interval.
- Compressed memory is the compressor-page share of the working set and is already included in memory used. Compression and decompression rates are deltas of Mach page counters converted to bytes per second with the same first-read zero baseline and rollback handling as swap rates.
- Disk capacity reads the root volume through `statfs`; the root shares its APFS container with the Data volume. Available space excludes purgeable files and is presented as a neutral capacity reading, never a derived pressure level.
- Low Power Mode is read from `ProcessInfo.isLowPowerModeEnabled`; it is a system state, not a Searoom-derived pressure signal.
- Sustained pressure is derived from retained history: the time since the oldest sample still holding the current overall level. It is window-bounded, hidden below one minute, and suffixed with `+` when the run spans every retained sample.
- Searoom process CPU is elapsed process CPU time divided by wall time. It can exceed `1.0` when multiple cores are used, so do not apply the system utilization clamp to it without changing its meaning.

Pressure thresholds are centralized in `PressureLevel.from(utilization:)`: 70% elevated, 85% constrained, and 95% critical. Any formula or threshold change requires tests and matching documentation in `README.md` and relevant UI help.

## Adding or changing a metric

Follow the data path rather than reaching into collectors from a view:

1. Add the typed field to `SystemSample` and its placeholder.
2. Add or extend a focused collector. Keep previous counters inside that collector.
3. Wire it through `SystemMetricsCollector`, choosing a cadence proportional to API cost.
4. Decide how old persisted samples decode before changing the Codable schema.
5. Add formatting in `MetricFormat` if the unit is reusable.
6. Add dashboard, trend, menu-bar, and accessibility presentation only where each is useful.
7. Update `--dump-sample`, self-test or XCTest expectations, README semantics, and sensor limitations as applicable.
8. Measure idle cost and verify unsupported hardware returns unavailable without log spam or crashes.

Keep collectors free of AppKit and UI policy. Keep views free of system calls and polling.

When diagnosing IORegistry or power-source values, extract only the keys needed for the investigation. Full AppleSmartBattery and IORegistry dumps can contain battery or hardware serial numbers and other stable identifiers; do not paste them into logs, issues, fixtures, or responses.

## Persistence and compatibility

Settings are JSON-encoded into `UserDefaults` under `Searoom.Settings.v1`. `AppSettings` has a custom decoder so older settings receive defaults. When adding a setting:

- Add the property, initializer default, coding key, decode fallback, and encoder entry.
- Add or update the Settings UI and migration test.
- Validate malformed or out-of-range persisted values before they influence timers or allocation bounds.

Trend history is a versioned binary property list at:

```text
~/Library/Application Support/Searoom/history.plist
```

Writes are atomic on the `app.searoom.history` utility queue. History is bounded in `RingBuffer` by the selected window and a hard sample-count cap; persistence takes one deliberate contiguous snapshot rather than retaining the live ring storage. `SystemSample` declares its own `init(from:)` and `CodingKeys` rather than relying on the synthesized decoder, so a new field must be decoded with `decodeIfPresent` and a default the way `swapInPerSecond`, `swapOutPerSecond`, and `isLowPowerModeEnabled` are. A plain `decode` for a key that version-1 archives do not contain rejects the entire history; add a decode default or migrate/bump the archive version deliberately. Corrupt or unsupported history should fail closed to an empty history, not prevent launch.

Do not persist secrets, stable hardware identifiers, process names, command lines, model prompts, or user content.

The Settings reset action clears only in-memory and persisted trend samples. It must remain confirmed and must not silently reset preferences, the global shortcut, or launch-at-login state.

## AppKit and interaction rules

- Searoom is an `LSUIElement` accessory app. Do not add a Dock icon as a side effect.
- The application menu is created programmatically even though it is not normally visible; it supplies standard `⌘,` Settings and `⌘Q` Quit routing while the popover or Settings is focused. Preserve those commands.
- The dashboard footer contains exactly three equal-width actions: Settings with `⌘,`, Activity Monitor, and Quit with `⌘Q`. Resolve Activity Monitor through bundle identifier `com.apple.ActivityMonitor`, not a hard-coded path; launch it only after explicit user activation.
- Searoom's own CPU, RAM, and sample interval form the final telemetry section: one compact line immediately above the footer. Keep it visible and do not expand it back into a multi-row card.
- The status item supports left-click toggle and right-click context menu. Preserve both paths.
- Text menu-bar presets use `NSStatusItem.variableLength`; do not restore a fixed width for the whole status item. Pad only volatile values to their compact character columns with `MetricFormat.fixedField`, and variable-width labels such as the temperature source with `MetricFormat.fixedLabel`, so that in monospaced Departure Mono ordinary sampling updates cannot move neighboring items. Labels retain natural width, values that exceed a field must expand rather than truncate, and adjacent metric groups use one subdued `·` with no surrounding spaces. Text presets are leading-aligned and begin with the cached, fixed-size, non-template `SearoomStatusDot` colored from overall pressure. The dot is not the Searoom mark and must retain its stable leading width, light/dark variants, and accessible state description. Each metric component carries its own `MenuBarTone`: pressure colors for health signals, cool/subdued activity colors for network and disk I/O, and neutral ink only when magnitude has no health meaning. Do not turn high throughput or long uptime into a warning color. Keep Minimal centered and square; it is the only menu-bar mode that displays the Searoom mark.
- The status item has two layouts, persisted in `menuBarLayout`. `stacked` is the default and draws the entire item, dot included, as one `NSImage` from `MenuBarRenderer`, because two independently aligned lines per column are beyond an attributed title. `inline` keeps the original attributed-string path. Both must keep working; do not delete `attributedMenuBarTitle`. An unknown stored layout falls back to `stacked`.
- Stacked columns are sized by `MenuBarRenderer.columnWidth`, the greater of the trimmed label and the **padded** value. Measuring the padded value is what preserves the no-shift guarantee, since the padding already reserves the widest reading the field can hold. `testStackedColumnWidthIsUnmovedByTheReading` is the guard; keep it. Both lines lead from the same edge, because centring would move the reading whenever a digit appeared.
- A metric may be a pair rather than a label and a number: `MenuBarComponent.Pair` carries a second reading, used by `networkUpDown` for the two directions. Stacked draws both lines in the reading treatment, since each arrow labels its own number and neither line is a label; inline puts them on one line. A pair still costs one of the five selections.
- Stacked lines are packed by cap height and baseline, not by line box. Departure Mono's natural line height is 13pt at 9.5pt, so two stacked line boxes want 26pt inside a 22pt menu bar, and even a small label over a value wants 23pt. `testStackedLinesFitTheMenuBarHeight` is the guard; do not go back to laying out with `size().height`.
- `MenuBarComponent` carries `label` and `value` separately, with the label holding its own trailing space so `text` is byte-identical to the single string it replaced. That keeps the inline rendering and the accessibility description unchanged.
- The menu bar is an ordered, unique selection of at most `MenuBarMetric.maximumCount` (five) values, persisted in `menuBarMetrics`. There are no presets. Its default is CPU usage, RAM used, and temperature. `MenuBarMetric.normalized` drops duplicates and anything past the cap, and deliberately preserves an empty result, because empty means the mark-only status item; only a *missing* stored key falls back to the defaults, which the decoder handles. Changing the selection may change the natural status-item width, but sampling updates reuse the same fixed value columns.
- `MenuBarMetric.migrated(preset:custom:)` translates pre-0.3 archives, which described the menu bar by preset name. There is one test per retired preset; keep them. `llm` is knowingly lossy because it drew `RAM used/total`, which no single metric expresses. Do not delete the legacy `menuBarPreset` and `customMenuBarMetrics` coding keys: they are read during migration and never written again.
- One selected metric can render as more than one group, as `power` yields the source and Low Power Mode, so the cap counts selections rather than rendered groups.
- Dashboard geometry is computed, never typed. `DashboardLayout.make(order:width:)` is the only source of section rectangles, the self strip, the footer, and the document height; `draw`, both invalidation paths, and the unit regions all read it. Do not reintroduce a literal `y` for a card. The regression test pins the default order to the geometry that shipped before the layout was computed, so a failure there means the dashboard moved rather than merely being derived.
- The nine movable sections reorder by dragging a card, or through the Settings reorder list, which is the keyboard and VoiceOver path and must keep working. Order is persisted in `dashboardSectionOrder` and normalized on decode, so an unknown or missing section is repaired rather than rejected. The header, accountability strip, and footer never move. Reordering can change the document height, because a full-width section after an odd number of half-width cards leaves half a row empty; call `syncContentHeight()` rather than assuming a fixed 1120.
- A press on a card is ambiguous and must stay that way until release. Several unit hit rects are the entire card (memory, thermal, GPU memory, disk, network), so cycling units on `mouseDown` makes those cards impossible to drag. `mouseDown` records both the pending unit region and the drag candidate; a drag past 4pt of travel cancels the pending click, and a release without one rotates the unit. Do not restore a priority order between the two at press time. Releasing outside the dashboard abandons the move.
- The dashboard has no visible scrollers. `SearoomClipView` and `SearoomScrollView` retain vertical trackpad/mouse-wheel behavior while locking the horizontal origin, disabling automatic content insets, and discarding horizontal-only wheel events. Preserve both missing scrollers, `.none` elasticity on both axes, and those locks.
- The global shortcut uses Carbon `RegisterEventHotKey`. Require Command, Option, or Control for printable keys.
- Keep both clearing paths working: the visible Settings Clear control and Delete while the recorder is active. The recorder and Clear button use the same control size, equal width, and matched height. Clearing must unregister the hot key and persist `nil`.
- Shortcut registration failure must restore the previously registered shortcut and leave settings unchanged.
- Do not replace the shortcut mechanism with an event tap or global monitor that requests privacy permissions.
- Launch at login uses `SMAppService.mainApp` and must be tested from a packaged application bundle.
- A fresh packaged install asks once whether Searoom should open at login. Never show this prompt from `Scripts/run-dev.sh`; remember either response locally, skip it when the service is already registered, and keep the Settings checkbox as the reversible control. Existing settings archives decode as already prompted so upgrades are not treated as fresh installs.
- Keep Settings and dashboard UI lazy-created; the normal menu-bar path should not allocate either window hierarchy. Release each controller after its window or popover closes.
- The Settings footer pairs the version and open-source license line on the left with quiet `GITHUB ↗` and `PART OF EMAITCHESS ↗` links on the right, in that order. The left line reads `SEAROOM <version> · OPEN SOURCE · MIT`, taking the version from the bundle so it cannot drift from the shipped build, and carries an accessibility label because the `·` separators read poorly aloud. Open the canonical repository and `https://emaitchess.com/` through `NSWorkspace` only after explicit activation; Searoom itself must not fetch either site. Preserve the affiliation link's stable UTM attribution: source `searoom`, medium `desktop_app`, campaign `product_attribution`, and content `settings_footer`.

Controls must be keyboard-operable and expose meaningful VoiceOver labels and values. Pair every pressure color with a state word, numeric value, marker, or other non-color signal. Respect system light/dark appearance and Reduce Motion. Test Increase Contrast when changing semantic colors or dither density.

## Visual system

`DESIGN.md` is the source of truth for branding, tokens, layout, components, and do/don't guidance. `SearoomStyle.swift`, `DashboardView.swift`, Settings, and brand assets should implement it rather than inventing local variants.

- Use Departure Mono for metric values and micro-labels; use the system font for controls and prose.
- Keep the bundled font registration fallback and the font availability self-test.
- Preserve the font's SIL Open Font License entry in `THIRD_PARTY_NOTICES.md` and packaged resources.
- Use the cached ordered 4×4 Bayer implementation in `DitherPattern`; do not add random noise, gradients, or animated texture.
- Prefer warm paper, near-black ink, hairline borders, restrained semantic color, and flat geometry.
- Do not introduce a neon gamer-monitor, glass dashboard, or generic web-dashboard aesthetic.

When changing design tokens or component rules, update both code and `DESIGN.md`, then run:

```sh
npx --yes @google/design.md lint DESIGN.md
```

That development command may access npm; it is not a runtime dependency.

## Swift and C conventions

- Use Swift 6 concurrency rules, four-space indentation, and small focused types.
- Prefer `guard` for system-call failure and return a safe unavailable reading.
- Avoid force unwraps in collectors, persistence, and sensor parsing.
- Handle `@unknown default` for system enums that Apple may extend.
- Keep units visible in names (`Bytes`, `PerSecond`, `Celsius`, `rpm`) and timestamps explicit.
- Centralize user-visible numeric formatting in `MetricFormat`.
- Avoid logging on every failed best-effort read; unsupported sensors are an expected steady state.
- In C, initialize ABI structs, validate data sizes and types, bound arrays, and release every acquired IOKit object.
- Keep the C API narrow and Swift-friendly. New undocumented SMC keys require a comment, plausible bounds, and verification on identified hardware.

Do not silently reinterpret a derived metric as an official Apple signal. Label it in code comments, the UI, and documentation.

## Build and diagnostics

Run commands from the repository root.

```sh
Scripts/run-dev.sh
swift build --disable-sandbox
swift test --disable-sandbox
.build/debug/Searoom --self-test
.build/debug/Searoom --dump-sample
```

The first sample for delta-based metrics is a baseline; use the second sample when diagnosing CPU, network, disk, or self CPU rates. `--self-test` is intentionally framework-independent and should work on machines with only Command Line Tools.

Some Command Line Tools installations do not include XCTest. If `swift test` fails because XCTest itself is missing, report that limitation accurately and still run the build and self-test. Do not claim unit tests passed when they did not run. CI uses full Xcode on `macos-15`, and the release gate refuses to publish without a green CI run, so a local skip delays a release rather than shipping past one. When a full Xcode is installed but not selected, point the toolchain at it for one command instead of switching the system default:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --disable-sandbox
```

In a restricted environment where Swift cannot write its default module cache, direct only the caches to a writable temporary location:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/searoom-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/searoom-swiftpm-cache \
swift build --disable-sandbox
```

Useful focused checks include:

```sh
clang -Wall -Wextra -Werror -fsyntax-only \
  -I Sources/CSearoomSensors/include Sources/CSearoomSensors/SearoomSensors.c
bash -n Scripts/build-app.sh Scripts/notarize.sh Scripts/release.sh Scripts/run-dev.sh
plutil -lint Support/Info.plist
```

## Verification by change type

| Change | Minimum verification |
| --- | --- |
| Pure model, threshold, or formatter | Debug build, relevant XCTest, self-test |
| Collector or C sensor | Above plus two-sample diagnostic, bounds/unavailable behavior, C warnings |
| Temperature source or conversion | Above plus source-labelled `--dump-sample`, direct/hundredths/invalid regression cases, and a plausibility check on identified hardware |
| Persistence or settings | Migration/round-trip test, corrupted-old-data behavior, self-test |
| Dashboard, dither, icon, status text, or scrolling | Build packaged app; inspect light/dark, VoiceOver labels, closed-popover idle cost; open repeatedly to check for first-frame lateral shift; verify horizontal gestures do nothing, vertical input still scrolls, and no scrollbar appears |
| Shortcut, menu, or lifecycle | Test status-item left/right click, recorded shortcut conflict, `⌘,`, and `⌘Q` from popover and Settings |
| Packaging or plist | Run packaging script, `plutil`, strict `codesign --verify`, and packaged self-test. For a release build also confirm `spctl --assess` reports `accepted` from a `Notarized Developer ID` source |
| Design system | Upstream `design.md` lint with zero errors and zero warnings |

Hardware sensor changes should be checked on the affected Mac model and macOS release. Do not turn one-machine success into a universal availability claim.

## Commit messages

Commits follow Conventional Commits: `type(optional scope): subject`, with the subject in lowercase, in the imperative mood, and without a trailing period. Allowed types are the `@commitlint/config-conventional` set: `build`, `chore`, `ci`, `docs`, `feat`, `fix`, `perf`, `refactor`, `revert`, `style`, `test`. Subjects stop at 72 characters and body lines wrap at 80; trailer lines are exempt so URLs need not wrap.

`.githooks/commit-msg` runs commitlint through `npx --yes` and needs `git config core.hooksPath .githooks` once per clone. It is a local drafting aid, not an enforcement boundary: it is absent from a fresh clone until configured, skipped when `npx` is missing, and bypassable with `--no-verify`. History before the convention was adopted does not follow it and was deliberately not rewritten.

## Packaging and release safety

Create a local ad-hoc signed bundle with:

```sh
Scripts/build-app.sh
dist/Searoom.app/Contents/MacOS/Searoom --self-test
codesign --verify --deep --strict --verbose=2 dist/Searoom.app
plutil -lint dist/Searoom.app/Contents/Info.plist
```

`Scripts/build-app.sh` deletes only the exact generated `dist/Searoom.app` path before rebuilding it. Keep that safety check if the script changes.

`Scripts/render-icon.swift` stages the PNG, SVG, and PNG-backed ICNS container before publishing any of them. Preserve that fail-closed behavior so a rendering or container-assembly error cannot leave mismatched brand formats.

`Scripts/release.sh` runs the whole release: preflight, tests, signed build, signature and hardened-runtime verification, notarization, stapling, and a Gatekeeper assessment. It publishes two artifacts: `Searoom.dmg`, which is signed and notarized in its own right so it validates offline, and `Searoom.zip`. The app inside the image is already stapled, so it stays valid once dragged out. Zip archives are not byte-reproducible, so never re-upload a zip over one already published; its checksum will differ even from identical sources. It stops before tagging unless `--publish` is passed, because tagging and creating a GitHub release are public actions. It reads `CODE_SIGN_IDENTITY` and `NOTARY_KEYCHAIN_PROFILE` from an untracked `.env.release`; see `.env.release.example`. That file names the keychain profile and must never hold the password itself.

Developer ID signing uses `CODE_SIGN_IDENTITY`; notarization uses a preconfigured notarytool keychain profile via `Scripts/notarize.sh`. Signing, notarization, publishing, changing external login items, and creating releases are external side effects—perform them only when explicitly requested. Never place certificates, keychain profiles, Apple credentials, or notarization secrets in the repository.

`Scripts/release.sh --publish` will not tag or release from a commit GitHub Actions has not already passed. The preflight looks up the `ci.yml` run for the exact `HEAD` SHA, waits while it is queued or in progress, and stops if it concluded anything other than success. 0.2.0 was published about thirty seconds before CI went red on that same commit, and the local `swift test` had not caught it because XCTest was missing from the selected toolchain, so the gate exists to make that ordering impossible. There is no override: fix CI, or do not release. `CI_WORKFLOW`, `CI_GATE_TIMEOUT`, and `CI_POLL_INTERVAL` can be set in `.env.release` if the workflow filename or the timings need to change.

`.github/workflows/release.yml` runs when a release is published and audits what actually shipped. The tag, `CFBundleShortVersionString`, and the changelog section have to agree; the tagged tree has to build, test, and pass the self-test; `Searoom.dmg` has to be stapled and assessed from a `Notarized Developer ID` source; the app inside `Searoom.zip` has to pass its own self-test; and the SHA-256 values printed in the release notes have to match the bytes attached to the release. It never builds or uploads an artifact. Developer ID signing needs a private key and the disk image's window layout is recorded by Finder, so release artifacts are built on a developer's Mac and CI checks them rather than producing them. Keep it that way; do not move signing credentials into Actions secrets.

`Scripts/release.sh` derives the tag from `CFBundleShortVersionString` and refuses to publish over an existing tag or release, so the version must be bumped before a new release. Update `CFBundleShortVersionString` and `CFBundleVersion` deliberately for releases. Keep the MIT license, third-party notices, bundled font license, privacy statements, and open-source documentation synchronized with shipped artifacts.
