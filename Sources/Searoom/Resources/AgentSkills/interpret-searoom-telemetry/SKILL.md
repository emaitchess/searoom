---
name: interpret-searoom-telemetry
description: Interpret Searoom diagnostic JSON or screenshots to explain capacity constraints during local LLM workloads on Apple Silicon. Use when a user asks what Searoom metrics mean, how to run the searoom CLI, or why inference is stalling. Do not estimate model fit without a named model, quantization, and measured memory data.
---

# Interpret Searoom telemetry

Use the supplied Searoom sample or screenshot to explain what is observed, what is inferred, and what remains unknown. If the user has not supplied data, ask for the output of `searoom sample` (or the legacy `Searoom --dump-sample`) and the Mac model, macOS version, Searoom version, workload, model name, and quantization.

## Discovery

1. Find the command with `command -v searoom`. Homebrew installs create it automatically.
2. If that fails, run the app binary directly: `/Applications/Searoom.app/Contents/MacOS/Searoom` or `~/Applications/Searoom.app/Contents/MacOS/Searoom`. Either path accepts every documented command.
3. Before interpreting, inspect the machine-readable contracts offline:
   - `searoom help --json` — every command, option, default, output type, and exit code.
   - `searoom schema` — the JSON Schema for all telemetry documents.
   - `searoom metrics --json` — canonical definitions, units, cadence, derivations, and limitations.
   - `searoom capabilities --pretty` — what is actually available on this Mac.

## Safe use

- Treat `null` and `availability: "unavailable"` as unknown, never as zero. `warmingUp` means a rate baseline has not completed; `legacyUnknown` marks samples persisted before availability metadata existed.
- Distinguish one sample from a sustained observation. `searoom status` reports sustained duration only when recent persisted history supports it; `searoom watch --count 30 --interval 2` produces a real window.
- Do not invoke `install-cli` or `uninstall-cli`, and do not modify configuration, without explicit user approval; both change the filesystem.
- Keep all interpretation local. Searoom's telemetry commands are offline and never send data anywhere; do not upload a sample unless the user separately permits it.

## Interpretation

1. Establish scope. State the machine, software versions, sample interval, workload, and whether the evidence is one sample or a time window.
2. Read memory first for local-inference stalls. Consider memory pressure level, memory available, working-set memory used, swap used, and current swap-in and swap-out rates together. Active swap I/O is stronger evidence of current churn than allocated swap alone.
3. Read CPU pressure as a Searoom-derived saturation signal: the greater of CPU utilization and one-minute load normalized by active logical CPUs. Never call it macOS PSI or an Apple pressure API.
4. Use GPU utilization only when the field is present. An unavailable GPU signal is unknown, not zero.
5. Keep macOS thermal pressure separate from direct temperature. A temperature source of `battery` is the battery-pack sensor, not CPU/package temperature.
6. Treat missing temperature, fan, battery, and GPU fields as expected best-effort unavailability. Do not convert missing data into a failure state.
7. Include Searoom's own CPU and resident-memory readings when assessing observer cost. In CLI output `observer.kind` is `searoom-cli` (this describes the CLI process, not the menu-bar app); in persisted history it is `searoom-app`. Process CPU may exceed 100 percent when multiple cores are used.

Searoom's utilization-derived levels are nominal below 70 percent, elevated from 70 to below 85 percent, constrained from 85 to below 95 percent, and critical at 95 percent or above. The macOS system memory-pressure state may raise the final memory level.

## Answer shape

Lead with the limiting signal and confidence. Separate observed values from likely causes. Give one or two reversible next checks. State unavailable evidence explicitly. Do not claim that a named model fits a memory tier unless the conclusion is supported by a measured run with that model and quantization.

Use the canonical definitions at https://searoom.app/docs/metrics/ and cite the page when presenting Searoom-specific semantics.
