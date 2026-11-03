import SwiftUI

// Menu bar switch for the "stay awake on AC" daemon (agent/com.guru.stayawake.plist).
let label = "com.guru.stayawake"
let plist = "/Library/LaunchDaemons/\(label).plist"
let sudoersPath = "/etc/sudoers.d/stayawake"

import ServiceManagement

// Two modes from one binary: the main app (window + Dock) and the helper (menu bar icon only, runs at login,
// stays alive when the main app quits). The helper sits at Remote Wake.app/Contents/Library/LoginItems/.
let isHelper = Bundle.main.bundleIdentifier?.hasSuffix(".helper") == true
let mainAppURL = isHelper ? Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() : Bundle.main.bundleURL
let resRoot = mainAppURL.appendingPathComponent("Contents/Resources").path

func run(_ cmd: String, _ args: [String]) -> (status: Int32, out: String) {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: cmd); p.arguments = args
    p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

// One admin-password prompt: installs the daemon from the app bundle plus the rule that lets this user toggle it silently.
func rootInstall() -> Bool {
    let r = resRoot
    let cmd = "/bin/bash '\(r)/agent/tailscale-install.sh' '\(r)/tailscale' && /bin/bash '\(r)/agent/stayawake-install.sh' \(NSUserName())"
    return run("/usr/bin/osascript", ["-e", "do shell script \"\(cmd)\" with administrator privileges"]).status == 0
}

// MARK: - Phone sessions (tmux). SSH logins get their own session without the Keychain, so CLIs like Claude Code ask to log in.
// A tmux server started by this GUI app lives in the desktop login session; the phone attaches to it, so saved logins work and
// programs survive a dropped connection. `-D` keeps the server a child of this app (the normal daemonizing start would leave the desktop session).
let phoneDir = NSHomeDirectory() + "/Library/Application Support/Remote Wake"
let tmuxBin = phoneDir + "/tmux", tmuxSock = "remotewake"
let zshrc = NSHomeDirectory() + "/.zshrc"
let zMark = ("# >>> Remote Wake phone sessions >>>", "# <<< Remote Wake phone sessions <<<")
let zBlock = """
\(zMark.0)
# Phone logins (SSH) join a tmux session in your desktop login, so saved logins (Keychain) work. Turn off in Remote Wake or delete this block.
_rw="$HOME/Library/Application Support/Remote Wake/tmux"
if [[ -n $SSH_CONNECTION && -z $TMUX && -x $_rw ]] && "$_rw" -L \(tmuxSock) has-session -t phone 2>/dev/null; then "$_rw" -L \(tmuxSock) attach -t phone && exit; fi
unset _rw
\(zMark.1)
"""
let tmuxConf = """
set -g status-left "[#S] "
set -g status-right ""
set -g history-limit 20000
set -g default-terminal "screen-256color"
set -sg escape-time 10
"""
func tmux(_ a: [String]) -> Int32 { run(tmuxBin, ["-L", tmuxSock] + a).status }
func phoneEnabled() -> Bool { ((try? String(contentsOfFile: zshrc, encoding: .utf8)) ?? "").contains(zMark.0) }
func tmuxUp() -> Bool { FileManager.default.isExecutableFile(atPath: tmuxBin) && tmux(["has-session", "-t", "phone"]) == 0 }
func startTmux() {
    guard FileManager.default.isExecutableFile(atPath: tmuxBin), !tmuxUp() else { return }
    let p = Process(); p.executableURL = URL(fileURLWithPath: tmuxBin)
    p.arguments = ["-u", "-L", tmuxSock, "-f", phoneDir + "/tmux.conf", "-D"]   // bare -D: with a command (even start-server) tmux daemonizes a new server in the Background session instead
    p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return }
    for _ in 0..<30 { usleep(100_000); if tmux(["new-session", "-d", "-s", "phone", "-c", NSHomeDirectory()]) == 0 { return } }   // wait for the socket
}
func setPhone(_ on: Bool) {
    let fm = FileManager.default
    var z = (try? String(contentsOfFile: zshrc, encoding: .utf8)) ?? ""
    if let r = z.range(of: "\n?" + NSRegularExpression.escapedPattern(for: zMark.0) + "[\\s\\S]*?" + NSRegularExpression.escapedPattern(for: zMark.1) + "\n?", options: .regularExpression) { z.replaceSubrange(r, with: "\n") }
    if on {
        try? fm.createDirectory(atPath: phoneDir, withIntermediateDirectories: true)
        _ = tmux(["kill-server"])   // so a new build is picked up
        try? fm.removeItem(atPath: tmuxBin); try? fm.copyItem(atPath: resRoot + "/tmux/tmux", toPath: tmuxBin)
        try? tmuxConf.write(toFile: phoneDir + "/tmux.conf", atomically: true, encoding: .utf8)
        z += (z.hasSuffix("\n") || z.isEmpty ? "" : "\n") + zBlock + "\n"
    } else { _ = tmux(["kill-server"]) }
    try? z.write(toFile: zshrc, atomically: false, encoding: .utf8)   // not atomic: keeps a symlinked .zshrc a symlink
    if on { startTmux() }
}

