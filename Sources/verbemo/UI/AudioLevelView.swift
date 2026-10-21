import AppKit

@MainActor
final class AudioLevelView: NSStackView {
    let meter = NSLevelIndicator()
    private let status = NSTextField(labelWithString: "")

    init(title: String, source: String) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 5
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = JournalStyle.ink
        meter.levelIndicatorStyle = .continuousCapacity
        meter.minValue = 0
        meter.maxValue = 1
        meter.warningValue = 0.95
        meter.criticalValue = 1
        meter.isEditable = false
        meter.fillColor = JournalStyle.accent
        meter.identifier = .init("audio-level.\(source)")
        meter.setAccessibilityLabel(title)
        meter.setAccessibilityHelp(localised(
            "Captured peak level. Scale: minus 60 to 0 decibels relative to full scale.",
            "Пиковый уровень захваченного звука. Шкала: от минус 60 до 0 децибел относительно максимума."))
        label.setAccessibilityElement(false)
        status.setAccessibilityElement(false)
        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.textColor = JournalStyle.muted
        for view in [label, meter, status] {
            addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        meter.heightAnchor.constraint(equalToConstant: 12).isActive = true
        update(.off)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ reading: AudioMeter.Reading) {
        let value: Double
        let text: String
        switch reading {
        case .off:
            value = 0; text = localised("Off", "Отключён")
        case .paused:
            value = 0; text = localised("Paused", "На паузе")
        case .unavailable:
            value = 0; text = localised("Unavailable", "Недоступен")
        case .level(let peak):
            let decibels = peak > 0 ? 20 * log10(Double(peak)) : -Double.infinity
            value = max(0, min(1, (decibels + 60) / 60))
            if peak == 0 {
                text = localised("Silence", "Тишина")
            } else {
                let level = decibels < -60 ? "< −60" : String(Int(decibels.rounded())).replacingOccurrences(of: "-", with: "−")
                text = localised("Signal", "Сигнал") + " · \(level) dBFS"
            }
        }
        if meter.doubleValue != value { meter.doubleValue = value }
        if status.stringValue != text {
            status.stringValue = text
            meter.setAccessibilityValueDescription(text)
        }
    }
}
