# Product Spec: Remote Wake for Mac (v3.0)

**Version:** 3.0, 2 Nov 2026. **Status:** Personal project, working prototype. A Mac menu bar app, a bundled Tailscale, and an Android app with an SSH terminal are built and tested on one Mac, one real phone and an emulator. The overnight lid-closed test is still pending. **Replaces:** v2.1 (`Remote Wake for Mac Product Spec v2.md`, the "wake it every 30 seconds" design, kept for history) and v1.

## 1. What it is

Remote Wake for Mac lets you open a terminal on your Mac from your Android phone, from any network, with nothing to buy and no router changes.

**The promise:** a Mac that is plugged in with its lid closed stays awake and reachable, and you tap it in the phone app and get a shell in under a second.

**Primary use case:** a Mac left at home, plugged in, lid closed, for days or weeks (for example on holiday), where you want to reach it remotely. Battery use is ignored while it is on AC.

This is not a remote desktop product. It gives a terminal as the Mac user, nothing else.

## 2. What changed from v2

v1 and v2 tried to wake a sleeping Mac. The feasibility tests (Tests 1 to 5, 27 to 28 Oct 2026) showed no outside event can wake it, so v2 woke the Mac itself every 30 seconds and polled a cloud service. The product goal was then clarified: the Mac is left on AC, so it does not need to sleep at all.

| Idea | Finding | Decision in v3 |
| --- | --- | --- |
| An Apple push (APNs) wakes the Mac | Held by Apple's servers while the Mac sleeps; arrives about 2 s after a manual wake | Dropped |
| An inbound packet wakes the Mac | No wake in two trials | Dropped |
| Wake it on a schedule and poll a server | Works on AC, but needs a root helper, a cloud service and a free-tier quota (Upstash 500K commands a month allows 3 to 4 Macs), and the display flashes on each wake | Dropped |
| Keep the Mac awake on AC | `caffeinate -s` holds the Mac awake with the lid closed, only while on AC. Short tests passed (section 8) | **The core of v3** |
| A cloud service reaches the Mac | Not needed: Tailscale gives each device a private address and a direct or relayed path | Tailscale replaces the cloud service |

The old cloud design (Vercel, Upstash, pairing codes, the PWA, the check-in agent) was built and then removed on 2 Nov 2026. It stays in git history (last commit with it: `d5eb0f2`).

## 3. How it works

1. The Mac app installs a small root LaunchDaemon (`com.guru.stayawake`) that runs `/usr/bin/caffeinate -s`. This keeps the Mac awake, lid closed too, but only on AC. On battery the Mac sleeps normally.
2. The app also installs Tailscale (a build of the open-source `tailscale` and `tailscaled` 1.104.4, bundled in the DMG) as a system daemon with Tailscale SSH turned on. It runs before anyone logs in.
3. The Android app embeds the Tailscale engine (`tsnet`, userspace, no VPN permission) and an SSH client, written in Go and loaded by a Flutter app. The user signs in to the same Tailscale account once.
4. The phone lists the Macs on the tailnet. The user taps one, enters the Mac user name, and gets an interactive terminal.
5. The Mac only makes outbound connections and exposes no port. The phone reaches it through Tailscale (direct when possible, relayed otherwise).

## 4. Goals and non-goals

### Goals

1. Reach a plugged-in, lid-closed Mac from a phone on any network.
2. Everything free: no paid services, no paid accounts.
3. No router changes, no open ports.
4. One package: the Mac DMG contains the Mac app, Tailscale and the Android app.
5. Be honest about state: show what is connected, what is not, and why.
6. Be secure: only devices signed in to the owner's Tailscale account can connect, and the phone checks the Mac's SSH key.

### Non-goals

- Waking a sleeping Mac (not possible, see section 2).
- Reaching a Mac that is shut down, out of power, off the network, or stopped at the FileVault unlock screen after a reboot.
- Unlocking the Mac or bypassing FileVault.
- Remote desktop or file access (a terminal only).
- Keeping the Mac awake on battery.
- iPhone in this version (it would need a paid developer account).

## 5. Mac side

