import AppKit
import UserNotifications

// Every log line is "<unix epoch, ms> <message>" so it lines up with send-log.txt.
func log(_ msg: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("wake1-app.log")
    let line = "\(String(format: "%.3f", Date().timeIntervalSince1970)) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? line.write(to: url, atomically: false, encoding: .utf8)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 120),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    let label = NSTextField(wrappingLabelWithString: "waiting for device token…")

    func applicationDidFinishLaunching(_ n: Notification) {
        let menu = NSMenu(), item = NSMenuItem(), sub = NSMenu()
        sub.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = sub; menu.addItem(item); NSApp.mainMenu = menu

        label.isSelectable = true
        label.frame = NSRect(x: 20, y: 20, width: 520, height: 80)
        window.contentView?.addSubview(label)
        window.title = "Wake Probe"
        window.center(); window.makeKeyAndOrderFront(nil)

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, err in
            log("AUTH granted=\(ok) err=\(String(describing: err))")
        }
        NSApp.registerForRemoteNotifications()
        log("LAUNCH")
    }

    func application(_ app: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken d: Data) {
        let t = d.map { String(format: "%02x", $0) }.joined()
        log("TOKEN \(t)")
        label.stringValue = t
    }

    func application(_ app: NSApplication, didFailToRegisterForRemoteNotificationsWithError e: Error) {
        log("REGFAIL \(e)")
        label.stringValue = "register failed: \(e)"
    }

    func application(_ app: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        log("RECV sentAt=\(userInfo["sentAt"] ?? "?")")
    }
}