func tsPath() -> String? { ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"].first { FileManager.default.isExecutableFile(atPath: $0) } }

@MainActor final class Model: ObservableObject {
    @Published var running = false
    @Published var installed = false
    @Published var onAC = true
    @Published var holding = false     // the daemon really holds a sleep assertion
    @Published var tsState = ""        // Running, NeedsLogin, Stopped, ... or "not installed"
    @Published var tsIP = ""
    @Published var authURL: String?
    @Published var phones: [String] = []   // Android devices already on the tailnet (name, with " (offline)" if so)
    @Published var phoneOn = false     // the .zshrc block is there
    @Published var tmuxRunning = false
    @Published var busy = false
    @Published var error: String?
    var timer: Timer?
    var tmuxStarting = false

    init() { refresh(); timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in Task { @MainActor in self.refresh() } } }

    func refresh() {
        installed = FileManager.default.fileExists(atPath: plist)
        running = run("/bin/launchctl", ["print", "system/\(label)"]).status == 0
        onAC = run("/usr/bin/pmset", ["-g", "batt"]).out.contains("AC Power")
        holding = run("/usr/bin/pmset", ["-g", "assertions"]).out.range(of: #"PreventSystemSleep\s+1"#, options: .regularExpression) != nil
        phoneOn = phoneEnabled(); tmuxRunning = phoneOn && tmuxUp()
        if isHelper && phoneOn && !tmuxRunning && !tmuxStarting { tmuxStarting = true; Task.detached { startTmux(); await MainActor.run { self.tmuxStarting = false } } }   // at login, or if it died
        let hasDaemon = ["/usr/local/bin/tailscaled", "/opt/homebrew/bin/tailscaled"].contains { FileManager.default.isExecutableFile(atPath: $0) }
        guard let ts = tsPath(), hasDaemon else { tsState = "not installed"; tsIP = ""; authURL = nil; return }
        let j = (try? JSONSerialization.jsonObject(with: Data(run(ts, ["status", "--json"]).out.utf8))) as? [String: Any]
        tsState = j?["BackendState"] as? String ?? "daemon not running"
        authURL = (j?["AuthURL"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let peers = (j?["Peer"] as? [String: [String: Any]])?.values.filter { ($0["OS"] as? String) == "android" } ?? []
        phones = peers.map { ($0["HostName"] as? String ?? "phone") + (($0["Online"] as? Bool) == true ? "" : " (offline)") }.sorted { ($0.hasSuffix("(offline)") ? 1 : 0, $0) < ($1.hasSuffix("(offline)") ? 1 : 0, $1) }  // online first
        tsIP = ((j?["Self"] as? [String: Any])?["TailscaleIPs"] as? [String])?.first ?? ""
    }

    func toggle() {
        let on = !running
        let cmds = on ? [["enable", "system/\(label)"], ["bootstrap", "system", plist]]
                      : [["disable", "system/\(label)"], ["bootout", "system/\(label)"]]
        busy = true
        Task.detached {
            func go() -> Bool { cmds.allSatisfy { run("/usr/bin/sudo", ["-n", "/bin/launchctl"] + $0).status == 0 } }
            var ok = go()
            // no rule yet (daemon installed by hand): one admin prompt creates it, then retry
            if !ok && !FileManager.default.fileExists(atPath: sudoersPath) && rootInstall() { ok = go() }
            let done = ok
            await MainActor.run { self.busy = false; self.error = done ? nil : "Toggle cancelled or failed"; self.refresh() }
        }
    }

    func phoneSessions(_ on: Bool) {
        busy = true
        Task.detached { setPhone(on); await MainActor.run { self.busy = false; self.refresh() } }
    }

    func connect() {
        guard let ts = tsPath() else { return }
        let host = (Host.current().localizedName ?? "mac").lowercased().replacingOccurrences(of: "['\u{2019}]", with: "", options: .regularExpression).replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        let p = Process(); p.executableURL = URL(fileURLWithPath: ts)
        p.arguments = ["up", "--ssh", "--hostname=\(host)"]   // blocks until sign-in; ends by itself
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    func install() {
        busy = true
        Task.detached {
            let ok = rootInstall()
            await MainActor.run { self.busy = false; self.error = ok ? nil : "Install cancelled or failed"; self.refresh() }
        }
    }
}


// MARK: - Sage design language (see design/tokens.md). Spacing uses only S.*; colors adapt to Light/Dark automatically.
import CoreText

extension Color { init(hex: UInt32) { self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255) } }
func dyn(_ l: UInt32, _ d: UInt32) -> Color {
    Color(nsColor: NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(Color(hex: d)) : NSColor(Color(hex: l)) })
}
enum T {
    static let bg = dyn(0xEEF2EC, 0x151B17), card = dyn(0xF8FAF6, 0x1D2520), soft = dyn(0xDDE7DA, 0x24302A), line = dyn(0xD3DCCF, 0x2E3A33)
    static let text = dyn(0x2F3A33, 0xE4EBE5), muted = dyn(0x5E6B61, 0x9BAB9F), accent = dyn(0x4F7A5A, 0x8FBF9A), onAccent = dyn(0xFFFFFF, 0x11201A)
    static let warn = dyn(0x7A5A12, 0xE5C57A), warnBg = dyn(0xF6EBD3, 0x2B2616)
}
enum S { static let xs: CGFloat = 4, sm: CGFloat = 8, md: CGFloat = 12, lg: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32 }
func ff(_ size: CGFloat, _ w: Font.Weight = .regular) -> Font { .custom("Figtree", size: size).weight(w) }
func registerFonts() { CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: resRoot + "/Fonts/Figtree.ttf") as CFURL, .process, nil) }

