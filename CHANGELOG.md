# Changelog

All notable changes to Searoom are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- The `searoom` command is linked on first launch, so it is there the first
  time someone opens a terminal rather than waiting to be found in Settings. It
  creates one symlink at `~/.local/bin/searoom` and, when that directory is not
  already reachable, one clearly marked block in `~/.zprofile` that puts it on
  PATH. No prompt and no privileges. It does nothing when the command already
  works, when something else occupies the path, when the app is running from a
  disk image or App Translocation, or when the command has been turned off.

  The profile edit is new behaviour for an installer that previously promised
  never to touch a shell file, and it is there because nothing else reaches a
  stock PATH without privileges: macOS ships
  `/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`, and both `/usr/local/bin` and
  `/etc/paths.d` are root-owned. The block is written only when no login file
  already mentions `~/.local/bin` — `.zshrc`, `.zshenv`, `.bashrc` and
  `.profile` are read even though Searoom never writes to them, because PATH is
  set in `.zshrc` far more often than in `.zprofile` — and turning the command
  off removes the block again, leaving every surrounding line untouched.
- Settings replaces the Install and Remove buttons with one `Enable the searoom
  command` toggle. Its state is read from the filesystem rather than from a
  stored flag, so it always shows what a terminal would find. A command
  provided by Homebrew is recognised and reported: the cask's link is not
  Searoom's to remove, so the toggle shows it as on and names where it came
  from instead of offering an off switch that would not work. Turning the
  command off is remembered, so the next launch does not put it back.
- Settings are grouped by what they change, under `MENU BAR`, `DASHBOARD`,
  `SAMPLING`, `SEAROOM CLI`, `GENERAL` and `MAINTENANCE`, rather than arriving
  in the order the controls happened to be built. Launch at login, trackpad
  feedback, Check for Updates and Reset Trend History move out of the strip
  below the grid and into the sections they belong to, and the three toggles
  are now switches on the trailing edge so they line up instead of drifting
  with the width of their labels.

- An `Agent skills` control installs the bundled Agent Skill into the folders
  coding agents read: Claude Code, Codex, Cursor and OpenCode, individually or
  all at once. Each agent is a checkable item, so the same menu removes what it
  installed, and an item shows a dash when the file on disk is not this
  version. One `SKILL.md` per agent is written and nothing else is touched. The
  row only appears while the command is enabled, because a skill that tells a
  model to run `searoom` is useless without it.

### Fixed
- Settings is now the popover's size, 430 by 720, and scrolls. It had grown to
  928 points tall, which no longer fits a laptop screen, and a fixed window
  also means no control can resize it by appearing or disappearing. The page's
  own `SEAROOM / SETTINGS` banner is gone, since the title bar already names
  the window, and the reorder controls are arrow glyphs, which is what fits
  beside a label column at that width; each keeps its accessibility label and
  gains a tooltip.
- The app appears in the Command-Tab switcher and the Dock while Settings is
  open, and goes back to being a menu bar app when it closes.
- `Clear` beside the shortcut recorder is hidden when no shortcut is set,
  rather than shown permanently disabled.

- Command-W closes the Settings window and leaves the app running in the menu
  bar. The shortcut is handled by the window itself, because an accessory app
  installs no menu bar and `NSApp.mainMenu` key equivalents are never matched:
  the Quit item's Command-Q has never fired either.
- The Searoom CLI status line no longer appears and disappears. It reports
  states only some machines reach, a Homebrew-provided command or a conflicting
  file, and letting it come and go resized the window under the switch that had
  just been clicked. It now holds one line whether or not it has something to
  say.
- The menu-bar preview is gone from Settings. The stacked and inline layouts
  have different natural sizes, so switching between them resized the window
  and the whole page appeared to jump. The menu bar itself now updates the
  moment the selection changes, which is a truer preview than a mockup of it.
- Changing a menu-bar metric or the layout refreshes the status item
  immediately rather than at the next sample, which at a ten-second interval
  was long enough to read as the setting not having worked.


- `searoom history --jsonl` returned the single envelope document instead of
  one sample per line. The parser accepted and validated the flag and then
  dropped it: `ParsedCommand` carried only the shared `--json` and `--pretty`,
  and the runner passed `--json` through in its place, which `history` does not
  accept, so the value was always false. `--jsonl` now travels on the `history`
  command itself, where a flag belonging to one command belongs.

  The streaming lines are the same `sample` document `watch` emits, so one
  reader handles both and every line validates against the published schema; a
  bare sample did not, because the schema's top level requires the envelope.
  Each line is labelled `source.kind: persisted`, `producer: searoom-app`,
  rather than claiming to be live telemetry the CLI just collected.
