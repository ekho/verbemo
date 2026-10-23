import AppKit

/// Live transcript and import progress inside the current recording page.
@MainActor
final class LiveTranscriptContent {
    var onToggleLive: ((Bool) -> Void)?
    var onImportFiles: (([URL]) -> Void)?
    var onCancelImport: (() -> Void)?

    let contentView: NSView
    /// What is wrong with the config file, when something is — see
    /// `Config.Problem`. Hidden, and so no row at all, the rest of the time.
    private let configProblemLabel = NSTextField(labelWithString: "")
    private let liveCheckbox = NSButton(
        checkboxWithTitle: localised("Live transcript", "Расшифровка на лету"),
        target: nil, action: nil)
    private let liveStatus = NSTextField(labelWithString: "")
    private let liveDownload = NSButton(title: "", target: nil, action: nil)
    private let liveReveal = NSButton(title: "", target: nil, action: nil)
    private let liveText = NSTextView()
    private let liveScroll = NSScrollView()
    private let liveSection = NSStackView()
    private let importStatus = MediaImportStatusView()

    private var liveTextVisible = false
    private var liveRevealedAfterStop = false

    init() {
        let container = MediaDropView()
        contentView = container
        configProblemLabel.font = .systemFont(ofSize: 11)
        configProblemLabel.textColor = .systemOrange
        configProblemLabel.lineBreakMode = .byTruncatingTail
        configProblemLabel.isHidden = true

        liveCheckbox.target = self
        liveCheckbox.action = #selector(liveClicked)
        liveCheckbox.isEnabled = true
        liveStatus.font = .systemFont(ofSize: 11)
        liveStatus.textColor = .secondaryLabelColor
        liveStatus.lineBreakMode = .byTruncatingTail
        liveStatus.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        liveDownload.identifier = .init("live.download")
        liveDownload.target = self
        liveDownload.action = #selector(downloadClicked)
        liveDownload.isHidden = true

        // The way back to a transcript the end of the recording folded away.
        // It sits where the status line does: a recording that has stopped
        // has no status to report, so the row has the space free.
        liveReveal.isBordered = false
        liveReveal.target = self
        liveReveal.action = #selector(liveRevealClicked)
        liveReveal.isHidden = true
        // Named so the suite that walks this page can click it. Finding it
        // by the words on it would be finding it by the very thing under
        // test — translate them and the click silently stops happening.
        liveReveal.identifier = NSUserInterfaceItemIdentifier("live-reveal")
        setRevealTitle(showing: false)

        liveText.isEditable = false
        liveText.isSelectable = true
        liveText.drawsBackground = false
        liveText.font = .systemFont(ofSize: 12)
        liveText.textContainerInset = NSSize(width: 8, height: 8)
        liveText.isVerticallyResizable = true
        liveText.isHorizontallyResizable = false
        liveText.autoresizingMask = [.width]
        liveText.textContainer?.widthTracksTextView = true
        liveScroll.documentView = liveText
        liveScroll.hasVerticalScroller = true
        liveScroll.autohidesScrollers = true
        liveScroll.drawsBackground = false
        liveScroll.borderType = .bezelBorder
        liveScroll.isHidden = true

        let liveHeader = NSStackView(views: [liveCheckbox, NSView(), liveStatus, liveDownload, liveReveal])
        liveHeader.orientation = .horizontal
        liveHeader.spacing = 8
        liveSection.setViews([liveHeader, liveScroll], in: .top)
        liveSection.orientation = .vertical
        liveSection.alignment = .leading
        liveSection.spacing = 6
        // Spare height belongs to the transcript only while it is visible.
        liveSection.setContentHuggingPriority(.required, for: .vertical)
        // The live transcript runs a local streaming model. On an Intel Mac
        // there is none, so the checkbox would be an offer that turns itself
        // back off — hidden instead.
        liveSection.isHidden = !Platform.supportsLocalModels

        importStatus.onCancel = { [weak self] in self?.onCancelImport?() }
        let rows = NSStackView()
        rows.setViews([configProblemLabel, liveSection, importStatus], in: .top)
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8
        rows.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        rows.translatesAutoresizingMaskIntoConstraints = false

        container.onFiles = { [weak self] urls in self?.onImportFiles?(urls) }
        container.addSubview(rows)

        // Fill available height without squeezing rows together in a short page.
        let fill = rows.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        fill.priority = .defaultLow
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: container.topAnchor),
            rows.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            fill,
            configProblemLabel.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -32),
            importStatus.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -32),
            liveSection.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -32),
            liveScroll.widthAnchor.constraint(equalTo: liveSection.widthAnchor),
            liveScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
    }

    func updateImport(_ update: MediaImportCoordinator.Update) {
        importStatus.update(update)
    }

    func finishImport(_ result: MediaImportCoordinator.Result) {
        importStatus.finish(result)
    }

    /// The config file's problem in one line, or nil when it has none.
    func updateConfigProblem(_ headline: String?) {
        configProblemLabel.stringValue = headline ?? ""
        configProblemLabel.toolTip = headline
        configProblemLabel.isHidden = headline == nil
    }

    func updateLive(_ snapshot: LiveTranscriptionCoordinator.Snapshot) {
        if snapshot.isRecording {
            liveCheckbox.state = snapshot.isEnabled ? .on : .off
        }
        liveStatus.stringValue = switch snapshot.status {
        case .idle: ""
        case .paused: localised("off", "выключена")
        case .downloading(let fraction): localised("Downloading Nemotron · ", "Загрузка Nemotron · ") + "\(Int(fraction * 100))%"
        case .loading: localised("loading model…", "загружаю модель…")
        case .live: localised("on this Mac", "на этом маке")
        case .modelMissing: localised("Nemotron model required", "Нужна модель Nemotron")
        case .overloaded:
            localised("stopped — Mac couldn't keep up", "остановлена — мак не успевает")
        case .error(let message): localised("stopped — ", "остановлена — ") + message
        }
        liveStatus.toolTip = liveStatus.stringValue
        liveDownload.title = snapshot.status == .modelMissing
            ? localised("Download model", "Скачать модель") : localised("Retry", "Повторить")
        switch snapshot.status {
        case .modelMissing, .error, .overloaded: liveDownload.isHidden = !snapshot.isRecording
        default: liveDownload.isHidden = true
        }

        let rendered = NSMutableAttributedString()
        for entry in snapshot.entries {
            switch entry {
            case .resumed:
                rendered.append(NSAttributedString(
                    string: localised(
                        "\n— live transcript resumed —\n\n",
                        "\n— расшифровка продолжена —\n\n"),
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]))
            case .speech(let block):
                rendered.append(NSAttributedString(
                    string: "\(block.speaker.label)  ",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                        .foregroundColor: NSColor.labelColor,
                    ]))
                rendered.append(NSAttributedString(
                    string: block.text + "\n\n",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 12),
                        .foregroundColor: block.isProvisional
                            ? NSColor.secondaryLabelColor : NSColor.labelColor,
                    ]))
            }
        }

        let documentHeight = liveText.layoutManager?.usedRect(
            for: liveText.textContainer!).height ?? 0
        let visibleBottom = liveScroll.contentView.bounds.maxY
        let wasAtBottom = documentHeight - visibleBottom < 24
        liveText.textStorage?.setAttributedString(rendered)
        if wasAtBottom { liveText.scrollToEndOfDocument(nil) }
        if snapshot.isRecording { liveRevealedAfterStop = false }
        let visibility = Self.liveTextVisibility(
            for: snapshot, revealed: liveRevealedAfterStop)
        showLiveText(visibility.showsTranscript)
        liveReveal.isHidden = !visibility.showsRevealLink
    }

    struct LiveTextVisibility: Equatable, Sendable {
        var showsTranscript: Bool
        var showsRevealLink: Bool
    }

    /// Hide an empty or finished transcript, retaining finished text behind
    /// a reveal link until the next recording clears it.
    nonisolated static func liveTextVisibility(
        for snapshot: LiveTranscriptionCoordinator.Snapshot,
        revealed: Bool
    ) -> LiveTextVisibility {
        let hasText = !snapshot.entries.isEmpty
        let expecting = snapshot.status == .loading || snapshot.status == .live
        guard !snapshot.isRecording else {
            return LiveTextVisibility(
                showsTranscript: hasText || expecting, showsRevealLink: false)
        }
        return LiveTextVisibility(
            showsTranscript: hasText && revealed, showsRevealLink: hasText)
    }

    private func showLiveText(_ visible: Bool) {
        guard visible != liveTextVisible else { return }
        liveTextVisible = visible
        liveScroll.isHidden = !visible
        liveSection.setContentHuggingPriority(visible ? .defaultLow : .required, for: .vertical)
        setRevealTitle(showing: visible)
    }

    /// Short titles leave room for the translated checkbox beside the link.
    private func setRevealTitle(showing visible: Bool) {
        liveReveal.attributedTitle = NSAttributedString(
            string: visible
                ? localised("Hide", "Скрыть")
                : localised("Show transcript", "Показать"),
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.linkColor,
            ])
    }

    func updateLivePreference(enabled: Bool) {
        liveCheckbox.state = enabled ? .on : .off
    }

    @objc private func liveClicked() { onToggleLive?(liveCheckbox.state == .on) }
    @objc private func downloadClicked() { onToggleLive?(true) }
    @objc private func liveRevealClicked() {
        liveRevealedAfterStop.toggle()
        showLiveText(liveRevealedAfterStop)
    }
}