struct Card: ViewModifier {
    var tint = false
    func body(content: Content) -> some View {
        content.padding(S.lg).frame(maxWidth: .infinity, alignment: .leading)
            .background(tint ? T.soft : T.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(T.line, lineWidth: 1))
    }
}
extension View { func card(tint: Bool = false) -> some View { modifier(Card(tint: tint)) } }

struct Pill: ButtonStyle {
    var primary = true
    @Environment(\.isEnabled) var enabled
    func makeBody(configuration c: Configuration) -> some View {
        c.label.font(ff(14, .semibold)).padding(.horizontal, S.lg).frame(height: 36)
            .foregroundStyle(primary ? T.onAccent : T.text)
            .background(primary ? T.accent : Color.clear, in: Capsule())
            .overlay(Capsule().stroke(primary ? Color.clear : T.line, lineWidth: 1))
            .opacity(enabled ? (c.isPressed ? 0.8 : 1) : 0.45)
    }
}
struct Quiet: ButtonStyle {
    func makeBody(configuration c: Configuration) -> some View { c.label.font(ff(14, .medium)).foregroundStyle(T.muted).opacity(c.isPressed ? 0.6 : 1) }
}

struct Status: View {   // the one way status is shown everywhere: dot + word
    let word: String, color: Color
    var body: some View { HStack(spacing: S.sm) { Circle().fill(color).frame(width: 8, height: 8); Text(word).font(ff(13, .semibold)).foregroundStyle(color) } }
}

struct InfoRow<Trailing: View>: View {
    let icon: String, label: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: S.md) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(T.muted).frame(width: 22)
            Text(label).font(ff(15)).foregroundStyle(T.text)
            Spacer(minLength: S.md)
            trailing
        }.frame(minHeight: 32)
    }
}
func value(_ s: String) -> some View { Text(s).font(ff(15)).foregroundStyle(T.muted).lineLimit(1) }

struct Logo: View {
    var size: CGFloat = 36
    var body: some View {
        ZStack { RoundedRectangle(cornerRadius: size * 0.3).fill(T.accent); Image(systemName: "moon.zzz.fill").font(.system(size: size * 0.5)).foregroundStyle(T.onAccent) }.frame(width: size, height: size)
    }
}

