import AppKit

/// The token exists only in the explicit copy closure, never in the text system.
@MainActor final class MCPMaskedTokenView: NSTextView {
    var copyToken: (() -> Void)?
    override func copy(_ sender: Any?) {
        guard selectedRange().length > 0 else { return }
        copyToken?()
    }
}

@MainActor final class MCPSettingsView: NSStackView, NSTextFieldDelegate {
    var controller: MCPController? {
        didSet { observeController(); refresh() }
    }
    var onError: ((String) -> Void)?
    var pasteboard = NSPasteboard.general
    private let executable: String
    private let toggle = NSSwitch()
    private let port = NSTextField()
    private let body = NSStackView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let operationError = NSTextField(wrappingLabelWithString: "")
    private let validation = NSTextField(wrappingLabelWithString: "")
    private let client = NSPopUpButton()
    private let token = MCPMaskedTokenView()
    private var disclosures: [(NSButton, NSStackView, NSView)] = []
    private var blocks: [(NSTextField, NSButton)] = []
    private let commandTitle = NSTextField(wrappingLabelWithString: "")
    private let manual = NSTextField(wrappingLabelWithString: "")
    private var portIsDirty = false
    private var lastEnabled = false
    private var configurationReadable = true
    private var lastControllerStatus: String?
    var schemaControls: [NSControl] { [toggle, port] }

