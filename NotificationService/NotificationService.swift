import UserNotifications

// Logs into the shared app group folder:
// ~/Library/Group Containers/group.com.guru.wakeprobe/wake1-ext.log
func log(_ msg: String) {
    guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.guru.wakeprobe") else { return }
    let url = dir.appendingPathComponent("wake1-ext.log")
    let line = "\(String(format: "%.3f", Date().timeIntervalSince1970)) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? line.write(to: url, atomically: false, encoding: .utf8)
    }
}

final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        log("EXT sentAt=\(request.content.userInfo["sentAt"] ?? "?")")
        contentHandler(request.content)
    }
}