extension Model {
    var ready: Bool { installed && tsState != "not installed" }
    var awakeWord: (String, Color) { !running ? ("Off", T.muted) : (holding ? ("Awake", T.accent) : ("Waiting for AC", T.warn)) }
    var heroTitle: String { !running ? "Stay awake is off" : (holding ? "Your Mac is staying awake" : "Ready, but on battery") }
    var heroText: String { !running ? "Your Mac sleeps normally." : (holding ? "Safe to close the lid while it is plugged in." : "Plug in to keep it awake. On battery it sleeps normally.") }
    var stayAwake: Binding<Bool> { Binding(get: { self.running }, set: { _ in self.toggle() }) }
}

struct TailscaleRow: View {
    @ObservedObject var m: Model
    var body: some View {
        InfoRow(icon: "network", label: "Tailscale") {
            if m.tsState == "Running" { value(m.tsIP) }
            else if m.tsState == "NeedsLogin", let u = m.authURL, let url = URL(string: u) { Button("Sign in") { NSWorkspace.shared.open(url) }.buttonStyle(Pill()) }
            else { Button("Connect") { m.connect() }.buttonStyle(Pill()) }
        }
    }
}

// MARK: - Main window

struct StepRow<A: View>: View {
    let n: Int, title: String, text: String, done: Bool, active: Bool
    @ViewBuilder var action: A
    var body: some View {
        HStack(alignment: .top, spacing: S.md) {
            ZStack {
                Circle().fill(done ? T.accent : (active ? T.soft : Color.clear)).overlay(Circle().stroke(done ? Color.clear : T.line, lineWidth: 1))
                if done { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(T.onAccent) }
                else { Text("\(n)").font(ff(13, .semibold)).foregroundStyle(active ? T.text : T.muted) }
            }.frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: S.sm) {
                Text(title).font(ff(16, .semibold)).foregroundStyle(done || active ? T.text : T.muted).frame(minHeight: 28, alignment: .leading)
                if active {
                    Text(text).font(ff(14)).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
                    action
                }
            }
        }
    }
}

struct SetupView: View {
    @ObservedObject var m: Model
    var skip: () -> Void
    var done: [Bool] { [m.ready, m.tsState == "Running", m.running] }
    var cur: Int { done.firstIndex(of: false) ?? -1 }
    var body: some View {
        VStack(alignment: .leading, spacing: S.lg) {
            VStack(alignment: .leading, spacing: S.xs) {
                Text("Let's get you set up").font(ff(20, .bold)).foregroundStyle(T.text)
                Text("Three quick steps. Each one ticks itself when it's done.").font(ff(14)).foregroundStyle(T.muted)
            }
            VStack(alignment: .leading, spacing: S.lg) {
                StepRow(n: 1, title: "Install", text: "Adds Tailscale and the stay-awake service. You'll be asked for your Mac password once.", done: done[0], active: cur == 0) {
                    Button("Install") { m.install() }.buttonStyle(Pill()).disabled(m.busy)
                }
                StepRow(n: 2, title: "Connect Tailscale", text: "Sign in with the account you'll also use on your phone.", done: done[1], active: cur == 1) {
                    if m.tsState == "NeedsLogin", let u = m.authURL, let url = URL(string: u) { Button("Sign in to Tailscale") { NSWorkspace.shared.open(url) }.buttonStyle(Pill()) }
                    else { Button("Connect Tailscale") { m.connect() }.buttonStyle(Pill()) }
                }
                StepRow(n: 3, title: "Stay awake on AC", text: "Turn this on. Keep the Mac plugged in; on battery it sleeps normally.", done: done[2], active: cur == 2) {
                    Toggle("Stay awake on AC", isOn: m.stayAwake).toggleStyle(.switch).tint(T.accent).font(ff(14)).disabled(m.busy)
                }
            }.card()
            HStack { Spacer(); Button("Skip setup") { skip() }.buttonStyle(Quiet()) }
        }
    }
}

