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
    @Published var busy = false
    @Published var error: String?
    var timer: Timer?

    init() { refresh(); timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in Task { @MainActor in self.refresh() } } }

    func refresh() {
        installed = FileManager.default.fileExists(atPath: plist)
        running = run("/bin/launchctl", ["print", "system/\(label)"]).status == 0
        onAC = run("/usr/bin/pmset", ["-g", "batt"]).out.contains("AC Power")
        holding = run("/usr/bin/pmset", ["-g", "assertions"]).out.range(of: #"PreventSystemSleep\s+1"#, options: .regularExpression) != nil
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

struct Row: View {
    let k: String, v: String
    var body: some View { HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).monospacedDigit() } }
}

struct Panel: View {
    @ObservedObject var m: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !m.installed || m.tsState == "not installed" {
                Text("Set up Remote Wake").font(.headline)
                Text("Installs Tailscale and a small background service that keeps this Mac awake while it is plugged in, so you can reach it from your phone. You'll be asked for your Mac password once.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Install") { m.install() }.disabled(m.busy)
            } else {
                Toggle(isOn: Binding(get: { m.running }, set: { _ in m.toggle() })) {
                    Text("Stay awake on AC").font(.headline)
                }.toggleStyle(.switch).disabled(m.busy)
                Text(!m.running ? "Off: the Mac sleeps normally"
                     : m.holding ? "On: awake, lid closed too" : "On, but on battery: the Mac sleeps normally")
                    .font(.caption).foregroundStyle(m.running && m.holding ? .green : .secondary)
                Divider()
                Row(k: "Power", v: m.onAC ? "AC" : "Battery")
                Row(k: "Tailscale", v: m.tsState == "Running" ? m.tsIP : m.tsState)
                if m.tsState == "NeedsLogin", let u = m.authURL, let url = URL(string: u) {
                    Button("Sign in to Tailscale") { NSWorkspace.shared.open(url) }
                } else if m.tsState != "Running" {
                    Button("Connect Tailscale") { m.connect() }
                }
            }
            if m.tsState == "Running" {
                Divider()
                if let ph = m.phones.first {
                    Row(k: "Phone", v: ph)
                } else {
                    Text("Next: set up your phone").font(.headline)
                    Text("1. Copy the phone app to your Android phone (cable, Drive, or email it to yourself) and open it; allow installs from that source.\n2. Open Remote Wake there and sign in to Tailscale with the same account as this Mac.\n3. Tap this Mac in the list.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let apk = Optional(URL(fileURLWithPath: resRoot + "/RemoteWake.apk")).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } {
                        Button("Show phone app in Finder") { NSWorkspace.shared.activateFileViewerSelecting([apk]) }
                    }
                }
            }
            if let e = m.error { Text(e).font(.caption).foregroundStyle(.red) }
            Divider()
            if isHelper {
                Button("Open Remote Wake") { NSWorkspace.shared.openApplication(at: mainAppURL, configuration: .init()) }
            }
            HStack { Button("Refresh") { m.refresh() }; Spacer(); Button(isHelper ? "Quit menu icon" : "Quit") { NSApplication.shared.terminate(nil) } }
        }.padding(12).frame(width: 300)
    }
}

// Main app: make sure the menu bar helper is registered for login and running now.
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
    var body: some Scene {
        MenuBarExtra("Remote Wake", systemImage: m.running ? "moon.zzz.fill" : "moon.zzz") { Panel(m: m) }
            .menuBarExtraStyle(.window)
    }
}

struct MainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var m = Model()
    var body: some Scene {
        Window("Remote Wake", id: "main") { Panel(m: m) }.windowResizability(.contentSize)
    }
}

@main enum Entry { static func main() { if isHelper { MenuApp.main() } else { MainApp.main() } } }
