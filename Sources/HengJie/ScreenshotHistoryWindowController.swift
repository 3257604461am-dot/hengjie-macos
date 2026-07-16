import AppKit

@MainActor
final class ScreenshotHistoryWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let service: ScreenshotHistoryService
    private let onEdit: (LoadedScreenshotProject) -> Void
    private let tableView = NSTableView()
    private let filterControl = NSSegmentedControl(labels: ScreenshotHistoryFilter.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var displayedItems: [ScreenshotHistoryItem] = []

    init(service: ScreenshotHistoryService, onEdit: @escaping (LoadedScreenshotProject) -> Void) {
        self.service = service
        self.onEdit = onEdit
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
        )
        window.title = "横截 — 最近截图"
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        service.onChange = { [weak self] in self?.reload() }
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: "最近截图")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        let note = NSTextField(labelWithString: "底图与标注图层分别保存，可继续编辑")
        note.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [title, note])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 2

        filterControl.selectedSegment = 0
        filterControl.target = self
        filterControl.action = #selector(filterChanged)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ScreenshotHistory"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 84
        tableView.intercellSpacing = CGSize(width: 0, height: 5)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(editSelected)
        tableView.target = self
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let edit = button("重新编辑", #selector(editSelected))
        edit.keyEquivalent = "\r"
        let copy = button("复制", #selector(copySelected))
        let save = button("另存…", #selector(saveSelected))
        let delete = button("删除", #selector(deleteSelected))
        let clear = button("清空全部…", #selector(clearAll))
        let actions = NSStackView(views: [edit, copy, save, delete, NSView(), clear])
        actions.spacing = 8

        let root = NSStackView(views: [heading, filterControl, scroll, statusLabel, actions])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            filterControl.widthAnchor.constraint(equalTo: root.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            statusLabel.widthAnchor.constraint(equalTo: root.widthAnchor),
            actions.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func reload() {
        let filter = ScreenshotHistoryFilter(rawValue: filterControl.selectedSegment) ?? .all
        displayedItems = service.filteredItems(filter)
        tableView.reloadData()
        let bytes = ByteCountFormatter.string(fromByteCount: service.items.reduce(0) { $0 + $1.byteCount }, countStyle: .file)
        statusLabel.stringValue = service.statusMessage ?? "\(service.items.count)/100 条 · \(bytes) · 最长保留 30 天"
        statusLabel.textColor = service.statusMessage == nil ? .secondaryLabelColor : .systemOrange
        if !displayedItems.isEmpty, tableView.selectedRow < 0 { tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { displayedItems.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard displayedItems.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ScreenshotHistoryCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? ScreenshotHistoryCellView)
            ?? ScreenshotHistoryCellView(identifier: identifier)
        let item = displayedItems[row]
        cell.configure(item: item, image: nil)
        service.loadThumbnail(for: item) { [weak tableView, weak cell] image in
            guard let tableView, tableView.row(for: cell ?? NSView()) == row else { return }
            cell?.updateImage(image)
        }
        return cell
    }

    @objc private func filterChanged() { reload() }

    private var selectedItem: ScreenshotHistoryItem? {
        let row = tableView.selectedRow
        return displayedItems.indices.contains(row) ? displayedItems[row] : nil
    }

    @objc private func editSelected() {
        guard let item = selectedItem else { NSSound.beep(); return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await service.load(id: item.id)
                onEdit(loaded)
                if let warning = loaded.annotationRecoveryWarning { showWarning(warning) }
            } catch { NSAlert(error: error).runModal() }
        }
    }

    @objc private func copySelected() { renderSelected { ImageExport.copy($0) } }

    @objc private func saveSelected() {
        renderSelected { image in
            do { try ImageExport.save(image, format: AppPreferences.shared.saveFormat) }
            catch { NSAlert(error: error).runModal() }
        }
    }

    private func renderSelected(_ action: @escaping (NSImage) -> Void) {
        guard let item = selectedItem else { NSSound.beep(); return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await service.load(id: item.id)
                let canvas = AnnotationCanvas(
                    image: loaded.image,
                    displaySize: CGSize(width: loaded.project.displayWidth, height: loaded.project.displayHeight)
                )
                canvas.restore(records: loaded.project.annotations)
                action(canvas.renderedImage())
            } catch { NSAlert(error: error).runModal() }
        }
    }

    @objc private func deleteSelected() {
        guard let item = selectedItem else { return }
        service.delete(item.id)
    }

    @objc private func clearAll() {
        guard !service.items.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "清空全部最近截图？"
        alert.informativeText = "底图、缩略图和可编辑标注图层都会被删除，此操作无法撤销。"
        alert.addButton(withTitle: "全部清空")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { service.clearAll() }
    }

    private func showWarning(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "部分内容无法恢复"
        alert.informativeText = text
        alert.runModal()
    }
}

private final class ScreenshotHistoryCellView: NSTableCellView {
    private let preview = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let state = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 6
        preview.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 11)
        state.font = .systemFont(ofSize: 11, weight: .medium)
        let labels = NSStackView(views: [title, detail, state])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        let row = NSStackView(views: [preview, labels])
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            preview.widthAnchor.constraint(equalToConstant: 112), preview.heightAnchor.constraint(equalToConstant: 70),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(item: ScreenshotHistoryItem, image: NSImage?) {
        preview.image = image ?? NSImage(systemSymbolName: item.kind.symbolName, accessibilityDescription: item.kind.title)
        title.stringValue = item.kind.title
        detail.stringValue = "\(item.pixelWidth) × \(item.pixelHeight) · \(Self.formatter.string(from: item.updatedAt))"
        state.stringValue = item.state.title
        state.textColor = item.state == .draft ? .systemOrange : .systemGreen
    }

    func updateImage(_ image: NSImage?) { if let image { preview.image = image } }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}
