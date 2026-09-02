---
version: "alpha"
name: Searoom
description: A quiet, dithered macOS instrument panel for understanding how much compute searoom remains during demanding local work.
colors:
  primary: "#151613"
  secondary: "#595959"
  neutral: "#EEEADF"
  cool: "#336B8A"
  nominal: "#45874F"
  elevated: "#AD6B0A"
  constrained: "#C44514"
  critical: "#B82E26"
  dark-primary: "#E9E7DD"
  dark-secondary: "#A8A8A8"
  dark-neutral: "#111210"
  dark-cool: "#73B7D3"
  dark-nominal: "#86D98F"
  dark-elevated: "#FFC857"
  dark-constrained: "#FF8745"
  dark-critical: "#FF6B61"
typography:
  metric-large:
    fontFamily: "Departure Mono"
    fontSize: "20px"
    fontWeight: 400
    lineHeight: 1.1
    letterSpacing: "0em"
  metric:
    fontFamily: "Departure Mono"
    fontSize: "15px"
    fontWeight: 400
    lineHeight: 1.2
    letterSpacing: "0em"
  label:
    fontFamily: "Departure Mono"
    fontSize: "10px"
    fontWeight: 400
    lineHeight: 1.2
    letterSpacing: "0.08em"
  body:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.35
    letterSpacing: "0em"
rounded:
  none: "0px"
  subtle: "4px"
  popover: "10px"
  mark: "48px"
spacing:
  hairline: "1px"
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "24px"
components:
  dashboard-light:
    backgroundColor: "{colors.neutral}"
    textColor: "{colors.primary}"
    typography: "{typography.body}"
    rounded: "{rounded.popover}"
    padding: "{spacing.md}"
    width: "430px"
    height: "720px"
  dashboard-dark:
    backgroundColor: "{colors.dark-neutral}"
    textColor: "{colors.dark-primary}"
    typography: "{typography.body}"
    rounded: "{rounded.popover}"
    padding: "{spacing.md}"
    width: "430px"
    height: "720px"
  metric-card-light:
    backgroundColor: "{colors.neutral}"
    textColor: "{colors.primary}"
    typography: "{typography.metric}"
    rounded: "{rounded.subtle}"
    padding: "{spacing.md}"
  metric-card-dark:
    backgroundColor: "{colors.dark-neutral}"
    textColor: "{colors.dark-primary}"
    typography: "{typography.metric}"
    rounded: "{rounded.subtle}"
    padding: "{spacing.md}"
  metric-label-light:
    backgroundColor: "{colors.neutral}"
    textColor: "{colors.secondary}"
    typography: "{typography.label}"
  metric-label-dark:
    backgroundColor: "{colors.dark-neutral}"
    textColor: "{colors.dark-secondary}"
    typography: "{typography.label}"
  graph-light:
    backgroundColor: "{colors.neutral}"
    textColor: "{colors.cool}"
    typography: "{typography.label}"
    rounded: "{rounded.none}"
    height: "36px"
  graph-dark:
    backgroundColor: "{colors.dark-neutral}"
    textColor: "{colors.dark-cool}"
    typography: "{typography.label}"
    rounded: "{rounded.none}"
    height: "36px"
  state-rail-nominal-light:
    backgroundColor: "{colors.nominal}"
    rounded: "{rounded.none}"
    width: "4px"
    height: "16px"
  state-rail-elevated-light:
    backgroundColor: "{colors.elevated}"
    rounded: "{rounded.none}"
    width: "4px"
    height: "16px"
  state-rail-constrained-light:
    backgroundColor: "{colors.constrained}"
    rounded: "{rounded.none}"
    width: "4px"
    height: "16px"
  state-rail-critical-light:
    backgroundColor: "{colors.critical}"
    rounded: "{rounded.none}"
    width: "4px"
    height: "16px"
  state-rail-nominal-dark:
    backgroundColor: "{colors.dark-nominal}"
    rounded: "{rounded.none}"
    width: "4px"
    height: "16px"
  state-rail-elevated-dark:
    backgroundColor: "{colors.dark-elevated}"
    rounded: "{rounded.none}"
    width: "4px"
    height: "16px"
  state-rail-constrained-dark:
    backgroundColor: "{colors.dark-constrained}"
    rounded: "{rounded.none}"
    width: "4px"
    height: "16px"
  state-rail-critical-dark:
    backgroundColor: "{colors.dark-critical}"
    rounded: "{rounded.none}"
    width: "4px"
    height: "16px"
