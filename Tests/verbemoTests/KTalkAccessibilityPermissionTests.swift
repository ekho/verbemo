import AppKit
import Testing
@testable import verbemo

@Suite(.serialized) @MainActor
struct KTalkAccessibilityPermissionTests {
    @Test(.freshHome, .speaking(.russian))
    func ktalkSettingsExposePermissionAction() throws {
        let app = ApplicationWindow()
        defer { _ = app.stopForTermination() }
        var requests = 0
        app.settings.requestAccessibility = { requests += 1 }
        app.settings.updateAccessibility(.denied)
        let page = app.settings.content(for: .ktalk)
        let button = try #require(page.allDescendants.first {
            $0.identifier?.rawValue == "access.accessibility.action"
        } as? NSButton)
        #expect(button.accessibilityLabel()?.contains("Универсальный доступ") == true)
        #expect(!button.isHiddenOrHasHiddenAncestor)
        #expect(button.title == "Разрешить…")
        button.performClick(nil)
        #expect(requests == 1)
        app.settings.updateAccessibility(.granted)
        #expect(button.isHidden)
        let row = try #require(page.allDescendants.first { $0.identifier?.rawValue == "access.accessibility" })
        #expect(row.allDescendants.compactMap { $0 as? NSTextField }.contains {
            !$0.isHiddenOrHasHiddenAncestor && $0.stringValue == "разрешено"
        })
        app.settings.updateAccessibility(.denied)
        #expect(!button.isHidden)
        #expect(button.isEnabled)
        #expect(requests == 1, "Refreshing a permission must never request it")
    }

    @Test(.freshHome, .speaking(.russian))
    func statusOpensKTalkAndReflectsPermissionChanges() throws {
        let app = ApplicationWindow()
        defer { _ = app.stopForTermination() }
        var access = ActivityAccess(microphone: .granted, systemAudio: .heard, calendar: nil)
        app.updateActivity([], access: access)
        let badge = try #require(app.activityBar.allDescendants.first {
            $0.identifier?.rawValue == "activity.accessibility-access"
        } as? NSButton)
        #expect(badge.isHidden)
        access.accessibility = .denied
        app.updateActivity([], access: access)
        #expect(!badge.isHiddenOrHasHiddenAncestor)
        #expect(badge.contentTintColor == .systemOrange)
        #expect(badge.toolTip?.contains("нужен Универсальный доступ") == true)
        #expect(badge.accessibilityLabel() == badge.toolTip)
        badge.performClick(nil)
        #expect(app.navigation.destination == .ktalk)
        access.accessibility = .granted
        app.updateActivity([], access: access)
        #expect(badge.contentTintColor != .systemOrange)
        #expect(badge.toolTip?.contains("разрешён") == true)
        access.accessibility = nil
        app.updateActivity([], access: access)
        #expect(badge.isHidden, "An unused integration must not show a permission warning")
    }

    @Test(.freshHome, .speaking(.russian))
    func permissionFitsNarrowSettingsInBothAppearances() throws {
        let app = ApplicationWindow()
        defer { _ = app.stopForTermination(); app.hide() }
        app.show()
        app.navigate(.ktalk)
        let page = app.settings.content(for: .ktalk)
        let row = try #require(page.allDescendants.first { $0.identifier?.rawValue == "access.accessibility" })
        let button = try #require(row.allDescendants.first {
            $0.identifier?.rawValue == "access.accessibility.action"
        } as? NSButton)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            app.panel.appearance = NSAppearance(named: appearance)
            for width in [760.0, 1340.0] {
                app.panel.setContentSize(.init(width: width, height: 820))
                for state in [SetupPermissions.State.denied, .granted] {
                    app.settings.updateAccessibility(state)
                    app.updateActivity([], access: .init(microphone: .granted, systemAudio: .heard,
                        calendar: .granted, accessibility: state))
                    app.panel.contentView?.layoutSubtreeIfNeeded()
                    app.panel.layoutIfNeeded()
                    #expect(abs(app.panel.contentLayoutRect.width - width) < 1)
                    #expect(row.bounds.width > 200)
                    for view in row.allDescendants where (view is NSTextField || view is NSButton) && !view.isHiddenOrHasHiddenAncestor {
                        let frame = view.convert(view.bounds, to: row)
                        #expect(frame.minX >= -1 && frame.maxX <= row.bounds.width + 1)
                    }
                    #expect(button.isHidden == (state == .granted))
                    if width == 760, let output = ProcessInfo.processInfo.environment["VERBEMO_ACCESS_SHOTS"], let content = app.panel.contentView {
                        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                        content.cacheDisplay(in: content.bounds, to: bitmap)
                        let data = try #require(bitmap.representation(using: .png, properties: [:]))
                        let name = "\(appearance.rawValue)-\(state == .granted ? "granted" : "denied").png"
                        try data.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
                    }
                }
            }
        }
    }
}
