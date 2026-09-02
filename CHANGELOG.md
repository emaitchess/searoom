# Changelog

All notable changes to Searoom are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Releases are now gated on continuous integration. `Scripts/release.sh
  --publish` refuses to tag or publish from a commit whose CI run did not
  conclude successfully, and a published release is re-checked against the
  artifacts attached to it: notarization, stapling, and the SHA-256 values in
  the release notes.

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
