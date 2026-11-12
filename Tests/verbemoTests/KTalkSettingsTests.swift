import AppKit
import Testing
@testable import verbemo

@Suite(.serialized) @MainActor
struct KTalkSettingsTests {
    @Test(.freshHome, .speaking(.russian))
    func russianPageMovesExistingControlsAndKeepsTheirValues() throws {
        try page(title: "Интеграция с KTalk")
    }
    @Test(.freshHome, .speaking(.english))
    func englishPageMovesExistingControlsAndKeepsTheirValues() throws {
        try page(title: "KTalk integration")
    }
    private func page(title: String) throws {
        Config.update(path: ["call_integrations", "ktalk", "enabled"], value: true)
        Config.update(path: ["call_integrations", "ktalk", "space_url"], value: "https://synthetic.ktalk.ru")
        let destination = try #require(ApplicationNavigationState.Destination(rawValue: "ktalk"))
        #expect(destination.title == title)
        let app = ApplicationWindow()
        defer { _ = app.stopForTermination() }
        app.navigate(destination)
        let content = app.settings.content(for: destination)
        for entry in SettingsSchema.sections.flatMap(\.entries) where entry.path.first == "call_integrations" {
            #expect(SettingsPage.destination(for: entry.path) == destination)
            #expect(entry.needsRestart)
            let key = entry.path.joined(separator: ".")
            let control = try #require(content.allDescendants.first { $0.identifier?.rawValue == key })
            #expect(!control.isHiddenOrHasHiddenAncestor)
            #expect(!app.settings.content(for: .general).allDescendants.contains { $0.identifier?.rawValue == key })
        }
        #expect(Config.ktalkIntegration().enabled)
        #expect(Config.ktalkIntegration().space == "https://synthetic.ktalk.ru")
    }

    @Test(.freshHome) func directReadinessDoesNotWarnAboutUnusedDevices() throws {
        let bar = ActivityStatusBar()
        bar.updateAccess(.init(microphone: .denied, systemAudio: nil, calendar: nil, directCallReady: true))
        for id in ["activity.microphone-access", "activity.system-access"] {
            let control = try #require(bar.allDescendants.first { $0.identifier?.rawValue == id } as? NSButton)
            #expect(control.contentTintColor != .systemOrange)
        }
    }

    @Test(.freshHome, .speaking(.russian)) func failedCaptureRemainsActionableAfterASR() throws {
        let dir = try SessionFixture.make(meta: ["capture_failure": "Allow microphone access"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try #require(SessionInventory.item(for: dir))
        let attention = try #require(MeetingPresentation.attention(for: item))
        #expect(attention.problems.contains { $0.contains("Запись неполная") })
    }
}
