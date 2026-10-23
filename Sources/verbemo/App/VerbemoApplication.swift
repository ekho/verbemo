import AppKit

@MainActor
final class QuitRequestGate {
    private var pending = false

    func perform(_ terminate: () -> Void) {
        guard !pending else { return }
        pending = true
        defer { pending = false }
        terminate()
    }
}

/// A second AppKit terminate bypasses the delegate while its deferred reply is pending.
@objc(VerbemoApplication)
@MainActor
final class VerbemoApplication: NSApplication {
    private let quitRequests = QuitRequestGate()

    override func terminate(_ sender: Any?) {
        quitRequests.perform { super.terminate(sender) }
    }
}
