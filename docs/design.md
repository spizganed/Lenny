# Lenny Design System — Dark Neubrutalism ("Sticker UI")

This file defines the visual language for every Lenny screen (desktop receiver and mobile sender). Follow it for all UI work, including screens and components that don't exist yet: quick connect menu, settings, onboarding, dialogs, and so on. When something isn't covered here, extend the rules below rather than falling back to Material defaults.

## 1. The idea in one sentence

Every interactive or grouping element is a flat, solid-colored "sticker": a thick dark outline, chunky rounded corners, and a hard offset shadow with zero blur. The sticker sits slightly above a dark dotted page and physically presses down into its shadow when tapped.

## 2. Non-negotiable rules

1. **No gradients, no blur, no soft elevation.** Shadows are solid ink rectangles offset down-right, with `blurRadius: 0` and `spreadRadius: 0`. Never use Material `elevation`.
2. **Every card, button, input, chip, switch, and tile has a 3px ink outline** (`#07081A`).
3. **Every sticker has an offset shadow** in the same ink color, sized by role (see §4).
4. **Press = sink.** On press, the element translates down-right by its shadow offset and the shadow shrinks to 0 (80ms, ease). On release it springs back.
5. **One color = one meaning.** Accent colors are functional, never decorative (see §3.2). If a color doesn't carry its meaning, the element uses a neutral surface.
6. **Text on accent fills is always ink** (`#07081A`), never white.
7. **Corners are chunky rounded** (14–20px). Full pills are reserved for status chips, switches, and segmented controls.
8. **Background is always the dotted page**, never a flat app-bar color band. There is no colored AppBar; the header sits directly on the page.

## 3. Tokens

### 3.1 Neutrals

| Token | Hex | Use |
|---|---|---|
| `ink` | `#07081A` | Outlines, shadows, text on accent fills |
| `page` | `#1A1D38` | Page background |
| `pageDot` | `#2C3060` | Dot pattern on the page |
| `surface` | `#262A4D` | Cards, neutral buttons in the header, chips |
| `well` | `#0F1126` | Recessed areas inside cards: inputs, off toggles, stat tiles, slider track, preview frame |
| `text` | `#F4F1E8` | Primary text (warm cream, not pure white) |
| `textMuted` | `#B7B9D6` | Labels, captions, secondary text |
| `textFaint` | `#9A9DC8` | Placeholder content inside wells only |

### 3.2 Accents (functional)

