import AppKit
import SwiftUI

@MainActor
final class StudioMeetingHeaderState: ObservableObject {
    @Published var matchCount = 0
    @Published var matchIndex: Int?
    @Published var hasQuery = false
    var onStep: ((Bool) -> Void)?
    var onClear: (() -> Void)?
    func step(forward: Bool) { onStep?(forward) }
    func clear() { onClear?() }
}

/// AppKit keeps selection, field editing and command routing; SwiftUI owns the adaptive layout.
@MainActor
struct StudioMeetingHeader: View {
    @ObservedObject var state: StudioMeetingHeaderState
    let versions: NSPopUpButton
    let tabs: NSStackView
    let search: NSSearchField
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let layout = compact
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            layout {
                HStack(spacing: 8) {
                    Text(localised("Version", "Версия")).font(.callout)
                    StudioHeaderControl(control: versions)
                }.frame(width: 220)
                HStack(spacing: 6) {
                    StudioHeaderControl(control: search).frame(minWidth: 140)
                    if state.hasQuery {
                        Text("\(state.matchIndex.map { $0 + 1 } ?? 0) / \(state.matchCount)")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            .accessibilityLabel(localised("Search matches", "Совпадения поиска"))
                        Button { state.step(forward: false) } label: { Image(systemName: "chevron.up") }
                            .help(localised("Previous match · Shift+Enter", "Предыдущее совпадение · Shift+Enter"))
                            .accessibilityLabel(localised("Previous match", "Предыдущее совпадение"))
                            .disabled(state.matchCount == 0)
                        Button { state.step(forward: true) } label: { Image(systemName: "chevron.down") }
                            .help(localised("Next match · Enter", "Следующее совпадение · Enter"))
                            .accessibilityLabel(localised("Next match", "Следующее совпадение"))
                            .disabled(state.matchCount == 0)
                        Button { state.clear() } label: { Image(systemName: "xmark") }
                            .help(localised("Clear search · Escape", "Очистить поиск · Escape"))
                            .accessibilityLabel(localised("Clear meeting search", "Очистить поиск во встрече"))
                    }
                }.frame(maxWidth: .infinity)
            }
            StudioHeaderControl(control: tabs)
        }
        .tint(Color(nsColor: StudioStyle.accent))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
final class StudioMeetingHeaderHost: NSHostingView<StudioMeetingHeader> {
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let compact = newSize.width < 560
        if rootView.compact != compact { rootView.compact = compact }
    }
}

@MainActor
private struct StudioHeaderControl<Control: NSView>: NSViewRepresentable {
    let control: Control
    func makeNSView(context: Context) -> Control { control }
    func updateNSView(_ view: Control, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Control, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.fittingSize.width, height: max(26, nsView.fittingSize.height))
    }
}
