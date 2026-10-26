import AppKit

@MainActor
final class EmailAddressesEditor: NSControl {
    private let list = NSStackView()
    private let input = NSTextField()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let lookup = NSButton(title: localised("Get from calendars", "Взять из календарей"), target: nil, action: nil)
    private var addresses: [String] = []
    var onChange: (([String]) -> Bool)?
    var onLookup: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        input.placeholderString = localised("Add email", "Добавить email")
        input.identifier = .init("user_email.input")
        input.setAccessibilityLabel(input.placeholderString)
        input.target = self
        input.action = #selector(addAddress)
        input.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let add = NSButton(title: localised("Add", "Добавить"), target: self, action: #selector(addAddress))
        add.identifier = .init("user_email.add")
        let inputRow = NSStackView(views: [input, add])
        inputRow.spacing = 8
        lookup.target = self
        lookup.action = #selector(findAddresses)
        lookup.identifier = .init("user_email.lookup")
        message.font = .systemFont(ofSize: 11)
        message.isHidden = true
        message.identifier = .init("user_email.message")
        let stack = NSStackView(views: [list, inputRow, lookup, message])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            list.widthAnchor.constraint(equalTo: stack.widthAnchor),
            inputRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func accessibilityChildren() -> [Any]? { NSAccessibility.unignoredChildren(from: subviews) }

    func show(_ emails: [String]) {
        guard emails != addresses else { return }
        addresses = emails
        for view in list.arrangedSubviews { list.removeArrangedSubview(view); view.removeFromSuperview() }
        for (index, address) in addresses.enumerated() {
            let label = NSTextField(labelWithString: address)
            label.isSelectable = true
            label.lineBreakMode = .byTruncatingMiddle
            label.toolTip = address
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let remove = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)!,
                                  target: self, action: #selector(removeAddress(_:)))
            remove.isBordered = false
            remove.tag = index
            remove.identifier = .init("user_email.remove")
            remove.setAccessibilityLabel(localised("Remove \(address)", "Удалить \(address)"))
            remove.toolTip = remove.accessibilityLabel()
            let row = NSStackView(views: [label, remove])
            row.spacing = 8
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }

    func report(_ text: String, error: Bool = false) {
        message.stringValue = text
        message.textColor = error ? .systemRed : .secondaryLabelColor
        message.isHidden = text.isEmpty
    }

    func setSearching(_ searching: Bool) {
        lookup.isEnabled = !searching
        if searching { report(localised("Looking for your addresses…", "Ищем ваши адреса…")) }
    }

    @objc private func addAddress() {
        guard let added = EmailAddresses.parse(input.stringValue), !added.isEmpty else {
            report(localised("Enter an email address, such as name@example.com.", "Введите email, например name@example.com."), error: true)
            return
        }
        if save(EmailAddresses.normalize(addresses + added)) {
            input.stringValue = ""
            window?.makeFirstResponder(input)
        }
    }

    @objc private func removeAddress(_ sender: NSButton) {
        guard addresses.indices.contains(sender.tag) else { return }
        var updated = addresses
        updated.remove(at: sender.tag)
        if save(updated) { window?.makeFirstResponder(input) }
    }

    @objc private func findAddresses() { onLookup?() }

    private func save(_ updated: [String]) -> Bool {
        guard onChange?(updated) == true else {
            report(localised("Could not save the addresses. Check the settings file.", "Не удалось сохранить адреса. Проверьте файл настроек."), error: true)
            return false
        }
        show(updated)
        report("")
        return true
    }
}