| Token | Hex | Meaning (the ONLY thing it's used for) |
|---|---|---|
| `yellow` | `#FFD23F` | Primary action: Connect, Start, Save, the main CTA of a screen. Max one per view. |
| `mint` | `#2EE6C5` | On / selected state: active toggles, selected segment, switch-on track |
| `green` | `#4ADE80` | Live / streaming status only: status dots, LIVE badge |
| `coral` | `#FF6B6B` | Stop / destructive / disconnected: Disconnect, Stop stream, delete, error status |
| `lilac` | `#A78BFA` | Values & info: slider fill, info badges, "waiting" status, platform tags |

Don't introduce new accent colors. If a new meaning is needed, discuss first.

### 3.3 Shape

| Token | Value |
|---|---|
| `borderWidth` | 3px everywhere |
| `radiusCard` | 20px |
| `radiusButton` | 16px |
| `radiusInput` | 14px |
| `radiusTile` | 14px (stat tiles, small wells, swatches) |
| `radiusChipSmall` | 12px (header copy chips, icon buttons) |
| `radiusPill` | 999px (status chips, switches, segmented controls only) |

### 3.4 Shadow offsets (x = y, always down-right, blur 0)

| Element | Offset |
|---|---|
| Hero/preview card | 8px |
| Cards | 6px |
| Primary / destructive buttons | 5px |
| Regular buttons, toggles, segmented control | 4px |
| Inputs, chips, switches, small icon buttons, slider track/thumb | 3px |
| Tiny status dot (optional) | 2px |
| Stat tiles *inside* a card | none (outline only) |

### 3.5 Spacing

- Page padding: 32px desktop, 20–24px mobile.
- Gap between cards: 16px (column), 24–28px (between major regions).
- Card inner padding: 18px (24px on large/showcase cards).
- Gap inside cards: 14px between rows; 10–12px between sibling buttons.
- Touch targets ≥ 44px tall. Standard button height 50–54px; primary full-width button 56px.

### 3.6 Typography

Use the `google_fonts` package.

| Role | Font | Weight | Size |
|---|---|---|---|
| Wordmark "Lenny" | Bricolage Grotesque | 800 | 46 desktop / 38 mobile, letter-spacing −0.02em, with a 3px hard ink text shadow |
| Headings / hero status ("Streaming") | Bricolage Grotesque | 700–800 | 22–28 |
| Body, button labels | DM Sans | 700 for buttons, 400–500 for body | 16–18 buttons, 14–16 body |
| Section labels | JetBrains Mono | 700 | 12, UPPERCASE, letter-spacing 0.08em, `textMuted` |
| Technical values (IPs, ports, fps, kbps, ms) | JetBrains Mono | 500–700 | 13–18 |

Rule: anything a user might copy or read as a number (IP, port, bitrate, latency) is monospace.

### 3.7 Page background

Dot grid: `pageDot` dots of ~1.6px radius on a 24px grid (22px on mobile) over `page`. Implement with a `CustomPainter` behind the whole scaffold. It's subtle texture, not a pattern that competes with content.

## 4. Component recipes

### Card
`surface` fill, 3px ink border, radius 20, 6px shadow, padding 18. Starts with a **section label** (mono, uppercase, muted), e.g. `CAMERA`, `FOCUS & LIGHT`, `EXPOSURE`, `STREAM`, `CONNECTION`. Group related controls into one card; don't leave controls floating on the page.

### Buttons
| Variant | Fill | Text | Shadow |
|---|---|---|---|
| Primary | `yellow` | ink | 5px |
| Destructive | `coral` | ink | 5px |
| Neutral | `well` (inside cards) or `surface` (on page) | `text` | 4px |
| Icon button | `surface` | `text` | 3px, 44–48px square, radius 12–14, needs a tooltip/semantic label |

All buttons use the press-sink behavior. Disabled: keep the shape, drop the shadow to 0, fill `well`, text `textMuted`, no press animation.

### Toggle button (e.g. Auto, Lock focus)
- Off: `well` fill, `text` label.
- On: `mint` fill, ink label, and a leading bold check icon (✓, stroke ~3).
- Same size/shape/shadow in both states; only fill, text color, and icon change.

### Switch (e.g. Torch)
Pill track 68×38, 3px border, 3px shadow. Knob: 24px `text`-colored circle with 3px ink border.
- Off: track `well`, knob left.
- On: track `mint`, knob right.
Animate knob position (~120ms). Label with icon sits on the left of the row, switch on the right.

### Segmented control (e.g. Back / Front)
One pill container (3px border, 4px shadow, clip). Segments split equally, separated by a 3px ink vertical divider. Selected segment `mint` with ink text; others `well` with `text`. Height 50–52.

### Text input
Label above (DM Sans 700, 14, `text`). Field: `well` fill, 3px border, radius 14, 3px shadow, height 50, horizontal padding 14, monospace for technical values. Focused: shadow grows to 4px and border stays ink (no colored focus glow). Disabled/locked (e.g. while streaming): `textMuted` value, no shadow.

### Status chip
Pill, height 38–44, `surface` (on page) or `well` (in card), 3px border, 3px shadow. Leading 12–14px dot with 3px ink border in the status color: green = streaming, lilac = waiting/connecting, coral = disconnected/error. Label in DM Sans 700.

### Badge (overlay on preview)
Small pill (height 32), 3px border, 3px shadow, mono 13 bold. `LIVE` badge = `green` fill + ink text + small ink dot. Info badges (camera side, resolution) = `surface` fill + `text`.

### Copy chip (IP / port in header)
Button styled as chip: `surface`, radius 12, height 44, 3px shadow, mono 14 bold, value + trailing copy icon. Tapping copies and briefly swaps the icon to a check.

### Slider (e.g. Exposure)
Track height 22, 3px border, pill, 3px shadow. Filled portion `lilac`, remainder `well`, with a hard edge between them (no gradient blend). Thumb: 34px `text` circle, 3px ink border, 3px shadow. Small sun icon at the left end, large sun icon at the right end, in `textMuted`.

### Stat tile
Inside a card: `well` fill, 3px border, radius 14, **no shadow**, padding 8×12. Label DM Sans 12 `textMuted`, value JetBrains Mono 18 bold. Lay out in a 2-column grid (desktop sidebar) or wrap.

### Preview frame (desktop)
Hero card: `well` fill, 8px shadow, radius 20, padding 16. Inside it, the video sits in a 4:3 box with a 3px ink border and radius 14, letterboxed and centered. Badges overlay the top corners at 18px inset.

### Menus, sheets, dialogs (future: quick connect, settings)
Treat them as cards floating above the page: `surface`, 3px border, radius 20, 8px shadow. Dim the page behind with a flat `ink` at ~60% opacity (no blur). List rows inside are `well` tiles or neutral buttons with the press-sink behavior. The single main action in a dialog is yellow; the cancel is neutral; destructive is coral.

## 5. Icons

Line icons, stroke width 2.5 (3 for check marks), round caps and joins, colored with the current text color. Sizes: 16–20 inline, 48–56 for empty/placeholder states. No filled icons, no emoji, no colored icon backgrounds unless the icon sits inside a sticker.

## 6. Layout patterns

**Desktop receiver:** wordmark + platform tag + status chip on the left of the header; connection info chips and settings button on the right. Below: the preview hero takes all remaining width; a fixed ~380px control column on the right holds stacked cards (Camera → Focus & light → Exposure → Stream stats).

**Mobile sender:** header row (wordmark left, settings icon button right) → status hero card (big green dot, "Streaming" heading, mono "to IP · port" subline) → Connection card (inputs + full-width action button) → Camera card (segmented control, toggle grid, torch switch row, exposure slider). Single column, full width minus page padding.

## 7. Flutter implementation notes

- Build one reusable `Sticker` / `PressableSticker` widget and use it everywhere rather than restyling Material widgets piecemeal:
  - `BoxDecoration(color: fill, border: Border.all(color: ink, width: 3), borderRadius: BorderRadius.circular(r), boxShadow: [BoxShadow(color: ink, offset: Offset(o, o), blurRadius: 0)])`.
  - Pressed state: track pressed via `GestureDetector`/`Listener` (`onTapDown`/`onTapUp`/`onTapCancel`), then `AnimatedContainer` (80ms, `Curves.easeOut`) with `transform: Matrix4.translationValues(o, o, 0)` and shadow offset `Offset.zero`.
- Put all values from §3 in a single `LennyTokens` class (colors, radii, shadow offsets, spacing) and a `ThemeData` with `useMaterial3: true` but with ripples disabled (`splashFactory: NoSplash.splashFactory`, transparent highlight/hover overlays). Press feedback comes from the sink, not ink splashes.
- Override Material components (`FilledButton`, `SegmentedButton`, `Switch`, `Slider`, `TextField`) only if they can hit the spec exactly; otherwise use custom widgets. Stock Material shapes, elevation, and ripples must not leak through.
- Slider: custom `SliderTheme` with a custom track shape (bordered pill, hard-edged lilac fill) and thumb shape (bordered circle with offset shadow), or a custom widget.
- Dot background: one `CustomPainter` wrapping the scaffold body; scaffold `backgroundColor` = `page`.
- Keep text contrast ≥ 4.5:1: `text`/`textMuted` on `page`, `surface`, or `well`; ink on every accent.

## 8. Don'ts

- No Material elevation, blurred shadows, ripples, or tinted surface overlays.
- No gradients (the slider's two-color fill is a hard stop, not a blend).
- No thin 1px outlines or borderless elements.
- No white text on accent fills.
- No accent used for decoration, and no more than one yellow action per view.
- No pure white (`#FFFFFF`) or pure black backgrounds.
- No fully rounded pill buttons for regular actions (pills are for status chips, switches, and segmented controls only).
- No colored app bar band; the header lives on the dotted page.
