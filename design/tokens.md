# Remote Wake design language: Sage (light + dark)

One source of truth for the Mac app (`app/RemoteWakeMenu.swift`), the Android app (`android-app/lib/theme.dart`) and the website. Change a value here, then in the two code files.

## Colors
| Token | Light | Dark | Use |
|---|---|---|---|
| bg | `#EEF2EC` | `#151B17` | window / screen background |
| card | `#F8FAF6` | `#1D2520` | cards, rows |
| soft | `#DDE7DA` | `#24302A` | tinted fills (active step, chips) |
| line | `#D3DCCF` | `#2E3A33` | borders, dividers |
| text | `#2F3A33` | `#E4EBE5` | primary text |
| muted | `#5E6B61` | `#9BAB9F` | secondary text, captions |
| accent | `#4F7A5A` | `#8FBF9A` | primary action, "on" state |
| onAccent | `#FFFFFF` | `#11201A` | text on accent |
| warn / warnBg | `#7A5A12` / `#F6EBD3` | `#E5C57A` / `#2B2616` | needs attention |
| danger / dangerBg | `#8A2F26` / `#F4DEDA` | `#E8A097` / `#2D1B19` | errors, lost connection |

## Type: Figtree (SIL OFL, bundled)
Title 24/700, heading 17/600, body 15/400, caption 13/400 muted. Terminal text uses the system monospace.

## Spacing (4-pt scale, nothing else)
xs 4, sm 8, md 12, lg 16, xl 24, xxl 32. Screen/window padding 24 (Mac) or 16 (phone). Gap between cards = lg 16. Inside a card = lg 16 padding, md 12 between its rows.

## Shape
Card radius 16, chip radius 8, buttons are pills (height 44 phone, 36 Mac). Borders 1 px `line`; no shadows in dark mode.

## Rules
- One primary action per screen at a time (a filled accent pill). Everything else is a quiet button.
- Status is always shown the same way: a dot + a word (accent = good, warn, danger, muted = off).
- Show only what the user needs now: setup steps until setup is done, then a calm dashboard.