- `searoom watch` was killed by SIGINT and SIGTERM instead of finishing the
  line in flight and returning 128 + signal. `CLIRunner.Environment` defaulted
  its signal monitor to `NoSignals()`, the test double, so the real
  `DispatchSignalMonitor` was never constructed outside the test suite and the
  two signals kept their default disposition. Every signal test injects its own
  monitor, which is why 133 passing tests said nothing about it. The default is
  now the dispatch monitor, one test asserts the production default directly,
  and `Scripts/check-watch-signal.py` runs in CI and in the release audit: it
  reads the raw wait status, because a shell reports 130 both for a process
  killed by SIGINT and for one that exits 130, and so cannot tell the
  regression from correct behaviour.

## [0.5.1] - 2026-09-09

### Fixed

- `searoom version` and the `searoomVersion` field in every telemetry document
  reported `0.0.0 (build 0)` whenever the command was reached through a symlink
  outside the app bundle, which is how both supported installations expose it:
  Homebrew's `bin` link and the `~/.local/bin/searoom` that `install-cli`
  creates. `Bundle.main` is derived from the launch path without resolving
  symlinks, so it pointed at the link's own directory, which has no
  `Info.plist`. Bundled resources were unaffected, because SwiftPM's accessor
  also searches the executable's directory, which is why only the version was
  wrong and only on the common path. The version now falls back to the `.app`
  enclosing the resolved executable, and CI asserts the version reported
  through a symlink against `Info.plist`.

## [0.5.0] - 2026-09-09

### Added

- A first-class `searoom` command line interface, built into the app: the same
  signed executable gains a lowercase `searoom` mode that prints help with no
  arguments and exposes `sample`, `watch`, `status`, `history`, `capabilities`,
  `metrics`, `schema`, `agent-guide`, `version`, `self-test`, `install-cli`,
  and `uninstall-cli` without launching any UI. Every telemetry and
  documentation command is read-only and offline; live sampling never writes
  app history. Homebrew installs link the command automatically; DMG installs
  can add it rootlessly with `searoom install-cli` or the new Settings control.
- Versioned telemetry output (schema v1) with UTC RFC 3339 timestamps,
  stable base units, lowercase pressure levels, and explicit `null` for
  unavailable readings, plus bundled JSON Schema, metric definitions, and an
  offline Agent Skill so automation can discover the whole contract without
  the network.
- Per-source availability metadata (`available`, `warmingUp`, `unavailable`,
  `legacyUnknown`) that distinguishes a valid idle zero, a missing rate
  baseline, and a failed read. Old archives decode as `legacyUnknown` and
  remain readable.
- `searoom sample`, `watch`, `status`, and `capabilities` prime their rate
  baselines before emitting, including one forced second disk read, so the
  first emitted sample carries meaningful disk I/O instead of a permanent zero.

### Fixed

- A failed disk-IO registry read no longer installs a zero counter baseline,
  which previously fabricated a false throughput spike on the next successful
  read. The same protection now covers the sampling process's own CPU baseline.

## [0.4.0] - 2026-09-08

### Added

- Trackpad haptic feedback when the sample rate changes, at each trend-window
  slider stop, while scrubbing a trend chart as the cursor crosses into the
  next retained sample, and each time a dragged dashboard card would land in a
  new slot. The slider and card-drag taps fire on the change rather than per
  event, so a slow gesture gives one tap per detent crossed rather than fifty.
  Chart scrubbing is floored at 25 taps a second: the snapped sample changes
  about once per pixel column, so an unthrottled sweep would fire at the
  mouse-moved rate and read as a buzz rather than a series of detents.
- A Trackpad feedback checkbox in Settings turns all of it off. On by default,
  and settings written before the toggle existed keep the feedback they already
  had. Every haptic in the app routes through one gate, so a new detent cannot
  ship ignoring the preference. `NSHapticFeedbackManager` is part of AppKit, so
  this adds no dependency and no measurable size, and it is a no-op on hardware
  without a Force Touch trackpad.

### Changed

- The trend window now runs from 15 minutes to 24 hours. It offers 15 and 30
  minutes then every hour to 24, and Settings presents it as a slider that
  snaps to those stops rather than a four-item menu. The four windows that
  existed before (15 minutes, 30 minutes, 1 hour, 3 hours) are all still
  offered, so a stored preference carries over unchanged.
- Windows longer than three hours keep their full span and retain every nth
  sample rather than every one. A 24 hour window therefore costs no more
  memory, disk, or scan time than the three hour window already did. Nothing
  changes on screen, because the dashboard already downsamples every series to
  its pixel width before drawing, and live readings are never thinned. Storing
  every sample for a 24 hour window would have meant about 33 MB rewritten to
  disk every minute to draw fewer than 400 points.
- Sample rate offers every whole second from 1 to 10, on a slider matching the
  trend window rather than a four-item pop-up. All four rates offered before
  are still stops, so a stored setting carries over. The value is committed
  when the drag ends, not on each tick: changing it restarts the sampling
  timer, so writing per tick would tear the timer down and rebuild it up to
  nine times for one gesture.
- The value beside each slider is pinned to the width of the widest string it
  can show. The trend-window strings range from 40.8pt for "1 hour" to 68.0pt
  for "15 minutes", so without this the label resized as the value changed and
  dragged the slider sideways under the thumb.