---

# Overview

Searoom should feel like a compact research-vessel instrument: calm, legible, utilitarian, and slightly tactile. It exists to answer one question at a glance: **how much useful capacity does this Mac have left?** The visual language borrows the honesty of early Macintosh graphics without turning the app into nostalgia or decoration.

The interface is a native macOS menu-bar popover, not a miniature dashboard website. It should open instantly, remain understandable in under five seconds, and disappear cleanly when focus moves elsewhere. System metrics are primary; Searoom's own resource cost is always visible so the instrument remains accountable.

The brand mark is a geometric capital **S** crossing a dithered waterline, with the letter's middle stroke centered on the line so the field fills exactly the lower half. It suggests both “Searoom” and a ship's Plimsoll line: the lower field is current load, while the paper above it is remaining capacity. The field is knocked out around the letter so dense dither never fuses with its strokes. Use the full name in documentation and onboarding. Use the mark alone only where the app's identity is already established, such as the app icon or menu-bar compact mode.

## Colors

Searoom uses warm paper and near-black ink instead of pure white and black. Semantic colors describe capacity state and never serve as the only signal.

| Role | Light | Dark | Meaning |
| --- | --- | --- | --- |
| Paper | `#EEEADF` | `#111210` | Main surface |
| Ink | `#151613` | `#E9E7DD` | Primary text and structure |
| Secondary | `#595959` | `#A8A8A8` | Labels and supporting text |
| Cool | `#336B8A` | `#73B7D3` | Neutral telemetry and graphs |
| Nominal | `#45874F` | `#86D98F` | Plenty of searoom |
| Elevated | `#AD6B0A` | `#FFC857` | Worth watching |
| Constrained | `#C44514` | `#FF8745` | Performance may be limited |
| Critical | `#B82E26` | `#FF6B61` | Immediate contention or failure |

Every state combines color with a word, value, line pattern, or icon. Do not use large solid status fills. Status color belongs in one-pixel borders, graph strokes, compact indicators, and short state labels. Respect the system appearance and Increase Contrast preference; when a semantic color does not provide sufficient text contrast, render text in Ink and retain the semantic color as a non-text indicator.

## Typography

Departure Mono is the voice of the instrument. It is bundled under the SIL Open Font License and is used for metric values, units, timestamps, compact menu-bar text, graph annotations, and uppercase micro-labels. Keep its natural spacing for values so the readout stays calm and mechanically precise.

Use the system font for preferences, help, longer explanations, buttons, and accessibility-facing prose. This keeps Searoom native and reduces visual fatigue. Never use Departure Mono for paragraphs.

- Large metric: Departure Mono Regular, 20 pt, tabular presentation. Scale down only when an explicit-unit reading would exceed its card width; never let it overlap the card edge.
- Metric value: Departure Mono Regular, 15 pt.
- Micro-label: Departure Mono Regular, 10 pt, uppercase, 0.08 em tracking.
- Body and controls: system font, 13 pt.

Prefer whole percentages and compact binary units in the popover. Preserve greater precision only in exported diagnostics. Avoid weight changes as hierarchy; use scale, spacing, and color instead.

## Layout

The default popover is 430 × 720 pt with a 12 pt outer inset. Content is arranged on a simple two-column grid with 10–12 pt gutters. The overview state and primary resource cards appear before secondary hardware and process details. If the display cannot fit the full popover, content scrolls vertically while the header remains visually stable. Horizontal scrolling and horizontal gesture drift are disabled.

Card order is the reader's. The nine movable sections—the six metric cards, network I/O, fan and uptime, and the Engine Room—can be rearranged by dragging a card on the dashboard or through the reorder list in Settings, and the choice persists. The shipped default still places primary resource cards before secondary hardware and process detail; a reader who departs from it is overriding a default knowingly. The header, the accountability strip, and the footer are not movable, so the strip stays immediately before the footer in every arrangement. A full-width section placed after an odd number of half-width cards leaves the other half of that row empty rather than reflowing a card into it.

While a card is being dragged it is a plain outline following the pointer, and a one-pixel ink rule marks where it will land, drawn from the arrangement the drop would actually produce. No shadow, no scaling, no animated reflow; the same flat rules apply here as everywhere else.

