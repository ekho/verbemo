import AppKit
import ApplicationServices
import CallIntegrations

actor KTalkAccessibility {
    private var applications: [pid_t: AXUIElement] = [:]
    private var restore: Set<pid_t> = []

    func stop() {
        for pid in restore {
            if let app = applications[pid] { AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanFalse) }
        }
        applications.removeAll(); restore.removeAll()
    }

    func read() -> KTalkReading {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "kontur.talk")
        guard !running.isEmpty else { stop(); return .init(participation: .idle) }
        guard AXIsProcessTrusted() else { return .init(participation: .unknown) }
        let pids = Set(running.map(\.processIdentifier))
        for pid in Array(applications.keys) where !pids.contains(pid) {
            applications.removeValue(forKey: pid); restore.remove(pid)
        }
        var candidates: [KTalkReading] = []
        for process in running {
            let pid = process.processIdentifier
            let app = applications[pid] ?? AXUIElementCreateApplication(pid)
            applications[pid] = app
            AXUIElementSetMessagingTimeout(app, 0.05)
            if !restore.contains(pid), attribute(app, "AXManualAccessibility") as? Bool == false,
               AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success {
                restore.insert(pid)
            }
            var windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
            for key in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
                if let value = attribute(app, key), CFGetTypeID(value) == AXUIElementGetTypeID() {
                    let window = unsafeDowncast(value, to: AXUIElement.self)
                    if !windows.contains(where: { CFEqual($0, window) }) { windows.append(window) }
                }
            }
            for window in windows.prefix(8) {
                candidates.append(scan(window, pid: pid))
            }
        }
        let active = candidates.filter { $0.participation == .inCall }
        if active.count == 1 { return active[0] }
        if active.isEmpty, let preparing = candidates.first(where: { $0.participation == .preparing }) { return preparing }
        return .init(participation: .unknown)
    }

    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }

    private func scan(_ window: AXUIElement, pid: pid_t) -> KTalkReading {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.35
        var stack = [(window, 0)]
        var seen: [CFHashCode: [AXUIElement]] = [:]
        var labels = Set<String>()
        var links = Set<URL>()
        var count = 0
        while let (node, depth) = stack.popLast() {
            guard count < 1200, depth <= 45, ProcessInfo.processInfo.systemUptime < deadline else { return .init(participation: .unknown) }
            let hash = CFHash(node)
            if seen[hash, default: []].contains(where: { CFEqual($0, node) }) { continue }
            seen[hash, default: []].append(node); count += 1
            let role = attribute(node, kAXRoleAttribute) as? String ?? ""
            if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) { continue }
            if role == kAXButtonRole {
                for key in [kAXTitleAttribute, kAXDescriptionAttribute] {
                    if let label = attribute(node, key) as? String { labels.insert(label) }
                }
            }
            for key in [kAXURLAttribute, kAXDocumentAttribute] {
                let value = attribute(node, key)
                let string = (value as? URL)?.absoluteString ?? value as? String
                if let string, let url = Self.cleanRoomURL(string) { links.insert(url) }
            }
            let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
            stack.append(contentsOf: children.reversed().map { ($0, depth + 1) })
        }
        let state = Self.participation(labels: labels)
        guard state != .unknown else { return .init(participation: .unknown) }
        // shortcut: AX mute labels across a window include other participants;
        // keep local mute unknown until the local toolbar is independently validated.
        return .init(participation: state, call: .init(id: "ax:\(pid):\(CFHash(window))",
            title: attribute(window, kAXTitleAttribute) as? String,
            url: links.count == 1 ? links.first : nil))
    }

    static func participation(labels: Set<String>) -> CallParticipation {
        let labels = Set(labels.map { $0.replacingOccurrences(of: "\u{200B}", with: "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let leave = !labels.isDisjoint(with: ["покинуть комнату", "покинуть встречу", "выйти из конференции", "leave meeting", "leave room", "leave call"])
        let join = !labels.isDisjoint(with: ["присоединиться", "войти в комнату", "присоединиться к встрече", "подключиться к встрече", "join meeting", "join room"])
        if leave == join { return .unknown }
        return leave ? .inCall : .preparing
    }

    static func cleanRoomURL(_ string: String) -> URL? {
        guard var c = URLComponents(string: string), ["https", "ktalk"].contains(c.scheme),
              let host = c.host, host.hasSuffix(".ktalk.ru"), c.port == nil,
              c.path.split(separator: "/").count == 1 else { return nil }
        c.user = nil; c.password = nil; c.query = nil; c.fragment = nil
        return c.url
    }
}