- Removed the blank line reserved under the global shortcut row. The error
  label was always present and empty, and an empty label still has intrinsic
  height, so it held roughly 16pt whether or not there was an error. It is now
  hidden when there is no message, which drops it from the layout entirely.

### Fixed

- The card order list's buttons are titled `Move Card Up` and `Move Card Down`.
  Two buttons read `Move Up` and two read `Move Down` in the same window, one
  pair per list, so the two lists were distinguishable only by which table
  happened to be selected.
- The sample rate control carries an accessibility label. VoiceOver announced
  the selected value with no indication of what it set, because the SAMPLE RATE
  text beside it is a separate label with no programmatic association.
- The Settings footer is constrained to sit at least 16pt below the disclosure
  note. The note is the only variable-height element in a fixed 720pt window
  that cannot scroll, and nothing held it off the footer; they did not overlap,
  but the failure would have been silent.

## [0.3.0] - 2026-09-03

### Added

- A `Network Upload/Download` metric showing both directions in one menu-bar
  slot, each on its own line with a compact arrow when the layout is stacked.
- Dashboard cards can be rearranged. Drag a card to move it, or use the card
  order list in Settings, which is the keyboard and VoiceOver equivalent. The
  order is remembered. The Searoom accountability strip and the footer stay
  where they are.

### Changed

- The menu bar stacks each metric's label above its value by default, which is
  about 61% of the previous width for the same five metrics and makes each
  label unambiguously belong to the reading beneath it. `Inline` in Settings
  restores the single larger line. Readings still cannot move the item as they
  change.
- The menu bar is no longer built from presets. Choose up to five metrics in
  any order, in Settings or from the status item's Menu Bar submenu. Choosing
  none shows the Searoom mark alone, which is what Minimal used to be.
- Existing settings migrate to the equivalent metric list, so the menu bar
  keeps showing what it showed before. The LLM preset is the one imperfect
  case: it drew `RAM used/total`, which no single metric expresses, so it
  becomes RAM used, temperature, and GPU memory, and the total is lost.
- Releases are now gated on continuous integration. `Scripts/release.sh
  --publish` refuses to tag or publish from a commit whose CI run did not
  conclude successfully, and a published release is re-checked against the
  artifacts attached to it: notarization, stapling, and the SHA-256 values in
  the release notes.

### Fixed

- Stacked menu-bar lines are positioned by baseline rather than by line box,
  so they no longer sit a point low in a 22pt menu bar.

## [0.2.0] - 2026-09-02

### Added

- Memory compression telemetry: the compressor's share of the working set and
  compression/decompression byte rates in the Engine Room, with the compressed
  share drawn as a second trend line on the memory card.
- GPU working-set memory: a GPU Memory card comparing in-use GPU system memory
  against the Metal-recommended working-set budget, a `VRAM` custom menu-bar
  metric, and VRAM in the LLM preset.
- Disk capacity: a Disk card showing remaining space with a used-capacity
  trend, and a `DISK` custom menu-bar metric. Remaining space is a neutral
  capacity reading, not a pressure signal.
- Sustained pressure: the dashboard header reports how long the current
  overall pressure level has been held. A `+` suffix means the run spans every
  retained sample, so the history window rather than the Mac bounds the figure.
- Synchronized hover across the six primary trends (CPU, memory, GPU, GPU
  memory, disk, thermal).
- Click-to-cycle display units for compressed memory, compression rates, GPU
  memory, and disk capacity.
- This changelog.

### Changed

- GPU pressure is now the greater of GPU utilization and the working-set
  ratio against the Metal-recommended budget, mirroring how CPU pressure
  combines utilization with normalized load. It remains a Searoom-derived
  signal, not an Apple pressure API, and is documented as such.

## [0.1.1] - 2026-08-31

### Added

- `Searoom.dmg`: a signed, notarized disk image published alongside the zip,
  styled with a paper-coloured background and a layout that persists.
- A user-initiated Check for Updates menu item. It fetches only a version
  manifest when chosen, never on a schedule, and never downloads or installs
  anything.
- The running version in the Settings footer.

## [0.1.0] - 2026-08-31

### Added

- Initial release. Searoom is a local-only macOS 14+ menu-bar instrument for
  understanding remaining system capacity during sustained workloads such as
  local LLM inference: CPU, memory, swap, thermal, GPU, network, and disk
  telemetry with derived pressure states, dithered trend graphs, menu-bar
  presets, up to three custom menu-bar metrics, bounded on-disk history, a
  global shortcut, and launch at login. No analytics, no accounts, no
  background network activity.

[Unreleased]: https://github.com/emaitchess/searoom/compare/v0.5.1...HEAD
[0.5.1]: https://github.com/emaitchess/searoom/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/emaitchess/searoom/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/emaitchess/searoom/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/emaitchess/searoom/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/emaitchess/searoom/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/emaitchess/searoom/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/emaitchess/searoom/releases/tag/v0.1.0
