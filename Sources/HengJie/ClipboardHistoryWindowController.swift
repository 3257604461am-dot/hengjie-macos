import AppKit

@MainActor
final class ClipboardHistoryWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    private let service: ClipboardHistoryService
    private let onEditImage: (CGImage) -> Void
    private let tableView = ClipboardHistoryTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let searchField = NSSearchField()
    private let filterControl = NSSegmentedControl(labels: ClipboardHistoryFilter.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let timePopup = NSPopUpButton()
    private var displayedItems: [ClipboardHistoryItem] = []

    init(service: ClipboardHistoryService, onEditImage: @escaping (CGImage) -> Void) {
        self.service = service
        self.onEditImage = onEditImage
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 430, height: 520),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "剪贴板历史"
        panel.level = .statusBar
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        super.init(window: panel)
        panel.delegate = self
        buildUI()
        service.onChange = { [weak self] in self?.reload() }
    }

    required init?(coder: NSCoder) { nil }

    func presentNearMouse() {
        reload()
        positionNearMouse()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !displayedItems.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let header = NSTextField(labelWithString: "最近复制的内容")
        header.font = .systemFont(ofSize: 15, weight: .semibold)
        header.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "搜索文字、链接或富文本"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        filterControl.selectedSegment = 0
        filterControl.target = self
        filterControl.action = #selector(filterChanged)
        filterControl.translatesAutoresizingMaskIntoConstraints = false
        timePopup.addItems(withTitles: ClipboardHistoryTimeFilter.allCases.map(\.title))
        timePopup.target = self
        timePopup.action = #selector(filterChanged)
        timePopup.translatesAutoresizingMaskIntoConstraints = false

        tableView.headerView = nil
        tableView.rowHeight = 72
        tableView.intercellSpacing = CGSize(width: 0, height: 4)
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(copySelected)
        tableView.onConfirm = { [weak self] in self?.copyCurrentSelection() }
        tableView.onCancel = { [weak self] in self?.window?.orderOut(nil) }
        let contextMenu = NSMenu()
        contextMenu.addItem(withTitle: "编辑图片", action: #selector(editSelectedImage), keyEquivalent: "")
        contextMenu.addItem(withTitle: "复制", action: #selector(copySelected), keyEquivalent: "")
        contextMenu.addItem(withTitle: "删除", action: #selector(deleteSelectedFromMenu), keyEquivalent: "")
        contextMenu.items.forEach { $0.target = self }
        contextMenu.delegate = self
        tableView.menu = contextMenu
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history"))
        column.width = 390
        tableView.addTableColumn(column)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.maximumNumberOfLines = 2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let clearButton = NSButton(title: "清空未固定记录", target: self, action: #selector(clearUnpinned))
        clearButton.bezelStyle = .rounded
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(header)
        content.addSubview(searchField)
        content.addSubview(filterControl)
        content.addSubview(timePopup)
        content.addSubview(scrollView)
        content.addSubview(statusLabel)
        content.addSubview(clearButton)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            searchField.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            filterControl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            filterControl.trailingAnchor.constraint(lessThanOrEqualTo: timePopup.leadingAnchor, constant: -8),
            filterControl.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            timePopup.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            timePopup.centerYAnchor.constraint(equalTo: filterControl.centerYAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            scrollView.topAnchor.constraint(equalTo: filterControl.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: clearButton.leadingAnchor, constant: -10),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -17),
            clearButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            clearButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor)
        ])
    }

    private func reload() {
        let filter = ClipboardHistoryFilter(rawValue: filterControl.selectedSegment) ?? .all
        let timeFilter = ClipboardHistoryTimeFilter(rawValue: timePopup.indexOfSelectedItem) ?? .all
        displayedItems = service.filteredItems(query: searchField.stringValue, filter: filter, timeFilter: timeFilter)
        tableView.reloadData()
        if displayedItems.isEmpty {
            statusLabel.stringValue = service.statusMessage ?? (searchField.stringValue.isEmpty ? "暂无记录。启用后只记录后续发生的剪贴板变化。" : "没有匹配的历史记录。")
        } else {
            let size = ByteCountFormatter.string(fromByteCount: service.items.reduce(0) { $0 + $1.byteCount }, countStyle: .file)
            let visible = displayedItems.count == service.items.count ? "" : " · 显示 \(displayedItems.count) 条"
            statusLabel.stringValue = service.statusMessage ?? "\(service.items.count)/100 条 · \(size)\(visible)"
        }
    }

    private func positionNearMouse() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        var frame = window.frame
        var origin = CGPoint(x: mouse.x - frame.width / 2, y: mouse.y - frame.height - 14)
        if origin.y < visible.minY { origin.y = mouse.y + 14 }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - frame.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - frame.height)
        frame.origin = origin
        window.setFrame(frame, display: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { displayedItems.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard displayedItems.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ClipboardHistoryCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? ClipboardHistoryCellView)
            ?? ClipboardHistoryCellView(identifier: identifier)
        let item = displayedItems[row]
        cell.configure(item: item, image: nil, row: row, target: self)
        service.loadPreview(for: item) { [weak self, weak cell] image in
            guard let self, self.displayedItems.indices.contains(row), self.displayedItems[row].id == item.id else { return }
            cell?.updatePreview(image, fallbackSymbol: item.kind.symbolName, title: item.kind.title)
        }
        return cell
    }

    @objc private func copySelected() { copyCurrentSelection() }

    private func copyCurrentSelection() {
        let row = tableView.selectedRow
        guard displayedItems.indices.contains(row) else { return }
        service.copyToPasteboard(displayedItems[row])
        window?.orderOut(nil)
    }

    @objc func togglePin(_ sender: NSButton) {
        guard displayedItems.indices.contains(sender.tag) else { return }
        service.togglePinned(displayedItems[sender.tag].id)
    }

    @objc func deleteItem(_ sender: NSButton) {
        guard displayedItems.indices.contains(sender.tag) else { return }
        service.delete(displayedItems[sender.tag].id)
    }

    @objc func editItem(_ sender: NSButton) {
        guard displayedItems.indices.contains(sender.tag) else { return }
        openImageEditor(displayedItems[sender.tag])
    }

    @objc private func editSelectedImage() {
        let row = tableView.selectedRow
        guard displayedItems.indices.contains(row) else { return }
        openImageEditor(displayedItems[row])
    }

    @objc private func deleteSelectedFromMenu() {
        let row = tableView.selectedRow
        guard displayedItems.indices.contains(row) else { return }
        service.delete(displayedItems[row].id)
    }

    private func openImageEditor(_ item: ClipboardHistoryItem) {
        guard item.kind == .image else { NSSound.beep(); return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let image = try await service.loadImage(item)
                window?.orderOut(nil)
                onEditImage(image)
            } catch { NSAlert(error: error).runModal() }
        }
    }

    @objc private func clearUnpinned() {
        guard service.items.contains(where: { !$0.isPinned }) else { return }
        let alert = NSAlert()
        alert.messageText = "清空未固定记录？"
        alert.informativeText = "固定的记录会继续保留。此操作无法撤销。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { service.clearUnpinned() }
    }

    @objc private func filterChanged() { reload() }

    func controlTextDidChange(_ obj: Notification) { reload() }

    func menuWillOpen(_ menu: NSMenu) {
        let row = tableView.selectedRow
        let isImage = displayedItems.indices.contains(row) && displayedItems[row].kind == .image
        menu.items.first(where: { $0.action == #selector(editSelectedImage) })?.isHidden = !isImage
    }
}

private final class ClipboardHistoryTableView: NSTableView {
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onConfirm?()
        case 53: onCancel?()
        default: super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return super.menu(for: event)
    }
}

