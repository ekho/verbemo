import Foundation

/// Activity policy adapted from Dmitry Pimenov's fix; see THIRD-PARTY-NOTICES.md.
enum Wakefulness {
    // Plain userInitiated includes idleSystemSleepDisabled, even between meetings.
    static let lifetime: ProcessInfo.ActivityOptions = [
        .userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled, .automaticTerminationDisabled,
    ]
    static let recording: ProcessInfo.ActivityOptions = [.userInitiated, .idleSystemSleepDisabled]
    static let transcribing = recording

    typealias Hold = @Sendable (_ reason: String) -> () -> Void

    static let holdAwake: Hold = { reason in
        let activity = ProcessInfo.processInfo.beginActivity(options: transcribing, reason: reason)
        return { ProcessInfo.processInfo.endActivity(activity) }
    }
}
