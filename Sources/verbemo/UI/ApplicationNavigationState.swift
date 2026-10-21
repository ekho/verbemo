import Foundation

struct ApplicationNavigationState {
    enum Destination: String, CaseIterable {
        case allMeetings, processing, attention, general, recording, transcription, summary, calendar, storage, about
        var isMeetings: Bool { [.allMeetings, .processing, .attention].contains(self) }
        var title: String {
            switch self {
            case .allMeetings: localised("All meetings", "Все встречи")
            case .processing: localised("Processing", "В обработке")
            case .attention: localised("Needs attention", "Нужны действия")
            case .general: localised("General", "Общие")
            case .recording: localised("Recording", "Запись")
            case .transcription: localised("Transcription", "Расшифровка")
            case .summary: localised("Summary and participants", "Сводка и участники")
            case .calendar: localised("Calendar", "Календарь")
            case .storage: localised("Storage and models", "Хранение и модели")
            case .about: localised("About Verbemo", "О Verbemo")
            }
        }
        var symbol: String {
            switch self {
            case .allMeetings: "doc.text"
            case .processing: "arrow.triangle.2.circlepath"
            case .attention: "exclamationmark.circle"
            case .general: "gearshape"
            case .recording: "mic"
            case .transcription: "doc.text"
            case .summary: "person.2"
            case .calendar: "calendar"
            case .storage: "folder"
            case .about: "info.circle"
            }
        }
    }
    var destination: Destination = .allMeetings
    var selectedSession: URL?
    var versionKey: String?
    var resultTab = "summary"
    var query = ""
    var showsDetail = false
    mutating func navigate(_ destination: Destination) { self.destination = destination }
    mutating func showAllMeetings() {
        destination = .allMeetings
        query = ""
        showsDetail = false
    }
}
