import AppKit
import Testing
@testable import verbemo

@Suite(.serialized) @MainActor
struct MCPSettingsViewTests {
    private func views(_ view: NSView) -> [NSView] { [view] + view.allDescendants }
    private func control<T: NSView>(_ view: NSView, _ id: String, as type: T.Type = T.self) throws -> T {
        try #require(views(view).first { $0.identifier?.rawValue == id } as? T)
    }
    private func click(_ view: NSView, _ id: String) throws {
        let button: NSButton = try control(view, id)
        if id.hasPrefix("mcp.section.") { button.state = button.state == .on ? .off : .on }
        _ = button.sendAction(button.action, to: button.target)
    }
    @Test(.freshHome) func disabledCardContainsOnlyTitleAndToggle() throws {
        let app = ApplicationWindow()
        defer { _ = app.stopForTermination() }
        app.navigate(.mcp)
        let page = app.settings.content(for: .mcp)
        let toggle: NSSwitch = try control(page, "mcp.enabled")
        #expect(toggle.state == .off)
        #expect(toggle.accessibilityLabel() == "MCP")
        let ids = Set(views(page).compactMap { $0.identifier?.rawValue }.filter { $0.hasPrefix("mcp.") })
        #expect(ids == ["mcp.card", "mcp.enabled"])
        #expect(!views(page).contains { $0 is NSTextView || $0 is NSPopUpButton })
        #expect(page.allDescendants.filter { $0.acceptsFirstResponder }.allSatisfy { $0 === toggle })
        #expect(app.panel.attachedSheet == nil)
    }
    @Test(.freshHome(config: #"{"mcp":{"enabled":true,"port":55432}}"#))
    func inlineDisclosuresRetainClientAndExpansionAcrossOffOn() throws {
        let card = MCPSettingsView()
        let client: NSPopUpButton = try control(card, "mcp.client")
        #expect(client.numberOfItems == 5)
        #expect(!views(card).contains { $0.identifier?.rawValue == "mcp.port" })
        #expect(!views(card).contains { $0.identifier?.rawValue == "mcp.token" })
        try click(card, "mcp.section.server")
        try click(card, "mcp.section.access")
        client.selectItem(at: 4); _ = client.sendAction(client.action, to: client.target)
        let port: NSTextField = try control(card, "mcp.port")
        #expect(port.stringValue == "55432")
        #expect(views(card).contains { $0.identifier?.rawValue == "mcp.token" })
        #expect((try control(card, "mcp.section.server", as: NSButton.self)).accessibilityValue() as? Int == 1)
        Config.update(path: ["mcp", "enabled"], value: false); card.refresh()
        #expect(views(card).compactMap { $0.identifier?.rawValue }.filter { $0.hasPrefix("mcp.") }.count == 2)
        Config.update(path: ["mcp", "enabled"], value: true); card.refresh()
        #expect(client.indexOfSelectedItem == 4)
        #expect(views(card).contains { $0 === port })
        #expect(views(card).contains { $0.identifier?.rawValue == "mcp.token" })
    }
    @Test(.freshHome(config: #"{"mcp":{"enabled":true,"port":55432}}"#), .speaking(.russian))
    func editedInvalidOrUnreadablePortDisablesEveryDependentCopyWithoutStaleText() throws {
        let card = MCPSettingsView(executable: "/Applications/Test's App.app/Contents/MacOS/verbemo")
        try click(card, "mcp.section.server")
        let port: NSTextField = try control(card, "mcp.port")
        let endpoint: NSTextField = try control(card, "mcp.url.text")
        #expect(endpoint.stringValue == "http://127.0.0.1:55432/mcp")
        port.stringValue = "55433"; card.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: port))
        #expect(endpoint.stringValue == "http://127.0.0.1:55433/mcp")
        let prompt: NSTextField = try control(card, "mcp.prompt.text")
        #expect(prompt.stringValue.contains("55433")); #expect(!prompt.stringValue.contains("55432"))
        port.stringValue = "wrong"; card.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: port))
        for id in ["url", "command", "prompt"] {
            #expect(!(try control(card, "mcp.\(id).copy", as: NSButton.self)).isEnabled)
            #expect((try control(card, "mcp.\(id).text", as: NSTextField.self)).stringValue.isEmpty)
        }
        #expect((try control(card, "mcp.validation", as: NSTextField.self)).stringValue.contains("1024"))
        port.stringValue = "55434"; card.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: port))
        try Home.current.writeConfig(text: "broken"); card.refresh()
        #expect(!(try control(card, "mcp.url.copy", as: NSButton.self)).isEnabled)
        #expect(endpoint.stringValue.isEmpty)
    }
    @Test(.freshHome(config: #"{"mcp":{"enabled":true,"port":55432}}"#))
    func threeCopyButtonsCopyTheirWholeCurrentBlocksAndRejectCorruptConfiguration() throws {
        let card = MCPSettingsView(executable: "/fixture/Verbemo App/verbemo")
        let board = NSPasteboard(name: .init("verbemo-task6-blocks-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        card.pasteboard = board
        for id in ["url", "command", "prompt"] {
            let text: NSTextField = try control(card, "mcp.\(id).text")
            try click(card, "mcp.\(id).copy")
            let copiedWholeBlock = board.string(forType: .string) == text.stringValue && !text.stringValue.isEmpty
            #expect(copiedWholeBlock, "Copy button copies its entire current block")
        }
        try click(card, "mcp.url.copy")
        let copiedURL = board.string(forType: .string) == "http://127.0.0.1:55432/mcp"
        #expect(copiedURL, "URL button copies the selected endpoint")
        try click(card, "mcp.command.copy")
        let copiedCommand = board.string(forType: .string) == "codex mcp add verbemo -- '/fixture/Verbemo App/verbemo' mcp"
        #expect(copiedCommand, "Command button copies the registration command")
        let client: NSPopUpButton = try control(card, "mcp.client")
        client.selectItem(at: 4); _ = client.sendAction(client.action, to: client.target)
        try click(card, "mcp.command.copy")
        let copiedBridge = board.string(forType: .string) == "'/fixture/Verbemo App/verbemo' mcp"
        #expect(copiedBridge, "Command button follows the selected client")
        board.clearContents(); board.setString("sentinel", forType: .string)
        try Home.current.writeConfig(text: "broken")
        try click(card, "mcp.prompt.copy")
        let clipboardUnchanged = board.string(forType: .string) == "sentinel"
        #expect(clipboardUnchanged, "Clipboard is unchanged when no copy is permitted")
        #expect(!(try control(card, "mcp.prompt.copy", as: NSButton.self)).isEnabled)
        #expect((try control(card, "mcp.prompt.text", as: NSTextField.self)).stringValue.isEmpty)
    }
    @Test(.freshHome(config: #"{"mcp":{"enabled":true,"port":55435}}"#))
    func maskedTokenUsesFreshSecretForButtonKeyboardAndContextCopy() async throws {
        let controller = MCPController(snapshot: { .init(root: Home.current.url) })
        defer { controller.stopAdmission() }
        let card = MCPSettingsView(controller: controller)
        try click(card, "mcp.section.access")
        let field: MCPMaskedTokenView = try control(card, "mcp.token")
        let board = NSPasteboard(name: .init("verbemo-task6-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        card.pasteboard = board
        let first = try MCPCredentials(home: .current).rotate()
        try click(card, "mcp.copy-token")
        let copiedFirst = board.string(forType: .string) == first
        #expect(copiedFirst, "Token copy button resolves current credential")
        let safelyMasked = field.string == "***" && field.accessibilityValue() == "***"
            && field.toolTip == nil && field.accessibilityHelp() == nil
        #expect(safelyMasked, "Display and accessibility contain only the mask")
        try click(card, "mcp.rotate-token")
        let second = try controller.tokenForLocalClipboard()
        let changed = first != second
        #expect(changed, "Synthetic credential rotation changed the key")
        field.setSelectedRange(NSRange(location: 1, length: 1))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = card; window.makeFirstResponder(field)
        let edit = NSMenu(title: "Edit")
        let copy = edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        copy.target = field
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        #expect(edit.performKeyEquivalent(with: event))
        let copiedSecond = board.string(forType: .string) == second
        #expect(copiedSecond, "Keyboard copy resolves current credential")
        let third = try MCPCredentials(home: .current).rotate()
        let mouse = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(field.menu(for: mouse))
        let contextCopy = try #require(menu.items.first { $0.action == #selector(NSText.copy(_:)) })
        _ = NSApplication.shared.sendAction(contextCopy.action!, to: field, from: contextCopy)
        let copiedThird = board.string(forType: .string) == third
        #expect(copiedThird, "Standard Copy action resolves current credential")
        field.setSelectedRange(NSRange(location: 0, length: 0))
        board.clearContents(); board.setString("sentinel", forType: .string)
        field.copy(nil)
        let clipboardUnchanged = board.string(forType: .string) == "sentinel"
        #expect(clipboardUnchanged, "Clipboard is unchanged when no copy is permitted")
        let displaySafe = views(card).compactMap { ($0 as? NSTextField)?.stringValue }.allSatisfy { !$0.contains(first) && !$0.contains(second) && !$0.contains(third) }
        #expect(displaySafe, "Visible text never contains a credential")
        window.contentView = nil
        await controller.stop()
    }
    @Test(.freshHome(config: #"{"mcp":{"enabled":true}}"#))
    func copyAndPortErrorsSurviveRefreshAndCollapsedSections() throws {
        let controller = MCPController(snapshot: { .init(root: Home.current.url) })
        let card = MCPSettingsView(controller: controller)
        try click(card, "mcp.section.access")
        try click(card, "mcp.copy-token")
        try click(card, "mcp.section.access")
        card.refresh()
        let error: NSTextField = try control(card, "mcp.operation-error")
        #expect(!error.isHiddenOrHasHiddenAncestor)
        #expect(error.stringValue == "Local token unavailable")
        let client: NSPopUpButton = try control(card, "mcp.client")
        client.selectItem(at: 1); _ = client.sendAction(client.action, to: client.target)
        #expect(error.stringValue == "Local token unavailable")
        try click(card, "mcp.section.server")
        let port: NSTextField = try control(card, "mcp.port")
        port.stringValue = "invalid"
        card.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: port))
        try click(card, "mcp.section.server"); card.refresh()
        #expect(!error.isHiddenOrHasHiddenAncestor)
        #expect(error.stringValue.contains("1024"))
    }

    @Test(.freshHome(config: #"{"mcp":{"enabled":true,"port":55432}}"#))
    func returningPortToDefaultUsesCanonicalSchemaClear() throws {
        let card = MCPSettingsView()
        try click(card, "mcp.section.server")
        let port: NSTextField = try control(card, "mcp.port")
        port.stringValue = ""
        card.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: port))
        card.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: port))
        #expect(Config.raw()["mcp"] as? [String: Any] != nil)
        #expect((Config.raw()["mcp"] as? [String: Any])?["port"] == nil)
        #expect((try control(card, "mcp.url.text", as: NSTextField.self)).stringValue == "http://127.0.0.1:52763/mcp")
    }
    @Test(.freshHome) func ordinaryTextSelectionKeepsNativeCopySemantics() {
        let board = NSPasteboard.general
        let previous = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        let text = NSTextView(); text.string = "ordinary selection text"
        text.setSelectedRange(NSRange(location: 9, length: 9))
        text.copy(nil)
        let ownedChange = board.changeCount
        defer {
            if board.changeCount == ownedChange {
                board.clearContents()
                let items = previous.map { values in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                }
                if !items.isEmpty { board.writeObjects(items) }
            }
        }
        let selectedTextCopied = board.string(forType: .string) == "selection"
        #expect(selectedTextCopied, "Ordinary native copy preserves partial selection")
    }
    @Test(.freshHome, .speaking(.russian)) func failedEnableKeepsOffCardAndUsesExistingAppNotice() throws {
        let home = Home.current
        try FileManager.default.createDirectory(at: home.keysDirectory, withIntermediateDirectories: true)
        #expect(chmod(home.keysDirectory.path, 0o755) == 0)
        let app = ApplicationWindow()
        let controller = MCPController(snapshot: { .init(root: home.url) })
        app.mcp = controller
        defer { _ = app.stopForTermination() }
        app.navigate(.mcp)
        let page = app.settings.content(for: .mcp)
        let toggle: NSSwitch = try control(page, "mcp.enabled")
        toggle.state = .on; _ = toggle.sendAction(toggle.action, to: toggle.target)
        #expect(toggle.state == .off)
        #expect(!views(page).contains { $0.identifier?.rawValue == "mcp.section.server" })
        let notice: NSTextField = try control(page, "settings.notice")
        #expect(!notice.isHiddenOrHasHiddenAncestor)
        #expect(notice.stringValue.contains("Не удалось сохранить"))
        #expect(app.panel.attachedSheet == nil)
    }
    @Test(.freshHome(config: #"{"mcp":{"enabled":true}}"#), .speaking(.russian))
    func rotateAndSaveFailuresRemainVisibleOutsideCollapsedDisclosures() throws {
        let home = Home.current
        try FileManager.default.createDirectory(at: home.keysDirectory, withIntermediateDirectories: true)
        #expect(chmod(home.keysDirectory.path, 0o755) == 0)
        let controller = MCPController(snapshot: { .init(root: home.url) })
        let card = MCPSettingsView(controller: controller)
        try click(card, "mcp.section.access"); try click(card, "mcp.rotate-token")
        try click(card, "mcp.section.access"); card.refresh()
        let error: NSTextField = try control(card, "mcp.operation-error")
        #expect(error.stringValue == "Не удалось заменить локальный токен")
        #expect(!error.isHiddenOrHasHiddenAncestor)
        try click(card, "mcp.section.server")
        let port: NSTextField = try control(card, "mcp.port")
        port.stringValue = "55439"
        card.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: port))
        #expect(chmod(home.configDirectory.path, 0o500) == 0)
        defer { _ = chmod(home.configDirectory.path, 0o700) }
        card.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: port))
        try click(card, "mcp.section.server")
        let client: NSPopUpButton = try control(card, "mcp.client")
        client.selectItem(at: 2); _ = client.sendAction(client.action, to: client.target)
        card.refresh()
        #expect(error.stringValue == "Не удалось сохранить порт MCP")
        #expect(!error.isHiddenOrHasHiddenAncestor)
    }
    @Test(.freshHome(config: #"{"mcp":{"enabled":true,"port":55438}}"#))
    func longInstructionsWrapInsideNarrowSettingsInBothLanguages() throws {
        for language in [InterfaceLanguage.english, .russian] {
            try InterfaceLanguage.$scoped.withValue(language) {
                let app = ApplicationWindow()
                defer { _ = app.stopForTermination(); app.hide() }
                app.panel.setContentSize(NSSize(width: 760, height: 680))
                app.navigate(.mcp); app.show()
                let page = app.settings.content(for: .mcp)
                let client: NSPopUpButton = try control(page, "mcp.client")
                for index in 0..<5 {
                    client.selectItem(at: index); _ = client.sendAction(client.action, to: client.target)
                    app.panel.contentView?.layoutSubtreeIfNeeded(); app.panel.layoutIfNeeded()
                    #expect(app.panel.contentLayoutRect.width <= 762)
                    let prompt: NSTextField = try control(page, "mcp.prompt.text")
                    #expect(prompt.bounds.width > 100)
                    #expect(prompt.bounds.width <= 520)
                    #expect(prompt.bounds.height > 100)
                    #expect(app.panel.attachedSheet == nil)
                }
            }
        }
    }

    @Test(.freshHome(config: #"{"mcp":{"enabled":true,"port":55436}}"#))
    func failedStartShowsSelectedEndpointAndNoActiveEndpoint() async throws {
        let host = MCPHTTP(port: 55436, token: String(repeating: "a", count: 64), gate: { _ in throw MCPFailure(.dataUnreadable) })
        try await host.start()
        defer { host.stopAdmission() }
        _ = try MCPCredentials(home: .current).rotate()
        let controller = MCPController(snapshot: { .init(root: Home.current.url) })
        let card = MCPSettingsView(controller: controller)
        controller.refresh()
        for _ in 0..<200 where controller.status == "Starting" { try await Task.sleep(for: .milliseconds(5)) }
        try click(card, "mcp.section.server")
        let status: NSTextField = try control(card, "mcp.status")
        #expect(status.stringValue.contains("Cannot listen"))
        #expect(status.stringValue.contains("Active endpoint: None"))
        #expect((try control(card, "mcp.url.text", as: NSTextField.self)).stringValue == "http://127.0.0.1:55436/mcp")
        #expect(!(try control(card, "mcp.operation-error", as: NSTextField.self)).isHiddenOrHasHiddenAncestor)
        await controller.stop(); await host.stop()
    }
}