struct PhoneCard: View {
    @ObservedObject var m: Model
    var body: some View {
        if let ph = m.phones.first {
            InfoRow(icon: "iphone", label: "Phone") { value(ph) }.card()
        } else {
            VStack(alignment: .leading, spacing: S.md) {
                Text("Add your phone").font(ff(17, .semibold)).foregroundStyle(T.text)
                Text("1. Install the phone app on your Android phone.\n2. Open it and sign in to Tailscale with the same account.\n3. Tap this Mac in the list.")
                    .font(ff(14)).foregroundStyle(T.muted).lineSpacing(S.xs).fixedSize(horizontal: false, vertical: true)
                if FileManager.default.fileExists(atPath: resRoot + "/RemoteWake.apk") {
                    Button("Show phone app in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: resRoot + "/RemoteWake.apk")]) }.buttonStyle(Pill())
                }
            }.card()
        }
    }
}

struct PhoneSessionsCard: View {
    @ObservedObject var m: Model
    var body: some View {
        if FileManager.default.fileExists(atPath: resRoot + "/tmux/tmux") {
            VStack(alignment: .leading, spacing: S.md) {
                HStack(alignment: .center, spacing: S.lg) {
                    VStack(alignment: .leading, spacing: S.xs) {
                        Text("Phone sessions").font(ff(17, .semibold)).foregroundStyle(T.text)
                        Text("Phone terminals share a session with your desktop login, so Claude Code, git and other tools stay signed in, and programs keep running if the phone drops.")
                            .font(ff(14)).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: S.md)
                    Toggle("Phone sessions", isOn: Binding(get: { m.phoneOn }, set: { m.phoneSessions($0) })).labelsHidden().toggleStyle(.switch).tint(T.accent).disabled(m.busy)
                }
                if m.phoneOn { Status(word: m.tmuxRunning ? "Ready" : "Starting", color: m.tmuxRunning ? T.accent : T.warn) }
                Text("Adds a short block to ~/.zshrc (turning this off removes it). Needs this Mac to be logged in; a locked screen is fine.")
                    .font(ff(12)).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
            }.card()
        }
    }
}

struct HelpSheet: View {
    var close: () -> Void
    let tips = [("clock.arrow.circlepath", "About every 12 hours Tailscale asks your phone to approve a connection in the browser. The phone app shows an Approve button."),
                ("arrow.triangle.2.circlepath", "If the connection drops, the phone reconnects. With Phone sessions on, your programs keep running and you land back in the same session."),
                ("lock.shield", "After a power cut with FileVault on, this Mac waits for its password at startup and cannot be reached until someone unlocks it."),
                ("menubar.rectangle", "The moon icon in the menu bar stays when you close this window or quit the app.")]
    var body: some View {
        VStack(alignment: .leading, spacing: S.lg) {
            Text("Good to know").font(ff(20, .bold)).foregroundStyle(T.text)
            VStack(alignment: .leading, spacing: S.md) {
                ForEach(0..<tips.count, id: \.self) { i in
                    HStack(alignment: .top, spacing: S.md) {
                        Image(systemName: tips[i].0).font(.system(size: 15)).foregroundStyle(T.accent).frame(width: 22)
                        Text(tips[i].1).font(ff(14)).foregroundStyle(T.text).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.card()
            HStack { Spacer(); Button("Done") { close() }.buttonStyle(Pill()).keyboardShortcut(.defaultAction) }
        }.padding(S.xl).frame(width: 440).background(T.bg)
    }
}

struct MainView: View {
    @ObservedObject var m: Model
    @AppStorage("setupDone") var setupDone = false
    @State private var help = false
    var allDone: Bool { m.ready && m.tsState == "Running" && m.running }
    var body: some View {
        VStack(alignment: .leading, spacing: S.xl) {
            HStack(spacing: S.md) {
                Logo()
                Text("Remote Wake").font(ff(24, .bold)).foregroundStyle(T.text)
                Spacer()
                Button("Help") { help = true }.buttonStyle(Quiet())
            }
            if !setupDone {
                SetupView(m: m) { setupDone = true }
            } else {
                VStack(alignment: .leading, spacing: S.lg) {
                    HStack(alignment: .center, spacing: S.lg) {
                        VStack(alignment: .leading, spacing: S.xs) {
                            Text(m.heroTitle).font(ff(18, .bold)).foregroundStyle(T.text)
                            Text(m.heroText).font(ff(14)).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: S.md)
                        Toggle("Stay awake on AC", isOn: m.stayAwake).labelsHidden().toggleStyle(.switch).tint(T.accent).disabled(m.busy)
                    }
                    Status(word: m.awakeWord.0, color: m.awakeWord.1)
                }.card(tint: m.running && m.holding)
                VStack(alignment: .leading, spacing: S.md) {
                    InfoRow(icon: m.onAC ? "powerplug.fill" : "battery.50", label: "Power") { value(m.onAC ? "Plugged in" : "On battery") }
                    Divider().overlay(T.line)
                    TailscaleRow(m: m)
                }.card()
                PhoneCard(m: m)
                PhoneSessionsCard(m: m)
            }
            if let e = m.error { Text(e).font(ff(13)).foregroundStyle(T.warn).padding(S.md).frame(maxWidth: .infinity, alignment: .leading).background(T.warnBg, in: RoundedRectangle(cornerRadius: 8)) }
        }
        .padding(S.xl).frame(width: 440).background(T.bg)
        .onChange(of: allDone) { if $0 { setupDone = true } }
        .onAppear { if allDone { setupDone = true } }
        .sheet(isPresented: $help) { HelpSheet { help = false } }
    }
}

// MARK: - Menu bar panel (compact, same language)

struct MenuView: View {
    @ObservedObject var m: Model
    var body: some View {
        VStack(alignment: .leading, spacing: S.lg) {
            HStack(spacing: S.md) {
                Logo(size: 28)
                Text("Remote Wake").font(ff(16, .bold)).foregroundStyle(T.text)
                Spacer()
                Status(word: m.awakeWord.0, color: m.awakeWord.1)
            }
            if !m.ready || m.tsState != "Running" {
                Text("Finish setting up in the app.").font(ff(14)).foregroundStyle(T.muted)
            } else {
                VStack(alignment: .leading, spacing: S.md) {
                    InfoRow(icon: "moon.zzz", label: "Stay awake") { Toggle("Stay awake on AC", isOn: m.stayAwake).labelsHidden().toggleStyle(.switch).tint(T.accent).disabled(m.busy) }
                    Divider().overlay(T.line)
                    InfoRow(icon: m.onAC ? "powerplug.fill" : "battery.50", label: "Power") { value(m.onAC ? "Plugged in" : "On battery") }
                    InfoRow(icon: "network", label: "Tailscale") { value(m.tsIP) }
                    InfoRow(icon: "iphone", label: "Phone") { value(m.phones.first ?? "Not set up") }
                    if FileManager.default.fileExists(atPath: resRoot + "/tmux/tmux") {
                        InfoRow(icon: "terminal", label: "Phone sessions") { Toggle("Phone sessions", isOn: Binding(get: { m.phoneOn }, set: { m.phoneSessions($0) })).labelsHidden().toggleStyle(.switch).tint(T.accent).disabled(m.busy) }
                    }
                }.card()
            }
            if let e = m.error { Text(e).font(ff(13)).foregroundStyle(T.warn) }
            HStack {
                Button("Open Remote Wake") { NSWorkspace.shared.openApplication(at: mainAppURL, configuration: .init()) }.buttonStyle(Pill(primary: !m.ready || m.tsState != "Running"))
                Spacer()
                Button("Quit menu icon") { NSApplication.shared.terminate(nil) }.buttonStyle(Quiet())
            }
        }.padding(S.lg).frame(width: 320).background(T.bg)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        guard !isHelper else { return }
        let id = "com.guru.remotewake.menu.helper"
        try? SMAppService.loginItem(identifier: id).register()
        // register() makes launchd start the helper itself; only start it by hand if nothing runs after a moment
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
                NSWorkspace.shared.openApplication(at: mainAppURL.appendingPathComponent("Contents/Library/LoginItems/Remote Wake Menu.app"), configuration: .init())
            }
        }
    }
}

struct MenuApp: App {
    @StateObject var m = Model()
    init() { registerFonts() }
    var body: some Scene {
        MenuBarExtra("Remote Wake", systemImage: m.running ? "moon.zzz.fill" : "moon.zzz") { MenuView(m: m) }
            .menuBarExtraStyle(.window)
    }
}

struct MainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var m = Model()
    init() { registerFonts() }
    var body: some Scene {
        Window("Remote Wake", id: "main") { MainView(m: m) }.windowResizability(.contentSize)
    }
}

@main enum Entry { static func main() { if isHelper { MenuApp.main() } else { MainApp.main() } } }