Metric cards share a consistent anatomy: uppercase label, current value, supporting detail, then a compact trend graph. Values align to the leading edge. Related pairs—CPU and memory, network in and out, GPU and thermal—may share a row, but each metric remains understandable in isolation. Searoom's own CPU, RAM, and sampling interval form one compact single-line accountability strip after every system metric section and immediately before the footer.

The menu-bar status item has two layouts. Stacked is the default: each metric is a column with its label above its value, which measures about 61% of the inline width for the same five metrics and binds each label to its own reading, so no separator glyph is needed between columns. Inline is one line with the label beside the value, kept for anyone who prefers larger text to a narrower item. The menu bar is only about 22pt tall, so stacked type is necessarily small; that is the trade it makes. Its content is chosen rather than preset: an ordered selection of up to five metrics, starting with CPU usage, RAM used, and temperature. Choosing none is a valid selection and gives the mark-only item, which is the only mode that displays the Searoom mark and the only one that stays a centred square. One selected metric may render as more than one group, so the limit of five counts selections rather than groups. Every text preset begins with one fixed-size, non-template semantic dot derived from overall pressure: nominal green, elevated/busy amber, constrained orange, critical red, and unavailable gray. The dot is a state marker rather than the Searoom mark, occupies a stable leading column, and is paired with the button's accessible state description. Each metric group uses its own pressure color so CPU, memory, GPU, thermal, fan, swap, power, and self-impact can be assessed independently. Network and disk activity use the cool non-alarm color when active and subdued ink while idle; uptime remains neutral because its magnitude is not a health signal. Metric groups are joined by a single subdued `·` with no surrounding spaces. Text presets do not show the Searoom mark and use AppKit's natural variable status-item length. Only volatile values reserve compact fixed character columns in Departure Mono: labels and separators retain their natural width, while ordinary changes such as `8%` to `10%`, `8G` to `10G`, and available to unavailable do not move neighboring items. The stacked layout keeps the same promise by a different route: a column is as wide as the greater of its label and its fully padded value, so the reading has room to grow inside its own column and nothing after it moves. Changing the preset or custom metric selection may resize the item; sampling updates may not unless a value exceeds its documented compact field. Omit decorative dither in text modes; system legibility wins there.

Settings use standard macOS window behavior and controls. The dashboard footer is one equal-width, three-column action row: Settings labeled with `⌘,`, Activity Monitor, and Quit labeled with `⌘Q`. Activity Monitor is an explicit bridge to the system utility, not a replacement for Searoom telemetry. The global-shortcut recorder must show the recorded key chord, disclose conflicts without losing the previous working shortcut, and sit beside an equally sized Clear button.

Spacing uses a four-point rhythm: 4, 8, 12, 16, and 24 pt. A one-pixel optical gap is allowed for graph grids and dither structures.

## Elevation & Depth

The app is deliberately flat. Cards are separated by whitespace, hairline ink borders, and sparse dither—not drop shadows. The system owns the popover shadow and window material. Do not stack additional translucent materials or simulate depth with gradients.

Dither is a material, not noise. Use an ordered 4 × 4 Bayer matrix so the pattern is deterministic, stable between frames, and cheap to draw. It may indicate surface separation, graph fill, pressure, or unavailable telemetry. Dither density should rise with intensity, never obscure values, and never animate continuously. Under Reduce Motion, state changes are immediate. Under Increase Contrast, reduce decorative dither and strengthen boundaries.

## Shapes

Use mostly rectangular geometry with one-pixel rules. Metric cards have at most a subtle 4 pt corner radius. Avoid pills except where macOS supplies them as a platform control. The outer popover follows the system window shape.

Graphs use square or minimally rounded joins. The Searoom mark may use the app icon's rounded-square silhouette, but the **H**, waterline, and individual dither cells remain crisp. The Minimal menu-bar mark is a monochrome template image; text modes contain no mark. Semantic color remains inside the popover except for the small overall-state dot that leads text menu-bar modes.

## Components

### Menu-bar status item

Displays the selected text preset using Departure Mono and compact fixed value columns, or the mark alone in Minimal. It supports left-click to toggle the popover, right-click for its context menu, and the same toggle through the configurable global shortcut. Never imply that unavailable sensor data is zero.

### System-state header

