import AppKit
import Sparkle

/// Sparkle, wired to verbemo's rule that a recording outranks an update.
///
/// Everything policy-shaped lives in `UpdateGate`, which is testable without a
/// bundle. What is left here is the adapter: start Sparkle when there is a
/// bundle to update, translate its two questions into the gate's vocabulary,
/// and hand the menu somewhere to send **Check for updates…**.
///
/// The updater only exists in a real `Verbemo.app` on a persistent, writable
/// volume. A bare binary has nothing Sparkle could replace, and a DMG copy is
/// read-only and disappears when ejected; starting it in either place only
/// produces a framework that logs its disappointment once a day.
final class AppUpdates: NSObject, SPUUpdaterDelegate {
    static let feedURL = "https://github.com/ekho/verbemo/releases/latest/download/appcast.xml"

    static func isConfigured(info: [String: Any]) -> Bool {
        guard info["SUFeedURL"] as? String == feedURL,
              let key = info["SUPublicEDKey"] as? String,
              let bytes = Data(base64Encoded: key), bytes.count == 32 else { return false }
        return true
    }

    private var controller: SPUStandardUpdaterController?
    private let gate: UpdateGate

    /// Whether this copy can be updated at all. False in a bare build and on
    /// the disk image, which is how the menu knows to leave out a button that
    /// can only fail.
    var isAvailable: Bool { controller != nil }

    @MainActor
    init(gate: UpdateGate) {
        self.gate = gate
        super.init()
        guard Runtime.supportsPersistentFeatures,
              Self.isConfigured(info: Bundle.main.infoDictionary ?? [:]) else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    @MainActor
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Recording, saving, processing or import changed. The gate rechecks
    /// all work before invoking a postponed relaunch.
    @MainActor
    func activityDidChange() {
        gate.activityDidChange()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        MainActor.assumeIsolated { gate.updaterDidAbort() }
    }

    // MARK: - SPUUpdaterDelegate

    /// Sparkle asks before every check. Refusing throws, and the error it
    /// carries is what ends up in the log, so it says why rather than that
    /// something went wrong.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        let kind: UpdateGate.Check
        switch updateCheck {
        case .updates: kind = .userInitiated
        case .updatesInBackground: kind = .background
        case .updateInformation: kind = .informationOnly
        @unknown default: kind = .background
        }
        let allowed = MainActor.assumeIsolated { gate.mayCheck(kind) }
        guard allowed else {
            throw NSError(
                domain: "name.ekho.verbemo.updates",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Verbemo is recording or processing; the update check can wait."]
            )
        }
    }

    /// The last gate, and the one that actually matters. Installing means
    /// quitting, and quitting mid-meeting loses the meeting — so the install
    /// is held until the recording and all subsequent processing are idle.
    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        MainActor.assumeIsolated {
            gate.postponeInstallIfBusy(installHandler)
        }
    }
}
