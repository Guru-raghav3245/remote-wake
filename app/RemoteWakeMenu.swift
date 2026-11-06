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
# Phone logins (SSH) join a tmux session in your desktop login, so saved logins (Keychain) work. Remote Wake keeps this on; if you delete the block it is added back the next time the app starts.
_rw="$HOME/Library/Application Support/Remote Wake/tmux"
if [[ -n $SSH_CONNECTION && -z $TMUX && -x $_rw ]] && "$_rw" -L \(tmuxSock) has-session -t phone 2>/dev/null; then "$_rw" -L \(tmuxSock) attach -t phone && exit; fi
unset _rw
\(zMark.1)
"""
let tmuxConf = """
set -g status off
set -g history-limit 20000
set -g default-terminal "screen-256color"
set -sg escape-time 10
set -g mouse on
"""
func tmux(_ a: [String]) -> Int32 { run(tmuxBin, ["-L", tmuxSock] + a).status }
func phoneEnabled() -> Bool { ((try? String(contentsOfFile: zshrc, encoding: .utf8)) ?? "").contains(zMark.0) }
func tmuxUp() -> Bool { FileManager.default.isExecutableFile(atPath: tmuxBin) && tmux(["has-session", "-t", "phone"]) == 0 }
func startTmux() {
    guard FileManager.default.isExecutableFile(atPath: tmuxBin), !tmuxUp() else { return }
    try? tmuxConf.write(toFile: phoneDir + "/tmux.conf", atomically: true, encoding: .utf8)   // so a new app version's settings apply at the next start
    let p = Process(); p.executableURL = URL(fileURLWithPath: tmuxBin)
    p.arguments = ["-u", "-L", tmuxSock, "-f", phoneDir + "/tmux.conf", "-D"]   // bare -D: with a command (even start-server) tmux daemonizes a new server in the Background session instead
    p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return }
    for _ in 0..<30 { usleep(100_000); if tmux(["new-session", "-d", "-s", "phone", "-c", NSHomeDirectory()]) == 0 { return } }   // wait for the socket
}
// Phone sessions are always on (the main point of the product): set up whenever the .zshrc block or the tmux copy is missing.
// A file lock keeps the app and the menu helper from doing it at the same time.
func ensurePhone() {
    guard FileManager.default.fileExists(atPath: resRoot + "/tmux/tmux") else { return }
    try? FileManager.default.createDirectory(atPath: phoneDir, withIntermediateDirectories: true)
    let fd = open(phoneDir + "/.setup.lock", O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { return }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return }
    if !phoneEnabled() || !FileManager.default.isExecutableFile(atPath: tmuxBin) { setPhone(true) }
    else if (try? String(contentsOfFile: phoneDir + "/tmux.conf", encoding: .utf8)) != tmuxConf {   // config changed in an update: apply it to the running server too
        try? tmuxConf.write(toFile: phoneDir + "/tmux.conf", atomically: true, encoding: .utf8)
        _ = tmux(["source-file", phoneDir + "/tmux.conf"])
    }
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

// Phone terminals run under the helper (the tmux server is its child), so macOS asks for access in the helper's name, on the Mac's screen,
// where nobody is when you are away. The helper reports whether it has Full Disk Access in a file the main app reads.
// Full Disk Access cannot be requested by code: the user adds the helper app in System Settings (the main app opens it).
let permFile = phoneDir + "/perms.json"
let permNames = ["disk": "Full Disk Access"]
func permStatus() -> [String: Bool] {
    let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)   // readable only with Full Disk Access
    if fd >= 0 { close(fd) }
    return ["disk": fd >= 0]
}
let permText = "Programs you run from your phone may need to read your files (Desktop, Documents, Downloads...), and macOS only asks on this Mac's screen. Allow it now: switch on \"Remote Wake Menu\" in the Full Disk Access list that opens."

// macOS applies Full Disk Access only to processes started after the switch was turned on, and it is the HELPER that needs it (it owns the tmux server).
// So: restart the helper at launch while the permission is still missing, and again when the app comes to the front after the user clicked Allow access.
let helperID = "com.guru.remotewake.menu.helper"
var grantClickedAt: Date?
func restartHelper() {
    NSRunningApplication.runningApplications(withBundleIdentifier: helperID).forEach { $0.terminate() }
    DispatchQueue.global().async {
        for i in 0..<40 {
            let left = NSRunningApplication.runningApplications(withBundleIdentifier: helperID)
            if left.isEmpty { break }
            if i == 20 { left.forEach { $0.forceTerminate() } }
            usleep(100_000)
        }
        DispatchQueue.main.async { NSWorkspace.shared.openApplication(at: mainAppURL.appendingPathComponent("Contents/Library/LoginItems/Remote Wake Menu.app"), configuration: .init()) }
    }
}
func diskAccessKnown() -> Bool { (((try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: permFile)))) as? [String: Bool]) ?? [:])["disk"] == true }

func tsPath() -> String? { ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"].first { FileManager.default.isExecutableFile(atPath: $0) } }

struct LogLine: Identifiable { let id: Int; let t: Date; let tag: String; let msg: String; let color: Color }

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
    @Published var perms: [String: Bool] = [:]   // written by the helper
    @Published var busy = false
    @Published var error: String?
    @Published var log: [LogLine] = []   // what happened, newest last: shown as the activity log
    var logN = 0
    var timer: Timer?
    var tmuxStarting = false
    var phoneTried: Date?   // setup is attempted at most every 5 minutes: setPhone restarts the tmux server, so it must not loop if .zshrc cannot be written

    func note(_ tag: String, _ msg: String, _ color: Color = T.accent) {
        logN += 1; log.append(LogLine(id: logN, t: Date(), tag: tag, msg: msg, color: color)); if log.count > 50 { log.removeFirst() }
    }

    init() {
        readState()
        note("app", "Remote Wake started"); note("tailscale", tsState == "Running" ? "running · \(tsIP)" : tsState, tsState == "Running" ? T.accent : T.warn)
        note("daemon", running ? "stay awake on" : "stay awake off", running ? T.accent : T.danger)
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in Task { @MainActor in self.refresh() } } }

    // Reads the state, then logs whatever changed since last time (so the log follows real events, not guesses).
    func refresh() {
        let o = (running, holding, onAC, tsState, phones.first, phoneOn, tmuxRunning)
        readState()
        if o.0 != running { running ? note("daemon", "stay awake on · caffeinate -s") : note("daemon", "stay awake off · Mac may sleep", T.danger) }
        if running && o.1 != holding { holding ? note("power", "sleep blocked") : note("power", "waiting for AC · sleeps on battery", T.warn) }
        if o.2 != onAC { note("power", onAC ? "AC connected" : "on battery", onAC ? T.accent : T.warn) }
        if o.3 != tsState { note("tailscale", tsState == "Running" ? "running · \(tsIP)" : tsState, tsState == "Running" ? T.accent : T.warn) }
        if o.4 != phones.first, let ph = phones.first { let on = !ph.hasSuffix("(offline)"); note("phone", ph.replacingOccurrences(of: " (offline)", with: "") + (on ? " online" : " offline"), on ? T.accent : T.warn) }
        if o.5 != phoneOn { note("session", phoneOn ? "phone sessions on" : "phone sessions off", phoneOn ? T.accent : T.warn) }
        if phoneOn && o.6 != tmuxRunning { note("session", tmuxRunning ? "phone session ready" : "phone session starting…", tmuxRunning ? T.accent : T.warn) }
    }

    func readState() {
        installed = FileManager.default.fileExists(atPath: plist)
        running = run("/bin/launchctl", ["print", "system/\(label)"]).status == 0
        onAC = run("/usr/bin/pmset", ["-g", "batt"]).out.contains("AC Power")
        holding = run("/usr/bin/pmset", ["-g", "assertions"]).out.range(of: #"PreventSystemSleep\s+1"#, options: .regularExpression) != nil
        if isHelper {
            try? FileManager.default.createDirectory(atPath: phoneDir, withIntermediateDirectories: true)
            let was = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: permFile)))) as? [String: Bool])?["disk"], now = permStatus()
            try? JSONSerialization.data(withJSONObject: now).write(to: URL(fileURLWithPath: permFile))
            // the tmux server was started before the grant, so programs run from the phone would still be denied: start a new one (the next refresh does)
            if was == false && now["disk"] == true { _ = tmux(["kill-server"]); note("access", "Full Disk Access is on · phone session restarted so it can read your files") }
        }
        perms = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: permFile)))) as? [String: Bool] ?? [:]
        phoneOn = phoneEnabled(); tmuxRunning = phoneOn && tmuxUp()
        if phoneTried == nil || (!phoneOn && Date().timeIntervalSince(phoneTried!) > 300) {
            phoneTried = Date()
            Task.detached { ensurePhone(); await MainActor.run { self.refresh() } }
        }
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
        busy = true; note("you", on ? "turning stay awake on…" : "turning stay awake off…", T.pink)
        Task.detached {
            func go() -> Bool { cmds.allSatisfy { run("/usr/bin/sudo", ["-n", "/bin/launchctl"] + $0).status == 0 } }
            var ok = go()
            // no rule yet (daemon installed by hand): one admin prompt creates it, then retry
            if !ok && !FileManager.default.fileExists(atPath: sudoersPath) && rootInstall() { ok = go() }
            let done = ok
            await MainActor.run { self.busy = false; self.error = done ? nil : "Toggle cancelled or failed"; if !done { self.note("daemon", "toggle cancelled or failed", T.danger) }; self.refresh() }
        }
    }

    func connect() {
        guard let ts = tsPath() else { return }
        note("you", "connecting Tailscale…", T.pink)
        let host = (Host.current().localizedName ?? "mac").lowercased().replacingOccurrences(of: "['\u{2019}]", with: "", options: .regularExpression).replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        let p = Process(); p.executableURL = URL(fileURLWithPath: ts)
        p.arguments = ["up", "--ssh", "--hostname=\(host)"]   // blocks until sign-in; ends by itself
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    func install() {
        busy = true; note("you", "installing Tailscale and the stay-awake service…", T.pink)
        Task.detached {
            let ok = rootInstall()
            await MainActor.run { self.busy = false; self.error = ok ? nil : "Install cancelled or failed"; self.note("install", ok ? "done" : "cancelled or failed", ok ? T.accent : T.danger); self.refresh() }
        }
    }
}


// MARK: - Terminal-bloom design language (see design/tokens.md and design/rose-style.html). Dark only; spacing uses only S.*.
import CoreText

extension Color { init(hex: UInt32) { self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255) } }
enum T {
    static let bg = Color(hex: 0x0B0B0E), card = Color(hex: 0x121217), soft = Color(hex: 0x1A1A21), line = Color(hex: 0x23232B)
    static let text = Color(hex: 0xE8E8EC), muted = Color(hex: 0x8A8A98), dim = Color(hex: 0x6B6B78)   // muted passes 4.5:1 on card; dim is for decoration only
    static let accent = Color(hex: 0x7BE0B0), onAccent = Color(hex: 0x06130D), pink = Color(hex: 0xFF6AC1)
    static let warn = Color(hex: 0xE3B341), warnBg = Color(hex: 0x2B251C), danger = Color(hex: 0xE5484D), dangerBg = Color(hex: 0x2B181D)
    static let stage = Color(hex: 0x050507)
}
enum S { static let xs: CGFloat = 4, sm: CGFloat = 8, md: CGFloat = 12, lg: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32 }
func ff(_ size: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: size, weight: w, design: .monospaced) }
var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

struct Card: ViewModifier {
    var tint = false
    func body(content: Content) -> some View {
        content.padding(S.lg).frame(maxWidth: .infinity, alignment: .leading)
            .background(tint ? T.soft : T.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(T.line, lineWidth: 1))
    }
}
extension View { func card(tint: Bool = false) -> some View { modifier(Card(tint: tint)) } }

// The button: a frame of characters. When it is the action the user must take, the border ripples (shaded characters); otherwise it is a still, dim frame.
struct AsciiButton: View {
    let title: String, primary: Bool, action: () -> Void
    @Environment(\.isEnabled) var enabled
    init(_ title: String, primary: Bool = true, action: @escaping () -> Void) { self.title = title; self.primary = primary; self.action = action }
    static let ramp = Array(" .:-=+*#%@")
    func art(_ t: Double, live: Bool) -> String {
        let w = title.count + 4
        let edge = String((0..<w).map { i in live ? Self.ramp[Int(4 + (0.5 + 0.5 * sin(Double(i) * 0.5 - t * 3)) * 5)] : "-" })
        return "+\(edge)+\n|  \(title)  |\n+\(edge)+"
    }
    var body: some View {
        let live = primary && enabled && !reduceMotion
        Button(action: action) {
            TimelineView(.animation(minimumInterval: 0.1, paused: !live)) { tl in
                Text(art(tl.date.timeIntervalSinceReferenceDate, live: live))
                    .font(ff(13, .bold)).lineSpacing(0).fixedSize()
                    .foregroundStyle(primary ? T.accent : T.muted)
                    .padding(.horizontal, S.sm).padding(.vertical, S.xs)
                    .background(primary ? T.accent.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                    .shadow(color: primary && enabled ? T.accent.opacity(0.45) : .clear, radius: 8)
            }
        }
        .buttonStyle(.plain).opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(title)
    }
}
struct Quiet: ButtonStyle {
    func makeBody(configuration c: Configuration) -> some View { c.label.font(ff(13, .medium)).foregroundStyle(T.muted).opacity(c.isPressed ? 0.6 : 1) }
}

struct Status: View {   // the one way status is shown everywhere: glowing dot + word
    let word: String, color: Color
    var body: some View { HStack(spacing: S.sm) { Circle().fill(color).frame(width: 8, height: 8).shadow(color: color, radius: 4); Text(word).font(ff(13, .semibold)).foregroundStyle(color) } }
}

struct InfoRow<Trailing: View>: View {
    let label: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: S.md) {
            Text(label).font(ff(13)).foregroundStyle(T.muted).frame(width: 104, alignment: .leading)
            trailing
            Spacer(minLength: 0)
        }.frame(minHeight: 28)
    }
}
func value(_ s: String) -> some View { Text(s).font(ff(13)).foregroundStyle(T.text).lineLimit(1) }

// ASCII word: the text is rasterised into a character grid, then each filled cell is drawn as a character whose density follows a light sweeping across.
struct WordGrid { let cols: Int, rows: Int, a: [UInt8] }
func makeWord(_ word: String, cols: Int, rows: Int) -> WordGrid {
    let chars = Array(word), gap: CGFloat = 2, xs: CGFloat = 1.23   // cells are 7 tall by 5.7 wide: draw letters wider so they look natural on screen
    func font(_ s: CGFloat, _ c: Character = "A") -> NSFont { NSFont.systemFont(ofSize: s, weight: c == "S" ? .heavy : .black) }   // S one step lighter: at .black its two curves close up into a blob
    func widths(_ s: CGFloat) -> [CGFloat] { chars.map { NSAttributedString(string: String($0), attributes: [.font: font(s, $0)]).size().width * xs } }
    var fs = CGFloat(rows) * 1.25, ws = widths(fs)
    func total() -> CGFloat { ws.reduce(0, +) + gap * CGFloat(chars.count - 1) }
    while total() > CGFloat(cols) * 0.92 { fs -= 2; ws = widths(fs) }
    var data = [UInt8](repeating: 0, count: cols * rows)
    var spans: [(Character, CGFloat, CGFloat)] = []
    data.withUnsafeMutableBytes { buf in
        guard let ctx = CGContext(data: buf.baseAddress, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: cols, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let f = font(fs), y = (CGFloat(rows) - f.capHeight) / 2 + f.descender
        var x = (CGFloat(cols) - total()) / 2
        for (i, c) in chars.enumerated() {
            ctx.saveGState(); ctx.translateBy(x: x, y: 0); ctx.scaleBy(x: xs, y: 1)
            NSAttributedString(string: String(c), attributes: [.font: font(fs, c), .foregroundColor: NSColor.white]).draw(at: NSPoint(x: 0, y: y))
            ctx.restoreGState()
            spans.append((c, x, ws[i])); x += ws[i] + gap
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    // A and W are mirror-symmetric: copy the left half onto the right so grid rounding cannot make the two sides differ
    for (c, x0, w0) in spans where c == "A" || c == "W" {
        let m2 = Int((2 * (x0 + w0 / 2)).rounded()), lo = Int(floor(x0)), hi = Int(ceil(x0 + w0))
        for r in 0..<rows { var k = (m2 + 1) / 2; while k < hi && k < cols { let src = m2 - 1 - k; data[r * cols + k] = src >= lo && src >= 0 ? data[r * cols + src] : 0; k += 1 } }
    }
    return WordGrid(cols: cols, rows: rows, a: data)
}
@MainActor var wordCache: [String: WordGrid] = [:]
@MainActor func word(_ w: String) -> WordGrid { if let g = wordCache[w] { return g }; let g = makeWord(w, cols: 88, rows: 12); wordCache[w] = g; return g }   // 12 rows: with fewer, the three bars of E and the curves of S merged into blocks

struct AsciiWord: View {
    let grid: WordGrid, color: Color
    static let cw: CGFloat = 5.7, ch: CGFloat = 7
    var body: some View {
        let live = !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !live)) { tl in
            Canvas { ctx, size in
                let t = live ? tl.date.timeIntervalSinceReferenceDate : 8
                var seed: UInt64 = 7
                func rnd() -> CGFloat { seed = (seed &* 16807) % 2147483647; return CGFloat(seed) / 2147483647 }
                for i in 0..<60 {
                    let x = rnd() * size.width, y = rnd() * size.height
                    ctx.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.white.opacity(0.4)))
                    if i % 12 == 0 {
                        let k = 0.5 + 0.5 * sin(t * 2 + Double(i)), p = Path { p in p.move(to: CGPoint(x: x - 6, y: y)); p.addLine(to: CGPoint(x: x + 6, y: y)); p.move(to: CGPoint(x: x, y: y - 6)); p.addLine(to: CGPoint(x: x, y: y + 6)) }
                        ctx.stroke(p, with: .color(.white.opacity(0.3 * k)), lineWidth: 1)
                    }
                }
                let ramp = Array(" .:-=+*#%@")
                let glyphs = ramp.map { ctx.resolve(Text(String($0)).font(.system(size: 9.5, weight: .regular, design: .monospaced)).foregroundColor(color)) }
                let ox = (size.width - CGFloat(grid.cols) * Self.cw) / 2, oy = (size.height - CGFloat(grid.rows) * Self.ch) / 2
                let sweep = (t * 0.12).truncatingRemainder(dividingBy: 1.6) - 0.3
                for r in 0..<grid.rows { for c in 0..<grid.cols {
                    let a = Double(grid.a[r * grid.cols + c]) / 255
                    if a < (r == 0 || r == grid.rows - 1 ? 0.45 : 0.15) { continue }   // faint overshoot on the edge rows reads as stray characters
                    let lit = max(0, 1 - abs(Double(c) / Double(grid.cols) - sweep) * 4)
                    let b = min(1, 0.5 + Double(r) / Double(grid.rows) * 0.15 + lit * 0.4)
                    ctx.opacity = 0.45 + 0.55 * b
                    ctx.draw(glyphs[min(9, Int(b * 10))], at: CGPoint(x: ox + CGFloat(c) * Self.cw, y: oy + CGFloat(r) * Self.ch), anchor: .topLeading)
                } }
            }
        }
          .frame(height: 120).frame(maxWidth: .infinity).background(T.stage, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(T.line, lineWidth: 1))
        .accessibilityLabel("Status")
    }
}

// [phone] ───●─── [mac awake]: the dot moves while the phone can reach an awake Mac.
struct PathLine: View {
    let live: Bool, phoneOnline: Bool, macWord: String
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !live || reduceMotion)) { tl in
            let n = 30, p = live ? Int(tl.date.timeIntervalSinceReferenceDate / 0.12) % n : -1
            let line = (0..<n).map { $0 == p ? "●" : (live ? "─" : "╌") }.joined()
            HStack(spacing: 0) {
                Text("[phone] ").foregroundStyle(phoneOnline ? T.muted : T.danger)
                Text(line).foregroundStyle(live ? T.accent : T.danger)
                Text(" [mac \(macWord)]").foregroundStyle(live ? T.accent : T.danger)
            }.font(ff(11)).lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}

struct Logo: View {
    var size: CGFloat = 36
    var body: some View {
        if let img = NSImage(contentsOfFile: resRoot + "/logo.png") { Image(nsImage: img).resizable().interpolation(.high).frame(width: size, height: size).accessibilityHidden(true) }
    }
}

extension Model {
    var needsPerms: Bool { FileManager.default.fileExists(atPath: resRoot + "/tmux/tmux") }
    var permsOK: Bool { !needsPerms || (!perms.isEmpty && !perms.values.contains(false)) }
    var permsMissing: String { permNames.filter { perms[$0.key] != true }.map { $0.value }.sorted().joined(separator: ", ") }
    func grantAccess() {
        grantClickedAt = Date()
        note("you", "opened Full Disk Access settings", T.pink)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
    var ready: Bool { installed && tsState != "not installed" }
    var awakeWord: (String, Color) { !running ? ("Off", T.danger) : (holding ? ("Awake", T.accent) : ("Waiting for AC", T.warn)) }
    var heroTitle: String { !running ? "Stay awake is off" : (holding ? "Your Mac is staying awake" : "Ready, but on battery") }
    var heroText: String { !running ? "Your Mac sleeps normally." : (holding ? "Safe to close the lid while it is plugged in." : "Plug in to keep it awake. On battery it sleeps normally.") }
    var stayAwake: Binding<Bool> { Binding(get: { self.running }, set: { _ in self.toggle() }) }
}

struct TailscaleRow: View {
    @ObservedObject var m: Model
    var body: some View {
        InfoRow(label: "Tailscale") {
            if m.tsState == "Running" { Status(word: "running", color: T.accent); value(m.tsIP) }
            else if m.tsState == "NeedsLogin", let u = m.authURL, let url = URL(string: u) { AsciiButton("SIGN IN") { NSWorkspace.shared.open(url) } }
            else { AsciiButton("CONNECT") { m.connect() } }
        }
    }
}

// MARK: - Main window

struct StepRow<A: View>: View {
    let n: Int, title: String, text: String, done: Bool, active: Bool
    @ViewBuilder var action: A
    var body: some View {
        HStack(alignment: .top, spacing: S.md) {
            Text(done ? "[x]" : (active ? "[>]" : "[ ]")).font(ff(14, .bold)).foregroundStyle(done ? T.accent : (active ? T.pink : T.dim))
                .frame(width: 32, height: 28, alignment: .leading).accessibilityLabel(done ? "Done" : (active ? "Current step" : "Not yet"))
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
    var done: [Bool] { [m.ready, m.tsState == "Running", m.running] + (m.needsPerms ? [m.permsOK] : []) }
    var cur: Int { done.firstIndex(of: false) ?? -1 }
    var body: some View {
        VStack(alignment: .leading, spacing: S.lg) {
            VStack(alignment: .leading, spacing: S.xs) {
                Text("Let's get you set up").font(ff(20, .bold)).foregroundStyle(T.text)
                Text("A few quick steps. Each one ticks itself when it's done.").font(ff(14)).foregroundStyle(T.muted)
            }
            VStack(alignment: .leading, spacing: S.lg) {
                StepRow(n: 1, title: "Install", text: "Adds Tailscale and the stay-awake service. You'll be asked for your Mac password once.", done: done[0], active: cur == 0) {
                    AsciiButton("INSTALL") { m.install() }.disabled(m.busy)
                }
                StepRow(n: 2, title: "Connect Tailscale", text: "Sign in with the account you'll also use on your phone.", done: done[1], active: cur == 1) {
                    if m.tsState == "NeedsLogin", let u = m.authURL, let url = URL(string: u) { AsciiButton("SIGN IN TO TAILSCALE") { NSWorkspace.shared.open(url) } }
                    else { AsciiButton("CONNECT TAILSCALE") { m.connect() } }
                }
                StepRow(n: 3, title: "Stay awake on AC", text: "Turn this on. Keep the Mac plugged in; on battery it sleeps normally.", done: done[2], active: cur == 2) {
                    AsciiButton("KEEP MY MAC AWAKE") { m.toggle() }.disabled(m.busy)
                }
                if m.needsPerms {
                    StepRow(n: 4, title: "Allow phone access", text: permText, done: m.permsOK, active: cur == 3) {
                        AsciiButton("ALLOW ACCESS") { m.grantAccess() }
                    }
                }
            }.card()
            HStack { Spacer(); Button("Skip setup") { skip() }.buttonStyle(Quiet()) }
        }
    }
}

@MainActor @ViewBuilder func phoneStatus(_ m: Model) -> some View {
    let ph = m.phones.first, online = ph != nil && !(ph!.hasSuffix("(offline)"))
    HStack(spacing: S.md) { Status(word: ph == nil ? "none" : (online ? "online" : "offline"), color: ph == nil ? T.muted : (online ? T.accent : T.danger)); if let ph { value(ph.replacingOccurrences(of: " (offline)", with: "")) } }
}

// The one thing that matters: is the Mac staying awake? A big ASCII word, the path to the phone, and the action when action is needed.
struct Hero: View {
    @ObservedObject var m: Model
    var info: (String, Color) { !m.running ? ("ASLEEP", T.danger) : (m.holding ? ("AWAKE", T.accent) : ("PLUG IN", T.warn)) }
    var phoneOnline: Bool { m.phones.first.map { !$0.hasSuffix("(offline)") } ?? false }
    var body: some View {
        VStack(alignment: .leading, spacing: S.md) {
            AsciiWord(grid: word(info.0), color: info.1)
            PathLine(live: m.running && m.holding && phoneOnline, phoneOnline: phoneOnline, macWord: m.running && m.holding ? "awake" : "asleep")
            HStack(alignment: .center, spacing: S.lg) {
                if !m.running { AsciiButton("KEEP MY MAC AWAKE") { m.toggle() }.disabled(m.busy) }
                else { AsciiButton("STOP STAYING AWAKE", primary: false) { m.toggle() }.disabled(m.busy) }
                VStack(alignment: .leading, spacing: S.xs) {
                    if !m.running { Text("! Action needed: your phone cannot reach this Mac while it sleeps.").font(ff(12, .semibold)).foregroundStyle(T.danger) }
                    Text(m.heroText).font(ff(12)).foregroundStyle(T.muted)
                }.fixedSize(horizontal: false, vertical: true)
            }
        }.card()
    }
}

// Readouts stacked in the right column: power, tailscale, phone, phone sessions.
struct Cell<C: View>: View {
    let label: String
    @ViewBuilder var content: C
    var body: some View { VStack(alignment: .leading, spacing: S.xs) { Text(label).font(ff(11)).foregroundStyle(T.muted); content }.padding(S.md).frame(maxWidth: .infinity, alignment: .leading) }
}
func small(_ s: String) -> some View { Text(s).font(ff(12)).foregroundStyle(T.text).lineLimit(1).truncationMode(.tail) }
struct Readouts: View {
    @ObservedObject var m: Model
    var hasTmux: Bool { FileManager.default.fileExists(atPath: resRoot + "/tmux/tmux") }
    var line: some View { Rectangle().fill(T.line).frame(height: 1) }
    var body: some View {
        let ph = m.phones.first, phOn = ph != nil && !(ph!.hasSuffix("(offline)"))
        VStack(alignment: .leading, spacing: 0) {
            Cell(label: "power") { HStack(spacing: S.sm) { Status(word: m.onAC ? "AC" : "battery", color: m.onAC ? T.accent : T.warn); small(m.onAC ? "plugged in" : "sleeps normally") } }
            line
            Cell(label: "tailscale") {
                if m.tsState == "Running" { HStack(spacing: S.sm) { Status(word: "running", color: T.accent); small(m.tsIP) } }
                else if m.tsState == "NeedsLogin", let u = m.authURL, let url = URL(string: u) { Button("Sign in →") { NSWorkspace.shared.open(url) }.buttonStyle(Quiet()) }
                else { Button("Connect →") { m.connect() }.buttonStyle(Quiet()) }
            }
            line
            Cell(label: "phone") {
                HStack(spacing: S.sm) {
                    Status(word: ph == nil ? "none" : (phOn ? "online" : "offline"), color: ph == nil ? T.muted : (phOn ? T.accent : T.danger))
                    small(ph?.replacingOccurrences(of: " (offline)", with: "") ?? "not set up")
                }
            }
            if hasTmux {
                line
                Cell(label: "phone sessions") {
                    HStack(spacing: S.sm) { Status(word: m.phoneOn && m.tmuxRunning ? "ready" : "starting", color: m.phoneOn && m.tmuxRunning ? T.accent : T.warn); small("always on") }
                }
            }
        }
        .background(T.card, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(T.line, lineWidth: 1))
    }
}

// Activity log: the last six real events (state changes and the user's own actions), newest highlighted like the current line in an editor.
let logTime: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
struct LogView: View {
    @ObservedObject var m: Model
    var body: some View {
        let rows = Array(m.log.suffix(6))
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { l in
                let cur = l.id == rows.last?.id
                HStack(spacing: S.sm) {
                    Text(String(format: "%3d", l.id)).foregroundStyle(T.dim)
                    Text(logTime.string(from: l.t)).foregroundStyle(T.dim)
                    Text(l.tag).foregroundStyle(l.color).frame(width: 64, alignment: .leading)
                    Text(l.msg).foregroundStyle(T.text).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(ff(11.5)).padding(.horizontal, S.md).frame(height: 22)
                .background(cur ? T.pink.opacity(0.10) : Color.clear)
                .overlay(alignment: .leading) { if cur { Rectangle().fill(T.pink).frame(width: 2) } }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, S.sm).frame(height: 6 * 22 + 2 * S.sm, alignment: .top).frame(maxWidth: .infinity, alignment: .leading)
        .background(T.card, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(T.line, lineWidth: 1))
        .accessibilityLabel("Activity log")
    }
}

struct PhoneCard: View {
    @ObservedObject var m: Model
    var body: some View {
        if m.phones.first == nil {
            VStack(alignment: .leading, spacing: S.md) {
                Text("Add your phone").font(ff(17, .semibold)).foregroundStyle(T.text)
                Text("1. Install the phone app on your Android phone.\n2. Open it and sign in to Tailscale with the same account.\n3. Tap this Mac in the list.")
                    .font(ff(14)).foregroundStyle(T.muted).lineSpacing(S.xs).fixedSize(horizontal: false, vertical: true)
                if FileManager.default.fileExists(atPath: resRoot + "/RemoteWake.apk") {
                    AsciiButton("SHOW PHONE APP IN FINDER") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: resRoot + "/RemoteWake.apk")]) }
                }
            }.card()
        }
    }
}

struct PermsCard: View {
    @ObservedObject var m: Model
    var body: some View {
        if m.needsPerms && !m.permsOK {
            VStack(alignment: .leading, spacing: S.md) {
                Text("Allow phone access").font(ff(17, .semibold)).foregroundStyle(T.text)
                Text(permText).font(ff(14)).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
                if !m.perms.isEmpty { Status(word: "Still needed: " + m.permsMissing, color: T.warn) }
                AsciiButton("ALLOW ACCESS") { m.grantAccess() }
            }.card()
        }
    }
}

struct HelpSheet: View {
    var close: () -> Void
    let tips = [("clock.arrow.circlepath", "About every 12 hours Tailscale asks your phone to approve a connection in the browser. The phone app shows an Approve button."),
                ("arrow.triangle.2.circlepath", "If the connection drops, the phone reconnects. Phone sessions are always on, so your programs keep running and you land back in the same session."),
                ("lock.shield", "After a power cut with FileVault on, this Mac waits for its password at startup and cannot be reached until someone unlocks it."),
                ("terminal", "Phone sessions: phone terminals share a session with your desktop login, so Claude Code, git and other tools stay signed in, and programs keep running if the phone drops. Remote Wake keeps it on: it adds a short, marked block to ~/.zshrc (delete the block and it is added back at the next start). Needs this Mac to be logged in (a locked screen is fine)."),
                ("menubar.rectangle", "The Remote Wake icon in the menu bar stays when you close this window or quit the app.")]
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
            HStack { Spacer(); AsciiButton("DONE") { close() }.keyboardShortcut(.defaultAction) }
            Text("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")).font(ff(9)).foregroundStyle(T.text.opacity(0.4)).frame(maxWidth: .infinity)
        }.padding(S.xl).frame(width: 440).background(T.bg)
    }
}

struct MainView: View {
    @ObservedObject var m: Model
    @AppStorage("setupDone") var setupDone = false
    @State private var help = false
    var allDone: Bool { m.ready && m.tsState == "Running" && m.running && m.permsOK }
    var body: some View {
        VStack(alignment: .leading, spacing: S.xl) {
            HStack(spacing: S.md) {
                Logo()
                Text("Remote Wake").font(ff(22, .bold)).foregroundStyle(T.text)
                Spacer()
                Button("Help") { help = true }.buttonStyle(Quiet())
            }
            if !setupDone {
                SetupView(m: m) { setupDone = true }.frame(maxWidth: 560).frame(maxWidth: .infinity)
            } else {
                HStack(alignment: .top, spacing: S.lg) {
                    VStack(spacing: S.lg) { Hero(m: m); PhoneCard(m: m); PermsCard(m: m) }.frame(width: 540)
                    Readouts(m: m).frame(width: 280)
                }
                LogView(m: m)
            }
            if let e = m.error { Text(e).font(ff(13)).foregroundStyle(T.warn).padding(S.md).frame(maxWidth: .infinity, alignment: .leading).background(T.warnBg, in: RoundedRectangle(cornerRadius: 8)) }
        }
        .padding(S.xl).frame(width: 884).background(T.bg)
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
                    InfoRow(label: "Stay awake") { Toggle("Stay awake on AC", isOn: m.stayAwake).labelsHidden().toggleStyle(.switch).tint(T.accent).disabled(m.busy) }
                    Divider().overlay(T.line)
                    InfoRow(label: "Power") { value(m.onAC ? "Plugged in" : "On battery") }
                    InfoRow(label: "Tailscale") { value(m.tsIP) }
                    InfoRow(label: "Phone") { value(m.phones.first ?? "Not set up") }
                    if FileManager.default.fileExists(atPath: resRoot + "/tmux/tmux") {
                        InfoRow(label: "Phone sessions") { Status(word: m.phoneOn && m.tmuxRunning ? "ready" : "starting", color: m.phoneOn && m.tmuxRunning ? T.accent : T.warn) }
                    }
                }.card()
            }
            if let e = m.error { Text(e).font(ff(13)).foregroundStyle(T.warn) }
            HStack {
                AsciiButton("OPEN REMOTE WAKE", primary: !m.ready || m.tsState != "Running") { NSWorkspace.shared.openApplication(at: mainAppURL, configuration: .init()) }
                Spacer()
                Button("Quit menu icon") { NSApplication.shared.terminate(nil) }.buttonStyle(Quiet())
            }
        }.padding(S.lg).frame(width: 320).background(T.bg)
    }
}

// MARK: - Menu bar icon: the logo reduced to solid shapes (chevron, underscore, Z) as a template image, so macOS tints it for light/dark bars.
// Dimmed when stay-awake is off.
func menuIcon(on: Bool) -> NSImage {
    let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
        let sz = r.width, a: CGFloat = on ? 1 : 0.4
        NSColor.black.withAlphaComponent(a).setFill(); NSColor.black.withAlphaComponent(a).setStroke()
        let ch = NSBezierPath(); ch.lineWidth = sz * 0.1; ch.lineCapStyle = .round; ch.lineJoinStyle = .round
        ch.move(to: NSPoint(x: sz * 0.2, y: sz * 0.5)); ch.line(to: NSPoint(x: sz * 0.4, y: sz * 0.35)); ch.line(to: NSPoint(x: sz * 0.2, y: sz * 0.2)); ch.stroke()
        NSRect(x: sz * 0.48, y: sz * 0.15, width: sz * 0.24, height: sz * 0.08).fill()
        func glyph(_ t: String, _ size: CGFloat, _ x: CGFloat, topFrac: CGFloat) {
            let at = NSAttributedString(string: t, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .black), .foregroundColor: NSColor.black.withAlphaComponent(a)])
            at.draw(at: NSPoint(x: x, y: sz * (1 - topFrac) - at.size().height))
        }
        glyph("Z", sz * 0.42, sz * 0.55, topFrac: 0.04); glyph("z", sz * 0.26, sz * 0.36, topFrac: 0.26)
        return true
    }
    img.isTemplate = true
    return img
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        guard !isHelper else { return }
        let id = helperID
        try? SMAppService.loginItem(identifier: id).register()
        // register() makes launchd start the helper itself; only start it by hand if nothing runs after a moment
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
                NSWorkspace.shared.openApplication(at: mainAppURL.appendingPathComponent("Contents/Library/LoginItems/Remote Wake Menu.app"), configuration: .init())
            } else if !diskAccessKnown() && FileManager.default.fileExists(atPath: resRoot + "/tmux/tmux") { restartHelper() }   // quit and reopen after granting: the old helper still has the old answer
        }
    }
    var lastRestart = Date.distantPast
    func applicationDidBecomeActive(_ n: Notification) {   // back from System Settings after clicking Allow access
        guard !isHelper, let t = grantClickedAt, Date().timeIntervalSince(t) < 600, !diskAccessKnown(), Date().timeIntervalSince(lastRestart) > 15 else { return }
        lastRestart = Date(); restartHelper()
    }
}

struct MenuApp: App {
    @StateObject var m = Model()
    var body: some Scene {
        MenuBarExtra { MenuView(m: m).preferredColorScheme(.dark) } label: { Image(nsImage: menuIcon(on: m.running)).accessibilityLabel("Remote Wake") }
            .menuBarExtraStyle(.window)
    }
}

struct MainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var m = Model()
    var body: some Scene {
        Window("Remote Wake", id: "main") { MainView(m: m).preferredColorScheme(.dark) }.windowResizability(.contentSize)
    }
}

@main enum Entry { static func main() { if isHelper { MenuApp.main() } else { MainApp.main() } } }
