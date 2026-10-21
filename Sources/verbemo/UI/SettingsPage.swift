import Foundation

/// Every schema entry belongs to one task-oriented page, including rare options.
enum SettingsPage {
    static func destination(for path: [String]) -> ApplicationNavigationState.Destination {
        if path == ["auto_record", "calendar"] || path == ["user_name"] { return .calendar }
        switch path.first {
        case "transcription", "live_transcription", "transcript_echo_filter": return .transcription
        case "summary", "speaker_names": return .summary
        case "recordings_dir", "keep_audio": return .storage
        case "calendar": return .calendar
        case "auto_record", "system_audio", "mic_voice_processing", "offline_echo_cancellation", "on_stop": return .recording
        default: return .general
        }
    }
}