- **Menu bar app** (SwiftUI, `app/RemoteWakeMenu.swift`): a switch "Stay awake on AC", the power source, the Tailscale state and address, buttons to install and to sign in or connect Tailscale, and a "Next: set up your phone" hint with the Android app bundled inside (it shows the phone's name once a phone has joined).
- **Install** is one admin password prompt. It installs Tailscale, the stay-awake daemon, and a sudoers rule limited to the four `launchctl enable/disable/bootstrap/bootout` commands for that one daemon, so the switch works silently afterwards.
- **No Python or other runtime** is needed on the Mac.
- **Updates are ours:** each Tailscale security fix means rebuilding the binaries (`app/build-tailscale.sh`) and shipping a new DMG. Tailscale publishes no prebuilt open-source macOS binaries.
- Remove everything with `agent/stayawake-uninstall.sh` and `tailscaled uninstall-system-daemon`.

## 6. Phone app (Android)

- **Home:** Tailscale status and address, a "Sign in to Tailscale" button (opens the browser), and the list of devices on the tailnet (online first, Macs preferred). The user name for each Mac is remembered.
- **Terminal:** a PTY shell (`xterm-256color`) with an extra-keys row (Esc, Tab, sticky Ctrl, ^C, ^D, arrows, `| / - ~`), resize with the screen and keyboard, full-screen programs such as `vi` work.
- **Host-key pinning:** the Mac's SSH key is saved on first connection (trust on first use). A different key later shows a "Host key changed" dialog with a "Trust new key" choice.
- **Reconnect on drop:** an SSH keepalive notices a dead connection in about 25 s, a "Connection lost, reconnecting..." banner appears, and the app retries (2, 4, 8, 15 s, 10 tries, then a Retry button). A reconnect opens a new shell, so running programs are stopped (use `tmux` on the Mac to keep them).
- **Approval prompt:** if the tailnet's SSH rule is "check", Tailscale asks for a browser approval about every 12 hours. The app shows an Approve button (the link arrives as the SSH banner).
- **Background:** a foreground service (partial wake lock, notification) keeps the session alive while the screen is off or the app is in the background; the app asks for the notification permission and a battery-optimisation exemption once.
- **Build:** a signed release APK (about 40 MB, arm64), icon "terminal prompt with zz" on a dark background. The keystore is `~/.remote-wake-android.jks` and must be backed up: losing it means phones have to uninstall to update.

## 7. Security

- **Identity is the Tailscale account.** Tailscale SSH uses no password or key on the phone: the Mac accepts a connection from a device on the owner's tailnet and runs the shell as the user named in the app (the tests used the normal user, not root). The tailnet's current SSH rule also lists `root` as an allowed user; the app does not offer it, but tighten the rule if that matters.
- **Anyone signed in to the owner's Tailscale account can open a shell on the Mac.** Protect the Tailscale account (strong login, 2FA at the identity provider). A lost phone is revoked by removing its node in the Tailscale admin console.
- **Check mode:** the default tailnet policy asks for re-approval about every 12 hours. Changing the rule to "accept" removes the prompt and weakens security; this is the owner's choice.
- **Host-key pinning** protects the phone against talking to a different machine under the same address.
- **No open ports** on the Mac; connections are outbound to Tailscale.
- **The root stay-awake daemon** runs one fixed command and accepts nothing from the network. The sudoers rule can only toggle that daemon.
- **A screen-locked Mac still accepts the connection** (tested). The login password is not needed, so the shell is as powerful as the user's account while the Mac is on.
- **The phone's Tailscale state** is stored in the app's private directory. Rooted phones or backups could expose it.

## 8. What has been validated

One MacBook Pro (Apple M5 Pro, macOS 26.6.2), one Nothing Phone (CMF Phone 2 Pro), an arm64 Android 15 emulator, home Wi-Fi and Jio 5G.

| Test | Result |
| --- | --- |
| SSH from the phone (Termux) to the Mac over Tailscale, no password | Pass, shell as the user (not root) |
| Lid closed on AC with `caffeinate -s` | Pass for about 2 min and about 6 min: a phone session printing every 5 s never stopped |
| Display off; screen locked with a fresh connection | Pass (verified with the lock flag, a screenshot and the login process) |
| Phone on mobile data | Pass: direct IPv6 path, then direct via the cellular address (172 ms ping) |
| Clean install of the DMG on the Mac, Tailscale sign-in, toggle | Pass (one password prompt; later toggles silent) |
| Android app: embedded Tailscale engine and SSH on the emulator and the real phone | Pass: connect in 50 to 274 ms, interactive shell, `vi` renders, resize correct |
| Real browser sign-in on the phone | Pass |
| Host-key pinning (changed-key dialog and re-trust) | Pass on the emulator |
| Foreground service through forced Doze | Pass on the emulator (froze without it) |
| Wi-Fi switched off with a session open, phone falls back to mobile data | Pass, no drop |
| Reconnect after a real network drop (emulator, Wi-Fi and data off, then on) | Pass: banner within about 25 s, new shell in about 20 ms |
| Screen off 4 minutes on mobile data | Pass, but the phone was charging (Doze not fully applied) |
| Tailscale "check" approval needed after about a day | Found and handled (banner and Approve button) |

## 9. Not tested, and risks

- **The overnight soak test** (lid closed on AC, 8 to 10 hours) and a 10-minute lid-closed run with the real daemon. This is the closest test to the vacation use case and the main gate before relying on the product.
- **Power loss and FileVault:** after a reboot with FileVault on, the Mac stops at the pre-boot unlock screen, so Tailscale does not run until someone enters the password. The product cannot fix this. Check `pmset -g custom | grep autorestart` so the Mac powers back on after a power cut.
- **On the real phone:** screen off for 10+ minutes unplugged (the phone maker's battery manager may be stricter than the emulator), Gboard typing and autocorrect in the terminal, rotation and keyboard resize, battery use, long sessions, a connection relayed through Tailscale's servers, the Approve button with a real signed-in browser, and reconnect.
- **Tailscale:** the free-plan limits and the terms for commercial use were not verified (sources conflicted). Fine for personal use; check before any public release.
- **Intel Macs:** the bundled binaries are universal but the Intel half is untested. A Mac that never used Tailscale was not tested.
- **Distribution on other machines:** ad-hoc signing gives other Macs a Gatekeeper warning. A sideloaded Android app may trigger a Google Play Protect warning.
- **Name resolution:** the phone could not resolve the MagicDNS name right after a Tailscale reset (use the address or wait).
- **The embedded engine is a community pattern.** Android 11 and later deny apps the network interface list, so the engine supplies a fake list (the same hook Tailscale's own app uses). Network changes were tested only on the one phone and the emulator.
- **Battery on the Mac:** none by design (AC only). Not measured on the phone.

## 10. Free and what would cost money

Everything above costs nothing today. These would cost money, so ask before doing any of them:

- Apple Developer ID (Mac app signing without a warning): $99 a year.
- Google Play Store listing: $25 once.
- iPhone app (App Store or TestFlight): $99 a year.
- Paid Tailscale plan, if the free plan's limits are hit.

## 11. Build status

| Part | Status |
| --- | --- |
| Stay-awake daemon, install and uninstall scripts | Done, tested |
| Mac menu bar app, bundled Tailscale, DMG with the Android app | Done; the phone-setup steps view was not seen on screen |
| Android app: Tailscale sign-in, device list, terminal, host-key pinning, foreground service, reconnect, approval prompt, signed release, icon | Done; real-phone checks listed in section 9 are pending |
| App icons (Android and Mac) | Done (PWA icons not needed, the PWA is part of the old design) |
| Spec for the new design | This document |
| iPhone app | Not started (needs a paid account) |

## 12. Open decisions

- **Tailnet SSH policy:** keep "check" (safer, a prompt about every 12 hours) or switch to "accept".
- **Distribution:** whether and when to pay for Developer ID, the Play Store, or an iPhone app.
- **A second Mac or second user:** not designed. One Tailscale account per owner.

## 13. Cleanup list

- Pending tests: the overnight soak test, FileVault and power-loss, the 10-minute lid-closed run, the real-phone checks in section 9.
- Switch Xcode back to the personal Apple account (Xcode > Settings > Accounts).
- Revoke the APNs key `wakeprobe apns` in the developer portal.
- Delete the GCP test project `<gcp-project>` (VM and firewall rules): the owner runs `gcloud projects delete <gcp-project>` (the assistant's attempt was blocked).
- Turn Power Nap back on: `sudo pmset -a powernap 1`.
- Delete the stale Tailscale nodes (`rw-phone`, `rw-phone-1`) in the admin console.
- Back up `~/.remote-wake-android.jks`.
- Before the repository is made public: remove the Apple team ID, the VM and public IP addresses from `CLAUDE.md` and `RESULTS.md`.
