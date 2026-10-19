import Foundation

/// Whether an update may happen right now, asked without Sparkle in the room.
///
/// Sparkle's scheduler knows about days and versions; it does not know that
/// this particular program is holding two audio taps open and that quitting to
/// swap the binary would destroy the meeting someone is in. That is the whole
/// reason this type exists: the rule is verbemo's, so it lives in verbemo, where
/// it can be tested without a bundle, a framework, or a network.
///
/// `AppUpdates` is the thin adapter that asks these questions on Sparkle's
/// behalf.
@MainActor
final class UpdateGate {
    /// Which kind of check Sparkle is about to make. The distinction matters:
    /// a background check is the updater's idea and can always wait, while a
    /// check someone chose from a menu is a question that deserves an answer
    /// even mid-recording — answering it costs nothing, since installing is
    /// gated separately.
    enum Check {
        case userInitiated
        case background
        case informationOnly
    }

    private let isBusy: () -> Bool
    private var postponedInstall: (() -> Void)?

    init(isBusy: @escaping () -> Bool) {
        self.isBusy = isBusy
    }

    func mayCheck(_ check: Check) -> Bool {
        switch check {
        case .background:
            // Nothing good comes of discovering an update mid-meeting: the
            // download competes for the same network the far end is on, and
            // the only thing it can lead to is the offer to restart.
            return !isBusy()
        case .userInitiated, .informationOnly:
            return true
        }
    }

    /// Hold an installation back while recording, saving, processing or importing.
    ///
    /// Returns true when the install was postponed, in which case `install` is
    /// kept and run by `activityDidChange()`. Returns false when there is
    /// nothing to wait for and the caller should proceed immediately.
    func postponeInstallIfBusy(_ install: @escaping () -> Void) -> Bool {
        guard isBusy() else { return false }
        postponedInstall = install
        return true
    }

    /// Recheck all activity before releasing the retained installer.
    func activityDidChange() {
        guard !isBusy(), let install = postponedInstall else { return }
        postponedInstall = nil
        install()
    }

    /// An aborted updater attempt must never revive its old relaunch handler.
    func updaterDidAbort() { postponedInstall = nil }

    var hasPostponedInstall: Bool { postponedInstall != nil }
}
