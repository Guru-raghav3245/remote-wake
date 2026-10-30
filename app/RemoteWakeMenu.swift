import SwiftUI

let label = "com.guru.wakeagent"
let plist = "/Library/LaunchDaemons/\(label).plist"
let logPath = "/var/log/wakeagent.log"
let serviceURL = "https://remote-wake.vercel.app"

struct Device: Decodable {
    var last_checkin: Double?
    var power: String?
    var battery: Int?
    var interval_s: Int?
    var paused: Bool?
    var no_recent_checkin: Bool?
    var paired: Bool?
}

func sh(_ cmd: String, args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cmd)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
    return p.terminationStatus
}

@MainActor final class Model: ObservableObject {
    @Published var running = false
    @Published var device: Device?
    @Published var error: String?
    @Published var logLines: [String] = []
    @Published var sleeps = 0
    @Published var stays = 0
    @Published var busy = false
    @Published var needsSetup = false
    @Published var code: String?
    var timer: Timer?
    var pairedBefore: Bool?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in Task { @MainActor in self.refresh() } }
    }

    func refresh() {
        needsSetup = !FileManager.default.fileExists(atPath: plist) || !FileManager.default.fileExists(atPath: deviceFile)
        running = sh("/bin/launchctl", args: ["print", "system/\(label)"]) == 0
        readLog()
        Task { await fetchDevice() }
    }

    func readLog() {
        guard let h = FileHandle(forReadingAtPath: logPath) else { logLines = []; return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 65536 ? size - 65536 : 0)
        let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        let lines = text.split(separator: "\n").map(String.init)
        let today = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        let todays = lines.filter { $0.hasPrefix(today) }
        sleeps = todays.filter { $0.contains("sleeping,") }.count
        stays = todays.filter { $0.contains("staying awake") }.count
        logLines = Array(lines.suffix(8))
    }

    func fetchDevice() async {
        let f = (NSHomeDirectory() as NSString).appendingPathComponent(".remote-wake-device.json")
        guard let d = FileManager.default.contents(atPath: f),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let tok = j["mac_token"] as? String,
              let url = URL(string: serviceURL + "/device") else { error = "No ~/.remote-wake-device.json"; return }
        var r = URLRequest(url: url, timeoutInterval: 10)
        r.setValue("Bearer " + tok, forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: r)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { error = "Server said \((resp as? HTTPURLResponse)?.statusCode ?? 0)"; return }
            device = try JSONDecoder().decode(Device.self, from: data); error = nil
            if device?.paired == true && code != nil && pairedBefore == false { code = nil }
            pairedBefore = device?.paired
        } catch { self.error = error.localizedDescription }
    }

    // First-time setup: register this Mac (open, rate limited), install the agent with one password prompt, show the phone pairing code.
    func setup(name: String) {
        busy = true; error = nil
        Task {
            defer { busy = false; refresh() }
            do {
                var r = URLRequest(url: URL(string: serviceURL + "/register")!, timeoutInterval: 20)
                r.httpMethod = "POST"
                r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                r.httpBody = try JSONSerialization.data(withJSONObject: ["name": name])
                let (data, resp) = try await URLSession.shared.data(for: r)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let mac = j["mac_token"] as? String else {
                    error = status == 503 ? "Remote Wake is full right now" : status == 429 ? "Too many attempts, try again later" : "Server said \(status)"; return }
                guard await Task.detached(operation: { rootInstall(macToken: mac) }).value else { error = "Install cancelled or failed"; return }
                FileManager.default.createFile(atPath: deviceFile, contents: data, attributes: [.posixPermissions: 0o600])
                code = j["code"] as? String
            } catch { self.error = error.localizedDescription }
        }
    }

    func newCode() {
        guard let tok = macToken(), let url = URL(string: serviceURL + "/pair-code") else { return }
        var r = URLRequest(url: url, timeoutInterval: 10)
        r.httpMethod = "POST"; r.setValue("Bearer " + tok, forHTTPHeaderField: "Authorization")
        Task {
            guard let (d, _) = try? await URLSession.shared.data(for: r),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { error = "Could not get a code"; return }
            code = j["code"] as? String
        }
    }

    // Root is needed for launchctl. First use asks for the admin password once and installs a sudoers rule
    // that allows exactly these four launchctl commands without a password; after that toggling is silent.
    var commands: [[String]] {
        running
            ? [["disable", "system/\(label)"], ["bootout", "system/\(label)"]]
            : [["enable", "system/\(label)"], ["bootstrap", "system", plist]]
    }

    func toggle() {
        let cmds = commands
        busy = true
        Task.detached {
            func run() -> Bool { cmds.allSatisfy { sh("/usr/bin/sudo", args: ["-n", "/bin/launchctl"] + $0) == 0 } }
            var ok = run()
            if !ok && !FileManager.default.fileExists(atPath: sudoersPath) && installRule() { ok = run() }
            let done = ok
            await MainActor.run { self.busy = false; if !done { self.error = "Toggle cancelled or failed" }; self.refresh() }
        }
    }
}

let sudoersPath = "/etc/sudoers.d/remotewake"
func sudoersLine() -> String {
    let allowed = [["disable", "system/\(label)"], ["bootout", "system/\(label)"],
                   ["enable", "system/\(label)"], ["bootstrap", "system", plist]]
        .map { "/bin/launchctl " + $0.joined(separator: " ") }.joined(separator: ", ")
    return "\(NSUserName()) ALL=(root) NOPASSWD: \(allowed)"
}
func macToken() -> String? {
    guard let d = FileManager.default.contents(atPath: deviceFile),
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
    return j["mac_token"] as? String
}
let deviceFile = (NSHomeDirectory() as NSString).appendingPathComponent(".remote-wake-device.json")

