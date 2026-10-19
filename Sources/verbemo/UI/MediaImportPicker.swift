import AppKit
import UniformTypeIdentifiers

/// The one file picker behind every Import command. Keeping its configuration
/// here stops the app menu and status menu from quietly accepting different
/// kinds of files as those entry points evolve.
@MainActor
enum MediaImportPicker {
    static func configure(_ panel: NSOpenPanel) {
        panel.title = localised("Import recordings", "Импорт записей")
        panel.prompt = localised("Import", "Импортировать")
        panel.message = localised(
            "Choose one or more audio or video files.",
            "Выберите один или несколько аудио- или видеофайлов.")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .movie]
    }

    static func choose() -> [URL]? {
        let panel = NSOpenPanel()
        configure(panel)
        return panel.runModal() == .OK ? panel.urls : nil
    }
}
