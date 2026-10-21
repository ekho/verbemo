import AppKit

@MainActor
enum MeetingActionsMenu {
    static func make(state: MeetingActionState, target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu(title: localised("Meeting actions", "Действия со встречей"))
        menu.autoenablesItems = false
        let titles = [
            localised("Rename", "Переименовать"), localised("Copy transcript", "Копировать транскрипцию"),
            localised("Transcribe again", "Расшифровать повторно"), localised("Copy summary", "Копировать сводку"),
            localised("Regenerate summary", "Перегенерировать сводку"), localised("Open folder in Finder", "Открыть папку в Finder"),
            localised("Open in external editor", "Открыть во внешнем редакторе"),
            localised("Delete", "Удалить"),
        ]
        for (kind, title) in zip(MeetingActionState.Action.allCases, titles) where ![.copyTranscript, .copySummary, .regenerateSummary].contains(kind) {
            if kind == .delete { menu.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = kind.rawValue
            item.toolTip = state.reason(for: kind)
            item.isEnabled = item.toolTip == nil
            menu.addItem(item)
        }
        return menu
    }
}
