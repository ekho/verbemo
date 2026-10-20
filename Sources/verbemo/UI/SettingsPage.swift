import Foundation

/// Every schema entry belongs to one task-oriented page, including rare options.
enum SettingsPage {
    static func destination(for path: [String]) -> ApplicationNavigationState.Destination {
        switch path.first {
        case "transcription", "live_transcription", "transcript_echo_filter": return .transcription
        case "summary", "speaker_names", "user_name": return .summary
        case "recordings_dir", "keep_audio": return .storage
        case "auto_record", "system_audio", "mic_voice_processing", "offline_echo_cancellation", "calendar", "on_stop": return .recording
        default: return .general
        }
    }
}
