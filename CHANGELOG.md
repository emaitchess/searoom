# Changelog

All notable changes to Searoom are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Trackpad haptic feedback when the sample rate changes, at each trend-window
  slider stop, and each time a dragged dashboard card would land in a new slot. Both fire on the change
  rather than per event, so a slow gesture gives one tap per detent crossed.
  `NSHapticFeedbackManager` is part of AppKit, so this adds no dependency and
  no measurable size, and it is a no-op on hardware without a Force Touch
  trackpad.

### Changed

- Sample rate offers every whole second from 1 to 10, on a slider matching the
  trend window rather than a four-item pop-up. All four rates offered before
  are still stops, so a stored setting carries over. The value is committed
  when the drag ends, not on each tick: changing it restarts the sampling
  timer, so writing per tick would tear the timer down and rebuild it up to
  nine times for one gesture.
- Superseded within the same unreleased block: sample rate was briefly four
  radio buttons. Four mutually
  exclusive choices with descriptive labels is what radio buttons are for, and
  the pop-up hid three of the four behind a click while stretching to the full
  column width to show one short value. Laid out two by two: four across
  measured 323pt against the 305pt the column has, and four stacked would have
  cost about 84pt of height in a window that cannot scroll.
- Removed the blank line reserved under the global shortcut row. The error
  label was always present and empty, and an empty label still has intrinsic
  height, so it held roughly 16pt whether or not there was an error. It is now
  hidden when there is no message, which drops it from the layout entirely.
- The trend window now runs from 15 minutes to 24 hours. It offers 15 and 30
  minutes then every hour to 24, and Settings presents it as a slider that
  snaps to those stops rather than a four-item menu. The three windows that
  existed before (15 minutes, 30 minutes, 1 hour, 3 hours) are all still
  offered, so a stored preference carries over unchanged.
- The trend-window value beside the slider is pinned to the width of the widest
  value it can show. The strings range from 40.8pt for "1 hour" to 68.0pt for
  "15 minutes", so without this the label resized as the value changed and
  dragged the slider sideways under the thumb.
- Windows longer than three hours keep their full span and retain every nth
  sample rather than every one. A 24 hour window therefore costs no more
  memory, disk, or scan time than the three hour window already did. Nothing
  changes on screen, because the dashboard already downsamples every series to
  its pixel width before drawing, and live readings are never thinned. Storing
  every sample for a 24 hour window would have meant about 33 MB rewritten to
  disk every minute to draw fewer than 400 points.

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

[Unreleased]: https://github.com/emaitchess/searoom/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/emaitchess/searoom/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/emaitchess/searoom/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/emaitchess/searoom/releases/tag/v0.1.0
