import AppKit

enum MediaImportPresentation {
    struct Copy: Equatable {
        let label: String
        let fraction: Double?
    }

    static func progress(_ update: MediaImportCoordinator.Update) -> Copy {
        let place = localised(
            "\(update.index) of \(update.total)",
            "\(update.index) из \(update.total)")
        let stage: String
        switch update.stage {
        case .checking: stage = localised("checking", "проверка")
        case .normalizing: stage = localised("converting", "конвертация")
        }
        return Copy(
            label: localised("Importing ", "Импорт ") + place + " · "
                + update.source.lastPathComponent + " · " + stage,
            fraction: update.fraction)
    }

    static func finished(_ result: MediaImportCoordinator.Result) -> Copy {
        if result.cancelled {
            return Copy(label: localised("Import cancelled", "Импорт остановлен"), fraction: nil)
        }
        var parts = [localised(
            "Imported \(result.imported.count)",
            "Импортировано: \(result.imported.count)")]
        if !result.duplicates.isEmpty {
            parts.append(localised(
                "\(result.duplicates.count) already here",
                "уже было: \(result.duplicates.count)"))
        }
        if !result.failures.isEmpty {
            parts.append(localised(
                "\(result.failures.count) failed",
                "ошибок: \(result.failures.count)"))
            let first = result.failures[0]
            let detail = first.source.lastPathComponent + ": " + first.message
            parts.append(result.failures.count == 1
                ? detail
                : detail + localised(
                    " (+\(result.failures.count - 1) more)",
                    " (+ещё \(result.failures.count - 1))"))
        }
        return Copy(label: parts.joined(separator: " · "), fraction: 1)
    }
}

/// A compact queue indicator shared by the meeting library and live page. Unknown stages spin;
/// AVFoundation conversion uses a real fraction and a real progress bar.
@MainActor
final class MediaImportStatusView: NSStackView {
    var onCancel: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let cancel = NSButton(
        title: localised("Cancel", "Остановить"), target: nil, action: nil)
    private var importing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        setHuggingPriority(.required, for: .vertical)
        identifier = NSUserInterfaceItemIdentifier("media-import-progress")
        isHidden = true

        label.font = .systemFont(ofSize: 11)
        label.identifier = .init("media-import.message")
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bar.style = .bar
        bar.controlSize = .small
        bar.minValue = 0
        bar.maxValue = 1
        bar.widthAnchor.constraint(equalToConstant: 86).isActive = true
        cancel.bezelStyle = .inline
        cancel.controlSize = .small
        cancel.target = self
        cancel.action = #selector(cancelClicked)
        addArrangedSubview(label)
        addArrangedSubview(bar)
        addArrangedSubview(cancel)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ update: MediaImportCoordinator.Update) {
        let copy = MediaImportPresentation.progress(update)
        importing = true
        isHidden = false
        label.stringValue = copy.label.split(whereSeparator: \.isNewline).joined(separator: " ")
        label.toolTip = copy.label
        cancel.isHidden = false
        cancel.identifier = .init("media-import.cancel")
        cancel.title = localised("Cancel", "Остановить")
        cancel.image = nil
        cancel.imagePosition = .noImage
        cancel.toolTip = cancel.title
        cancel.setAccessibilityLabel(cancel.title)
        bar.isHidden = false
        if let fraction = copy.fraction {
            bar.isIndeterminate = false
            bar.doubleValue = fraction
            bar.stopAnimation(nil)
        } else {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }
    }

    func finish(_ result: MediaImportCoordinator.Result) {
        let copy = MediaImportPresentation.finished(result)
        importing = false
        isHidden = false
        label.stringValue = copy.label.split(whereSeparator: \.isNewline).joined(separator: " ")
        label.toolTip = copy.label
        cancel.isHidden = false
        cancel.identifier = .init("media-import.dismiss")
        cancel.title = ""
        cancel.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        cancel.imagePosition = .imageOnly
        cancel.toolTip = localised("Dismiss notice", "Скрыть уведомление")
        cancel.setAccessibilityLabel(cancel.toolTip)
        bar.stopAnimation(nil)
        bar.isHidden = true
    }

    @objc private func cancelClicked() {
        if importing { onCancel?() } else { isHidden = true }
    }
}

/// A normal content container that additionally accepts Finder file drops.
/// Format validation belongs to AVFoundation in MediaNormalizer, so future
/// audio/video containers work without maintaining a brittle extension list.
@MainActor
final class MediaDropView: NSView {
    var onFiles: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let accepted = !fileURLs(from: sender.draggingPasteboard).isEmpty
        layer?.borderColor = accepted ? NSColor.controlAccentColor.cgColor : nil
        layer?.borderWidth = accepted ? 2 : 0
        return accepted ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        layer?.borderWidth = 0
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        layer?.borderWidth = 0
        let urls = fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onFiles?(urls)
        return true
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { !$0.hasDirectoryPath }
    }
}