private final class ClipboardHistoryCellView: NSTableCellView {
    private let preview = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let pinButton = NSButton()
    private let editButton = NSButton()
    private let deleteButton = NSButton()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 5
        preview.layer?.masksToBounds = true
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = .secondaryLabelColor
        pinButton.isBordered = false
        pinButton.imagePosition = .imageOnly
        pinButton.toolTip = "固定/取消固定"
        editButton.isBordered = false
        editButton.imagePosition = .imageOnly
        editButton.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "编辑图片")
        editButton.toolTip = "打开图片编辑"
        deleteButton.isBordered = false
        deleteButton.imagePosition = .imageOnly
        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "删除")
        deleteButton.toolTip = "删除"
        [preview, titleLabel, detailLabel, pinButton, editButton, deleteButton].forEach(addSubview)
    }

    required init?(coder: NSCoder) { nil }

    func configure(item: ClipboardHistoryItem, image: NSImage?, row: Int, target: AnyObject) {
        preview.image = image ?? NSImage(systemSymbolName: item.kind.symbolName, accessibilityDescription: item.kind.title)
        titleLabel.stringValue = item.previewText.isEmpty ? item.kind.title : item.previewText
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .short
        detailLabel.stringValue = "\(item.kind.title) · \(relative.localizedString(for: item.lastUsedAt, relativeTo: Date()))"
        pinButton.image = NSImage(systemSymbolName: item.isPinned ? "pin.fill" : "pin", accessibilityDescription: item.isPinned ? "取消固定" : "固定")
        pinButton.tag = row
        pinButton.target = target
        pinButton.action = #selector(ClipboardHistoryWindowController.togglePin(_:))
        editButton.isHidden = item.kind != .image
        editButton.tag = row
        editButton.target = target
        editButton.action = #selector(ClipboardHistoryWindowController.editItem(_:))
        deleteButton.tag = row
        deleteButton.target = target
        deleteButton.action = #selector(ClipboardHistoryWindowController.deleteItem(_:))
        needsLayout = true
    }

    func updatePreview(_ image: NSImage?, fallbackSymbol: String, title: String) {
        preview.image = image ?? NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: title)
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        preview.frame = CGRect(x: 8, y: 8, width: 54, height: max(40, height - 16))
        deleteButton.frame = CGRect(x: bounds.width - 31, y: (height - 24) / 2, width: 24, height: 24)
        pinButton.frame = CGRect(x: deleteButton.frame.minX - 29, y: deleteButton.frame.minY, width: 24, height: 24)
        editButton.frame = CGRect(x: pinButton.frame.minX - 29, y: pinButton.frame.minY, width: 24, height: 24)
        let textWidth = max(30, editButton.frame.minX - 74)
        titleLabel.frame = CGRect(x: 72, y: height / 2 - 2, width: textWidth, height: 34)
        detailLabel.frame = CGRect(x: 72, y: 9, width: textWidth, height: 16)
    }
}