    init(controller: MCPController? = nil, executable: String = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]) {
        self.controller = controller; self.executable = executable
        super.init(frame: .zero)
        identifier = .init("mcp.card")
        orientation = .vertical; alignment = .leading; spacing = 16
        toggle.identifier = .init("mcp.enabled")
        toggle.setAccessibilityLabel("MCP")
        toggle.target = self; toggle.action = #selector(enableChanged)
        let heading = SetupLayout.row(title: SetupLayout.title("MCP"), trailing: [toggle])
        addArrangedSubview(heading)
        heading.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 16
        body.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 14, right: 14)
        operationError.isHidden = true
        operationError.identifier = .init("mcp.operation-error"); operationError.textColor = .systemRed
        body.addArrangedSubview(operationError)
        operationError.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -28).isActive = true
        status.identifier = .init("mcp.status")
        port.identifier = .init("mcp.port"); port.delegate = self
        if let entry = SettingsSchema.sections.flatMap(\.entries).first(where: { $0.path == ["mcp", "port"] }) {
            port.placeholderString = SettingsSchema.describeDefault(entry)
        }
        port.target = self; port.action = #selector(applyPort)
        port.setAccessibilityLabel(localised("MCP port", "Порт MCP"))
        let portRow = SetupLayout.row(title: SetupLayout.title(localised("Port", "Порт")), trailing: [port])
        port.widthAnchor.constraint(equalToConstant: 100).isActive = true
        let warning = label(localised("Changing the port disconnects active clients. Finish editing the port before starting a client; the bridge reads the saved settings.", "Изменение порта отключит активных клиентов. Завершите редактирование порта перед запуском клиента: мост читает сохранённые настройки."))
        section("server", title: localised("Server", "Сервер"), expanded: false, views: [status, portRow, warning])
        client.identifier = .init("mcp.client")
        client.addItems(withTitles: MCPConnectionInstructions.Client.allCases.map(\.rawValue))
        client.target = self; client.action = #selector(clientChanged)
        client.setAccessibilityLabel(localised("MCP client", "MCP-клиент"))
        validation.identifier = .init("mcp.validation"); validation.textColor = .systemOrange
        let urlBlock = block("url", title: label("MCP URL"))
        let commandBlock = block("command", title: commandTitle)
        let promptBlock = block("prompt", title: label(localised("Agent prompt", "Промпт для агента")))
        manual.identifier = .init("mcp.manual")
        section("connection", title: localised("Connection", "Подключение"), expanded: true,
                views: [client, validation, urlBlock, commandBlock, promptBlock, manual])
        token.string = "***"; token.isEditable = false; token.isSelectable = true
        token.drawsBackground = false; token.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        token.identifier = .init("mcp.token"); token.setAccessibilityLabel(localised("Direct HTTP token", "Токен прямого HTTP-доступа"))
        token.heightAnchor.constraint(equalToConstant: 24).isActive = true
        token.copyToken = { [weak self] in self?.copyCurrentToken() }
        let copy = button(localised("Copy token", "Копировать токен"), id: "mcp.copy-token", action: #selector(copyToken))
        let rotate = button(localised("Rotate token", "Заменить токен"), id: "mcp.rotate-token", action: #selector(rotateToken))
        section("access", title: localised("Access", "Доступ"), expanded: false, views: [
            label(localised("Token for direct HTTP access", "Токен для прямого HTTP-доступа")), token, copy,
            label(localised("Copying inserts the full token", "При копировании будет подставлен полный токен")), rotate,
            label(localised("The native bridge reads the protected token itself. Standard client setup does not need a token.", "Нативный мост сам читает защищённый токен. Для обычной настройки клиента токен не нужен."))])
        observeController(); refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    private func button(_ title: String, id: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.identifier = .init(id); button.bezelStyle = .rounded
        return button
    }
    private func section(_ id: String, title: String, expanded: Bool, views: [NSView]) {
        let button = button(title, id: "mcp.section." + id, action: #selector(disclose(_:)))
        button.setButtonType(.onOff); button.isBordered = false; button.alignment = .left
        button.state = expanded ? .on : .off; button.tag = disclosures.count
        button.setAccessibilityRole(.disclosureTriangle)
        button.setAccessibilityLabel(title)
        button.imagePosition = .imageLeading
        let content = SetupLayout.group(views, spacing: 10)
        let section = NSStackView(views: [button]); section.orientation = .vertical; section.alignment = .leading; section.spacing = 10
        button.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        disclosures.append((button, section, content))
        body.addArrangedSubview(section)
        section.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -28).isActive = true
        updateDisclosure(disclosures.count - 1)
    }
    private func block(_ id: String, title: NSTextField) -> NSView {
        let text = label(""); text.identifier = .init("mcp.\(id).text")
        text.isSelectable = true; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.lineBreakMode = .byCharWrapping
        let copy = button(localised("Copy", "Копировать"), id: "mcp.\(id).copy", action: #selector(copyBlock(_:)))
        copy.tag = blocks.count; blocks.append((text, copy))
        return SetupLayout.group([title, text, copy], spacing: 6)
    }
    private func observeController() {
        controller?.onChange = { [weak self] in self?.refresh() }
    }
    func refresh() {
        if let config = try? MCPConfiguration.read(home: .current) {
            configurationReadable = true; lastEnabled = config.enabled
            if !portIsDirty { port.stringValue = String(config.port) }
        } else { configurationReadable = false }
        toggle.state = lastEnabled ? .on : .off
        if lastEnabled, body.superview == nil {
            addArrangedSubview(body)
            body.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        } else if !lastEnabled, body.superview != nil {
            removeArrangedSubview(body); body.removeFromSuperview()
        }
        let rawStatus = controller?.status ?? "Off"
        status.stringValue = localised("Server: ", "Сервер: ") + localizedStatus(rawStatus) + "\n"
            + localised("Selected endpoint: ", "Выбранный адрес: ") + (selectedPort.map { "http://127.0.0.1:\($0)/mcp" } ?? localised("Invalid selection", "Некорректный порт")) + "\n"
            + localised("Active endpoint: ", "Активный адрес: ") + (controller?.listeningAddress ?? localised("None", "Нет"))
        disclosures[0].0.title = localised("Server", "Сервер") + " — " + localizedStatus(rawStatus)
            + (controller?.listeningAddress.flatMap { URL(string: $0)?.port }.map { " (\($0))" } ?? "")
        let statusChanged = lastControllerStatus != rawStatus
        lastControllerStatus = rawStatus
        if statusChanged && (rawStatus.hasPrefix("MCP closed") || rawStatus == "Cannot listen on selected port") {
            report(localizedStatus(rawStatus))
        }
        updateContent()
    }
    private var selectedPort: Int? {
        guard configurationReadable else { return nil }
        let input = port.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty { return 52763 }
        guard let number = Int(input), (1024...65535).contains(number) else { return nil }
        return number
    }
    private var validationMessage: String {
        configurationReadable ? localised("Enter an integer port from 1024 to 65535.", "Укажите целый порт от 1024 до 65535.")
            : localised("MCP settings cannot be read. Fix the configuration before copying setup instructions.", "Настройки MCP не читаются. Исправьте конфигурацию перед копированием инструкции.")
    }
    private func updateContent() {
        configurationReadable = (try? MCPConfiguration.read(home: .current)) != nil
        let generated = selectedPort.flatMap { MCPConnectionInstructions.content(client: MCPConnectionInstructions.Client.allCases[max(0, client.indexOfSelectedItem)], port: $0, executable: executable) }
        validation.stringValue = generated == nil ? validationMessage : ""; validation.isHidden = generated != nil
        commandTitle.stringValue = generated?.commandTitle ?? localised("Console command", "Команда консоли")
        let values = [generated?.endpoint, generated?.command, generated?.agentPrompt]
        for (index, block) in blocks.enumerated() {
            block.0.stringValue = values[index] ?? ""; block.1.isEnabled = generated != nil
        }
        manual.stringValue = generated?.manualSteps ?? ""
    }
    @objc private func disclose(_ sender: NSButton) { updateDisclosure(sender.tag) }
    private func updateDisclosure(_ index: Int) {
        let (button, section, content) = disclosures[index]
        let expanded = button.state == .on
        button.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        button.setAccessibilityValue(expanded ? 1 : 0)
        if expanded, content.superview == nil {
            section.addArrangedSubview(content)
            content.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        }
        if !expanded, content.superview != nil { section.removeArrangedSubview(content); content.removeFromSuperview() }
    }
    @objc private func enableChanged() {
        guard let controller else { report(localised("MCP controller unavailable", "Контроллер MCP недоступен")); refresh(); return }
        controller.setEnabled(toggle.state == .on); refresh()
    }
    func controlTextDidChange(_ notification: Notification) {
        portIsDirty = true; updateContent()
        // Keep the unapplied selection separate from the actual listener during typing.
        refresh()
    }
    func controlTextDidEndEditing(_ notification: Notification) { applyPort() }
    @objc private func applyPort() {
        updateContent()
        guard selectedPort != nil,
              let entry = SettingsSchema.sections.flatMap(\.entries).first(where: { $0.path == ["mcp", "port"] })
        else { report(validationMessage); return }
        let resolution = SettingsSchema.resolve(.text(port.stringValue), for: entry)
        let stored = (Config.raw()["mcp"] as? [String: Any])?["port"]
        guard SettingsSchema.changes(resolution, from: stored) else {
            portIsDirty = false; refresh(); return
        }
        let value: Any?
        switch resolution {
        case .set(let port): value = port
        case .clear: value = nil
        case .invalid: report(validationMessage); return
        }
        guard Config.update(path: entry.path, value: value) else {
            report(localised("Could not save MCP port", "Не удалось сохранить порт MCP")); return
        }
        portIsDirty = false; controller?.refresh(); refresh()
    }
    @objc private func clientChanged() { updateContent() }
    @objc private func copyBlock(_ sender: NSButton) {
        updateContent()
        guard sender.isEnabled else { report(validationMessage); return }
        writeClipboard(blocks[sender.tag].0.stringValue)
    }
    @objc private func copyToken() { copyCurrentToken() }
    private func copyCurrentToken() {
        do {
            guard let value = try controller?.tokenForLocalClipboard() else { throw MCPFailure(.dataUnreadable) }
            writeClipboard(value)
        } catch { report(localised("Local token unavailable", "Локальный токен недоступен")) }
    }
    @objc private func rotateToken() {
        guard let controller else { report(localised("Could not replace local token", "Не удалось заменить локальный токен")); return }
        controller.rotateToken(); refresh()
    }
    private func writeClipboard(_ value: String) {
        pasteboard.clearContents()
        if !pasteboard.setString(value, forType: .string) { report(localised("Could not copy to clipboard", "Не удалось скопировать в буфер обмена")) }
    }
    private func report(_ message: String) {
        operationError.stringValue = message; operationError.isHidden = false
        if !lastEnabled { onError?(message) }
    }
    private func localizedStatus(_ status: String) -> String {
        switch status {
        case "Off": localised("Off", "Выключен")
        case "Starting": localised("Starting", "Запускается")
        case "Listening": localised("Listening", "Слушает подключения")
        case "Stopped": localised("Stopped", "Остановлен")
        case "Waiting for library change": localised("Waiting for library change", "Ожидает смены библиотеки")
        case "Local token missing — enable or rotate locally": localised("Local token missing — enable or rotate locally", "Нет локального токена — включите сервер или замените токен на этом компьютере")
        case "Cannot listen on selected port": localised("Cannot listen on selected port", "Не удалось слушать выбранный порт")
        case "MCP closed — could not save local credentials/settings": localised("Could not save MCP credentials/settings", "Не удалось сохранить токен или настройки MCP")
        case "MCP closed — could not save token": localised("Could not replace local token", "Не удалось заменить локальный токен")
        case "MCP closed — configuration changed": localised("MCP closed — configuration changed", "MCP закрыт — конфигурация изменилась")
        default: localised("MCP closed — settings or local token unreadable", "MCP закрыт — настройки или локальный токен не читаются")
        }
    }
}
