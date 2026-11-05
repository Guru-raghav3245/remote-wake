# Remote Wake design language: terminal-bloom (dark only)

One source of truth for the Mac app (`app/RemoteWakeMenu.swift`), the Android app (`android-app/lib/theme.dart`) and the demo pages (`design/rose-style.html`, `design/logo-options.html`). Change a value here, then in the two code files. Replaces the earlier "Sage" light/dark language.

Idea (from an ASCII-rose reel): text characters are the material. Big things are drawn as shaded characters, everything else is plain monospace, and colour carries state.

## Colors (dark only)
| Token | Value | Use |
|---|---|---|
| bg | `#0B0B0E` | window / screen |
| card | `#121217` | cards, panels |
| soft | `#1A1A21` | pressed / tinted fills |
| line | `#23232B` | 1 px borders, dividers |
| stage | `#050507` | the ASCII art stage |
| text | `#E8E8EC` | primary text |
| muted | `#8A8A98` | secondary text (passes 4.5:1 on card) |
| dim | `#6B6B78` | decoration only (HUD text, inactive markers) |
| accent (ok) | `#7BE0B0` | on / good / primary action |
| onAccent | `#06130D` | text on accent |
| warn / warnBg | `#E3B341` / `#2B251C` | needs attention |
| danger / dangerBg | `#E5484D` / `#2B181D` | off, lost, errors |
| pink | `#FF6AC1` | current step, current line, focus ring |
| blue | `#6CB6FF` | links in code-like text |

## Type
System monospace everywhere (SF Mono on Mac, Android `monospace`). Title 22/700, body 13 to 15, captions 12. No bundled font.

## Spacing and shape
4-pt scale only: xs 4, sm 8, md 12, lg 16, xl 24, xxl 32. Cards radius 14, 1 px `line` border, no shadows except the glow on the primary button and status dots. Touch targets at least 44 pt on the phone.

## Components
- **Status:** a glowing dot + a lowercase word (accent good, warn, danger, muted off). Same everywhere.
- **ASCII button:** a frame of characters (`+----+` / `|  LABEL  |`). When it is the action the user must take, the top and bottom borders ripple (characters from `.:-=+*#%@`) on a faint accent fill with a glow; otherwise a still, muted frame. Ripple stops with Reduce Motion.
- **ASCII word (Mac hero):** the status word (AWAKE accent, ASLEEP danger, PLUG IN warn) is rasterised into a character grid (A and W mirrored so both sides match, 2-column letter gap, faint edge-row cells dropped) and shaded by a light sweeping across. Phone hero: an ASCII laptop (28 columns, every row the same width) with the status word as plain bold text under it.
- **Path line:** `[phone] ---o--- [mac awake]`, the dot moves while the phone can reach an awake Mac.
- **Step markers:** `[x]` done (accent), `[>]` current (pink), `[ ]` later (dim).
- **Phone terminal:** quick-command chips, red Stop (^C), key grid (Esc Tab Ctrl arrows | / ~ - _ *), a command bar with autocorrect off, and banners (amber reconnecting, pink approval).

## Logo
Option B: a `>_` prompt with a `Z` made of small `z` characters, mint on near-black. Three sizes of drawing: 128 px and up shaded characters, 48 to 127 px dot-matrix, under 48 px bold solid shapes. The chevron is a hand-made bitmap so it is exactly symmetric. Generated, not hand-exported: run `python3 design/make-icons.py` (headless Chrome renders `design/icon-render.html` into the Mac `.icns`, Android launcher layers, notification icon, `app/logo.png`). The Mac menu bar icon is drawn in code (`menuIcon(on:)`), a template image dimmed when stay-awake is off.

## Rules
- One primary action per screen at a time (the rippling ASCII button). Everything else is a quiet frame or text.
- When stay-awake is off, say what it costs (the phone cannot reach the Mac) and offer the action right there.
- Show only what the user needs now: setup steps until setup is done, then a calm dashboard.
