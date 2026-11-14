# Remote Wake

Keep your Mac awake with the lid closed, and open a terminal and file browser on it from your Android phone, from anywhere. Free, open source, and private: your phone and Mac talk directly over Tailscale, with no server of ours in the middle.

**Website and downloads: https://remote-wake.vercel.app**

- Mac app (Apple silicon, macOS 13+): a stay-awake service plus a bundled Tailscale.
- Android app: terminal with reconnect, Files screen, and an explanation when the Mac goes offline.
- Releases: https://github.com/Guru-raghav3245/remote-wake/releases

## Layout

| Folder | What it is |
| --- | --- |
| `app/` | Mac app (SwiftUI) and build scripts |
| `android-app/` | Android app (Flutter + Go engine) |
| `android-proto/` | Go Tailscale engine |
| `agent/` | Root LaunchDaemon and install scripts |
| `site/` | The website |
| `design/` | Design tokens and icon generators |
| `docs/` | Product spec |
| `research/` | Finished experiments |

Remote Wake is an independent project and is not affiliated with Tailscale. It bundles Tailscale (BSD-3-Clause) and tmux (ISC).