// One admin-password prompt: installs the agent from the app bundle and the sudoers rule.
// The Mac token goes into a private temp script (not onto a command line) that is deleted afterwards.
func rootInstall(macToken: String) -> Bool {
    let agentDir = Bundle.main.resourcePath! + "/agent"
    let script = NSTemporaryDirectory() + "rw-setup-\(UUID().uuidString).sh"
    let body = """
    #!/bin/bash
    set -e
    /bin/bash "\(agentDir)/install.sh" "\(serviceURL)" "\(macToken)"
    S=$(mktemp)
    cat > "$S" <<'EOF'
    \(sudoersLine())
    EOF
    /usr/sbin/visudo -cf "$S" && install -m 440 -o root -g wheel "$S" \(sudoersPath)
    rm -f "$S"
    """
    guard FileManager.default.createFile(atPath: script, contents: Data(body.utf8), attributes: [.posixPermissions: 0o700]) else { return false }
    defer { try? FileManager.default.removeItem(atPath: script) }
    return sh("/usr/bin/osascript", args: ["-e", "do shell script \"/bin/bash \(script)\" with administrator privileges"]) == 0
}

func installRule() -> Bool {
    let tmp = NSTemporaryDirectory() + "remotewake.sudoers"
    try? (sudoersLine() + "\n").write(toFile: tmp, atomically: true, encoding: .utf8)
    let cmd = "/usr/sbin/visudo -cf \(tmp) && install -m 440 -o root -g wheel \(tmp) \(sudoersPath)"
    return sh("/usr/bin/osascript", args: ["-e", "do shell script \"\(cmd)\" with administrator privileges"]) == 0
}

func ago(_ t: Double?) -> String {
    guard let t else { return "never" }
    let s = Int(Date().timeIntervalSince1970 - t)
    return s < 90 ? "\(s) s ago" : s < 5400 ? "\(s / 60) min ago" : "\(s / 3600) h ago"
}

struct Row: View {
    let k: String, v: String
    var body: some View { HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).monospacedDigit() } }
}

struct Setup: View {
    @ObservedObject var m: Model
    @State var name = Host.current().localizedName ?? "My Mac"
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Set up Remote Wake").font(.headline)
            Text("Installs the wake agent on this Mac and gives you a code to pair your phone. You'll be asked for your Mac password once.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Device name", text: $name)
            if let e = m.error { Text(e).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Set up") { m.setup(name: name) }.disabled(name.isEmpty || m.busy)
                Spacer(); Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }.padding(12).frame(width: 330)
    }
}

struct Panel: View {
    @ObservedObject var m: Model
    var body: some View {
        if m.needsSetup { Setup(m: m) } else { main }
    }
    var main: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { m.running }, set: { _ in m.toggle() })) {
                Text("Wake agent").font(.headline)
            }.toggleStyle(.switch).disabled(m.busy)
            Text(m.running ? "Running" : "Stopped").font(.caption).foregroundStyle(m.running ? .green : .secondary)
            Divider()
            if let d = m.device {
                Row(k: "Last check-in", v: ago(d.last_checkin))
                Row(k: "Server view", v: d.no_recent_checkin == true ? "no recent check-in" : "online")
                Row(k: "Power", v: "\(d.power ?? "?") \(d.battery.map { "\($0)%" } ?? "")")
                Row(k: "Interval", v: "\(d.interval_s ?? 0) s" + (d.paused == true ? " (paused)" : ""))
            }
            if let e = m.error { Text(e).font(.caption).foregroundStyle(.red) }
            Divider()
            if m.device?.paired == true && m.code == nil {
                HStack { Text("Phone paired").foregroundStyle(.green); Spacer(); Button("Pair another") { m.newCode() } }
            } else if let c = m.code {
                Text("Open \(serviceURL.replacingOccurrences(of: "https://", with: "")) on your phone and enter:").font(.caption).foregroundStyle(.secondary)
                Text(c).font(.system(size: 26, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                Text("Valid for 15 minutes, works once.").font(.caption2).foregroundStyle(.secondary)
            } else {
                HStack { Text("No phone paired").foregroundStyle(.secondary); Spacer(); Button("Get code") { m.newCode() } }
            }
            Divider()
            Row(k: "Today: slept", v: "\(m.sleeps)")
            Row(k: "Today: stayed awake", v: "\(m.stays)")
            Text("Recent log").font(.caption).foregroundStyle(.secondary)
            ScrollView { Text(m.logLines.isEmpty ? "(empty)" : m.logLines.joined(separator: "\n"))
                .font(.system(size: 10, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                .frame(height: 90)
            Divider()
            HStack { Button("Refresh") { m.refresh() }; Spacer(); Button("Quit") { NSApplication.shared.terminate(nil) } }
        }.padding(12).frame(width: 330)
    }
}

@main struct RemoteWakeMenu: App {
    @StateObject var m = Model()
    var body: some Scene {
        MenuBarExtra("Remote Wake", systemImage: m.running ? "moon.zzz.fill" : "moon.zzz") { Panel(m: m) }
            .menuBarExtraStyle(.window)
    }
}