Combines a plain-language state—All Clear, Busy, Constrained, Critical, or Checking—with the most relevant limiting signal. Color is supplemental. A short operational sentence is more valuable than a synthetic score without context.

### Metric card

Shows one current reading, a concise qualifier, and a local trend. Missing values display `N/A` and a reason where space permits. Clicking a convertible byte, temperature, or throughput reading rotates only that reading's units; paired directions rotate together. Units rotate on release, not on press: a press that travels far enough becomes a drag that reorders the card, and one that does not is still a click that rotates the reading. Cards whose whole surface rotates a unit are draggable on the same terms as any other. Unit selection is presentation state and must not reinterpret stored samples or trigger collection. Cards do not poll or own data; they render the shared sampled state.

### Trend graph

Uses a single thin semantic stroke over a faint ordered-dither field. Percentage series retain a fixed zero-to-one scale, temperature uses the documented operating range, and paired network series share the recent maximum. The memory trend draws two series on the shared zero-to-one scale: the used-ratio in the pressure color and the compressed-ratio in the cool telemetry color. Hovering any of the six primary trends snaps all six crosshairs and value tooltips to the same nearest locally stored sample; the network trend retains its own hover. Hover must show exact values and timestamps, never interpolate, and never trigger new collection. The dashboard accessibility summary communicates current primary values without reading visual padding used by menu-bar fields.

### Pressure indicator

Pressure communicates contention, not merely utilization. Show the state word alongside the measured or derived value. Derived CPU/GPU pressure must be labeled as such in help text and must not masquerade as a private Apple sensor reading.

### Scrolling

The dashboard has no visible scrollbars or scrollbar gutters. Retain vertical trackpad, mouse-wheel, and keyboard scrolling while disabling elastic overscroll at both boundaries. Horizontal gestures, horizontal scrolling, and first-open lateral layout movement are suppressed completely.

### Settings window

Uses standard AppKit controls, keyboard navigation, clear grouping, and immediate local persistence. Include sample interval, trend window, the ordered menu-bar metric list, launch at login, global shortcut, and a confirmed action to reset trend history without changing preferences. On the first packaged launch only, a short native confirmation asks whether Searoom should open at login; both choices are explicit, remembered locally, and reversible here. Development-mode launches never show the confirmation. The menu-bar metric list adds, removes, and reorders up to five entries, offers only metrics not already chosen, accepts an empty selection as meaning the mark alone, and retains CPU / RAM / temperature as its initial default. It shows the string the status item is currently rendering, so the width cost of a long selection is visible before it reaches the menu bar. Advanced sensor limitations belong in concise help text rather than visual warnings on every card. The footer keeps version and license status at the lower left, with quiet `GITHUB ↗` and `PART OF EMAITCHESS ↗` links at the lower right in that order. Both links use the micro-label style, remain keyboard and VoiceOver accessible, and open their destinations in the default browser only after explicit activation. The GitHub link targets the canonical repository. The affiliation URL retains stable `searoom` source, `desktop_app` medium, `product_attribution` campaign, and `settings_footer` content UTM values.

### Shortcut recorder

Records one key plus standard modifiers, requires a modifier for ordinary printable keys, rejects reserved or conflicting chords, and restores the last registered shortcut on failure. It must be operable entirely by keyboard and expose its state to VoiceOver.

## Do's and Don'ts

### Do

- Optimize for a glance: lead with remaining capacity and contention.
- Keep collection, storage, and drawing costs visible and bounded.
- Use native macOS behavior, system preferences, and accessibility settings.
- Pair every semantic color with text or geometry.
- Keep dither deterministic, sparse, and purposeful.
- Show unavailable private hardware sensors honestly and degrade gracefully.
- Save preferences and bounded history locally; collect no analytics by default.
- Test light mode, dark mode, Increase Contrast, Reduce Motion, VoiceOver, and narrow menu-bar space.

### Don't

- Do not adopt a neon “gamer monitor,” glass dashboard, or cyberpunk aesthetic.
- Do not animate graphs or dither when the popover is closed.
- Do not use gradients, large status fills, ornamental gauges, or fake precision.
- Do not call high-overhead shell tools on every sample.
- Do not claim CPU or GPU pressure is an official macOS pressure API when it is derived.
- Do not turn missing temperature, GPU, or fan telemetry into a failure state.
- Do not hide Searoom's own CPU and memory usage.
- Do not require accessibility or input-monitoring permission for the global shortcut.
