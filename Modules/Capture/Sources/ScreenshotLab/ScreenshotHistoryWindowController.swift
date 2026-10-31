import AppKit
import ImageIO

final class ScreenshotHistoryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    var onEdit: ((CGImage) -> Void)?
    var onCopy: ((CGImage) -> Void)?
    var onLimitChanged: ((Int) -> Void)?

    private let store: ScreenshotHistoryStore
    private var entries: [ScreenshotHistoryEntry] = []
    private(set) var displayedEntries: [ScreenshotHistoryEntry] = []

    private let tableView = NSTableView()
    private let previewImageView = NSImageView()
    private let previewPlaceholder = NSTextField(labelWithString: "选择一张截图进行预览")
    private let metadataLabel = NSTextField(labelWithString: "")
    private let headingLabel = NSTextField(labelWithString: "截图历史")
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "暂无截图")
    private let startPicker = NSDatePicker()
    private let endPicker = NSDatePicker()
    private let clearFilterButton = NSButton(title: "显示全部", target: nil, action: nil)
    private let limitField = NSTextField()
    private let limitStepper = NSStepper()
    private let editButton = NSButton(title: "编辑", target: nil, action: nil)
    private let copyButton = NSButton(title: "复制图片", target: nil, action: nil)
    private let finderButton = NSButton(title: "在 Finder 中显示", target: nil, action: nil)
    private let deleteButton = NSButton(title: "删除", target: nil, action: nil)
    private let previewSpinner = NSProgressIndicator()
    private let thumbnailCache = NSCache<NSString, NSImage>()
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm:ss"
        return formatter
    }()
    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()
    private var beginDate = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    private var endDate = Date()
    private var filterActive = false
    private var previewGeneration = UUID()

    init(store: ScreenshotHistoryStore) {
        self.store = store
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 980, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "截图历史"
        window.minSize = NSSize(width: 820, height: 520)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        thumbnailCache.totalCostLimit = 16 * 1024 * 1024
        buildInterface()
        bindStore()
        refreshFromStore()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        refreshFromStore()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        displayedEntries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard displayedEntries.indices.contains(row) else { return nil }
        let entry = displayedEntries[row]
        let identifier = NSUserInterfaceItemIdentifier("ScreenshotHistoryRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? HistoryTableCellView
            ?? HistoryTableCellView(identifier: identifier)
        cell.configure(with: entry, dateFormatter: dateFormatter, byteFormatter: byteFormatter)
        loadThumbnail(for: entry, into: cell)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelection()
    }

    private func bindStore() {
        store.onChange = { [weak self] entries in
            self?.apply(entries: entries)
        }
        store.onError = { [weak self] error in
            self?.showHistoryError(error)
        }
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        headingLabel.font = AppTheme.font(ofSize: 22, weight: .semibold)
        headingLabel.identifier = NSUserInterfaceItemIdentifier("HistoryHeading")
        countLabel.font = AppTheme.font(ofSize: 12, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right

        let titleRow = NSStackView(views: [headingLabel, flexibleSpacer(), countLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 12

        let timeLabel = NSTextField(labelWithString: "时间")
        timeLabel.font = AppTheme.font(ofSize: 11, weight: .medium)
        timeLabel.textColor = .secondaryLabelColor
        configureDatePicker(startPicker, identifier: "HistoryStartDate")
        configureDatePicker(endPicker, identifier: "HistoryEndDate")
        let rangeSeparator = NSTextField(labelWithString: "至")
        rangeSeparator.font = AppTheme.font(ofSize: 11, weight: .regular)
        rangeSeparator.textColor = .secondaryLabelColor

        clearFilterButton.target = self
        clearFilterButton.action = #selector(clearDateFilter)
        clearFilterButton.bezelStyle = .rounded
        clearFilterButton.controlSize = .small
        clearFilterButton.identifier = NSUserInterfaceItemIdentifier("HistoryClearDate")

        let retentionLabel = NSTextField(labelWithString: "保留最近")
        retentionLabel.font = AppTheme.font(ofSize: 11, weight: .medium)
        retentionLabel.textColor = .secondaryLabelColor
        configureLimitControls()
        let retentionSuffix = NSTextField(labelWithString: "张")
        retentionSuffix.font = AppTheme.font(ofSize: 11, weight: .regular)
        retentionSuffix.textColor = .secondaryLabelColor

        let filterRow = NSStackView(views: [
            timeLabel, startPicker, rangeSeparator, endPicker, clearFilterButton,
            flexibleSpacer(), retentionLabel, limitField, limitStepper, retentionSuffix,
        ])
        filterRow.orientation = .horizontal
        filterRow.alignment = .centerY
        filterRow.spacing = 7
        filterRow.setCustomSpacing(16, after: clearFilterButton)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ScreenshotHistoryEntry"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 66
        tableView.intercellSpacing = NSSize(width: 0, height: 3)
        tableView.selectionHighlightStyle = .regular
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.identifier = NSUserInterfaceItemIdentifier("HistoryTable")

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        emptyLabel.font = AppTheme.font(ofSize: 13, weight: .medium)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.identifier = NSUserInterfaceItemIdentifier("HistoryEmpty")

        let listContainer = NSView()
        listContainer.wantsLayer = true
        listContainer.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.48).cgColor
        listContainer.layer?.cornerRadius = 10
        listContainer.layer?.masksToBounds = true
        for view in [scrollView, emptyLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            listContainer.addSubview(view)
        }

        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.wantsLayer = true
        previewImageView.layer?.backgroundColor = NSColor.black.cgColor
        previewImageView.layer?.cornerRadius = 9
        previewImageView.layer?.masksToBounds = true
        previewImageView.identifier = NSUserInterfaceItemIdentifier("HistoryPreview")

        previewPlaceholder.font = AppTheme.font(ofSize: 13, weight: .medium)
        previewPlaceholder.textColor = .secondaryLabelColor
        previewPlaceholder.alignment = .center

        previewSpinner.style = .spinning
        previewSpinner.controlSize = .small
        previewSpinner.isDisplayedWhenStopped = false

        let previewContainer = NSView()
        previewContainer.wantsLayer = true
        previewContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        previewContainer.layer?.cornerRadius = 10
        for view in [previewImageView, previewPlaceholder, previewSpinner] {
            view.translatesAutoresizingMaskIntoConstraints = false
            previewContainer.addSubview(view)
        }

        metadataLabel.font = AppTheme.font(ofSize: 12, weight: .medium)
        metadataLabel.textColor = .secondaryLabelColor
        metadataLabel.lineBreakMode = .byTruncatingTail
        metadataLabel.identifier = NSUserInterfaceItemIdentifier("HistoryMetadata")

        configureActionButton(editButton, action: #selector(editSelected))
        configureActionButton(copyButton, action: #selector(copySelected))
        configureActionButton(finderButton, action: #selector(showSelectedInFinder))
        configureActionButton(deleteButton, action: #selector(deleteSelected))
        editButton.identifier = NSUserInterfaceItemIdentifier("HistoryEdit")
        copyButton.identifier = NSUserInterfaceItemIdentifier("HistoryCopy")
        finderButton.identifier = NSUserInterfaceItemIdentifier("HistoryFinder")
        deleteButton.identifier = NSUserInterfaceItemIdentifier("HistoryDelete")

        let actions = NSStackView(views: [
            editButton, copyButton, finderButton, flexibleSpacer(), deleteButton,
        ])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 7

        let previewPane = NSStackView(views: [metadataLabel, previewContainer, actions])
        previewPane.orientation = .vertical
        previewPane.alignment = .leading
        previewPane.spacing = 9
        actions.widthAnchor.constraint(equalTo: previewPane.widthAnchor).isActive = true
        previewContainer.widthAnchor.constraint(equalTo: previewPane.widthAnchor).isActive = true
        metadataLabel.widthAnchor.constraint(equalTo: previewPane.widthAnchor).isActive = true

        let columns = NSStackView(views: [listContainer, previewPane])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 14
        listContainer.widthAnchor.constraint(equalToConstant: 330).isActive = true
        columns.heightAnchor.constraint(greaterThanOrEqualToConstant: 430).isActive = true

        let memoryNote = NSTextField(
            wrappingLabelWithString: "历史存于本地磁盘；缩略图和当前预览会增加少量内存占用。"
        )
        memoryNote.font = AppTheme.font(ofSize: 11, weight: .regular)
        memoryNote.textColor = .tertiaryLabelColor
        memoryNote.maximumNumberOfLines = 2
        memoryNote.identifier = NSUserInterfaceItemIdentifier("HistoryMemoryNote")

        let root = NSStackView(views: [titleRow, filterRow, columns, memoryNote])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.setCustomSpacing(16, after: titleRow)
        root.setCustomSpacing(10, after: columns)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -22),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            titleRow.widthAnchor.constraint(equalTo: root.widthAnchor),
            filterRow.widthAnchor.constraint(equalTo: root.widthAnchor),
            columns.widthAnchor.constraint(equalTo: root.widthAnchor),
            memoryNote.widthAnchor.constraint(equalTo: root.widthAnchor),
            scrollView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: listContainer.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: listContainer.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: listContainer.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: listContainer.leadingAnchor, constant: 18),
            previewImageView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 12),
            previewImageView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -12),
            previewImageView.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 12),
            previewImageView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -12),
            previewPlaceholder.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            previewPlaceholder.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
            previewPlaceholder.leadingAnchor.constraint(greaterThanOrEqualTo: previewContainer.leadingAnchor, constant: 20),
            previewSpinner.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            previewSpinner.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor, constant: 24),
        ])
        updateSelection()
    }

    private func configureDatePicker(_ picker: NSDatePicker, identifier: String) {
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .yearMonthDay
        picker.controlSize = .small
        picker.dateValue = identifier == "HistoryStartDate" ? beginDate : endDate
        picker.target = self
        picker.action = #selector(dateFilterChanged)
        picker.identifier = NSUserInterfaceItemIdentifier(identifier)
    }

    private func configureLimitControls() {
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: ScreenshotHistoryStore.minimumLimit)
        formatter.maximum = NSNumber(value: ScreenshotHistoryStore.maximumLimit)
        limitField.formatter = formatter
        limitField.font = AppTheme.font(ofSize: 12, weight: .medium)
        limitField.alignment = .right
        limitField.controlSize = .small
        limitField.target = self
        limitField.action = #selector(retentionChanged(_:))
        limitField.identifier = NSUserInterfaceItemIdentifier("HistoryLimitField")
        limitField.translatesAutoresizingMaskIntoConstraints = false
        limitField.widthAnchor.constraint(equalToConstant: 42).isActive = true

        limitStepper.minValue = Double(ScreenshotHistoryStore.minimumLimit)
        limitStepper.maxValue = Double(ScreenshotHistoryStore.maximumLimit)
        limitStepper.increment = 1
        limitStepper.valueWraps = false
        limitStepper.target = self
        limitStepper.action = #selector(retentionChanged(_:))
        limitStepper.identifier = NSUserInterfaceItemIdentifier("HistoryLimitStepper")
    }

    private func configureActionButton(_ button: NSButton, action: Selector) {
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = action
    }

    private func flexibleSpacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    private func refreshFromStore() {
        entries = store.entries
        applyRetention(store.limit)
        apply(entries: entries)
    }

    private func apply(entries: [ScreenshotHistoryEntry]) {
        self.entries = entries
        displayedEntries = filterActive
            ? ScreenshotHistoryStore.filter(entries, from: beginDate, to: endDate)
            : entries

        let selectedID = selectedEntry?.id
        tableView.reloadData()
        displayedEntries = filterActive
            ? ScreenshotHistoryStore.filter(entries, from: beginDate, to: endDate)
            : entries
        if let selectedID,
           let row = displayedEntries.firstIndex(where: { $0.id == selectedID }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        } else if !displayedEntries.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        } else {
            tableView.deselectAll(nil)
        }
        countLabel.stringValue = "\(displayedEntries.count) 张"
        emptyLabel.isHidden = !displayedEntries.isEmpty
        updateSelection()
    }

    private func applyRetention(_ value: Int) {
        let clamped = min(
            ScreenshotHistoryStore.maximumLimit,
            max(ScreenshotHistoryStore.minimumLimit, value)
        )
        limitField.integerValue = clamped
        limitStepper.integerValue = clamped
    }

    private var selectedEntry: ScreenshotHistoryEntry? {
        guard displayedEntries.indices.contains(tableView.selectedRow) else { return nil }
        return displayedEntries[tableView.selectedRow]
    }

    private func updateSelection() {
        let entry = selectedEntry
        for button in [editButton, copyButton, finderButton, deleteButton] {
            button.isEnabled = entry != nil
        }
        previewGeneration = UUID()
        if let entry {
            previewPlaceholder.isHidden = true
            previewSpinner.startAnimation(nil)
            metadataLabel.stringValue = "\(dateFormatter.string(from: entry.createdAt))  ·  \(entry.byteCount > 0 ? byteFormatter.string(fromByteCount: entry.byteCount) : "正在读取")"
            loadPreview(for: entry, generation: previewGeneration)
        } else {
            previewSpinner.stopAnimation(nil)
            previewImageView.image = nil
            previewPlaceholder.isHidden = false
            metadataLabel.stringValue = filterActive && displayedEntries.isEmpty
                ? "当前日期范围没有截图"
                : "尚未选择截图"
        }
    }

    private func loadThumbnail(for entry: ScreenshotHistoryEntry, into cell: HistoryTableCellView) {
        let key = entry.id.uuidString as NSString
        if let image = thumbnailCache.object(forKey: key) {
            cell.setThumbnail(image)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak cell] in
            let image = Self.downsampledImage(url: entry.thumbnailURL, maxPixelSize: 160)
            guard let image else { return }
            let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            let cost = image.width * image.height * 4
            DispatchQueue.main.async {
                guard let self, let cell else { return }
                self.thumbnailCache.setObject(nsImage, forKey: key, cost: cost)
                if cell.representedEntryID == entry.id {
                    cell.setThumbnail(nsImage)
                }
            }
        }
    }

    private func loadPreview(for entry: ScreenshotHistoryEntry, generation: UUID) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = Self.downsampledImage(url: entry.imageURL, maxPixelSize: 1400)
            let nsImage = image.map {
                NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
            }
            DispatchQueue.main.async {
                guard let self, self.previewGeneration == generation else { return }
                self.previewSpinner.stopAnimation(nil)
                self.previewImageView.image = nsImage
                self.previewPlaceholder.isHidden = nsImage != nil
                self.previewPlaceholder.stringValue = nsImage == nil ? "无法读取预览" : ""
            }
        }
    }

    private static func downsampledImage(url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func fullImage(url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(
            source,
            0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        )
    }

    private func loadSelectedImage(
        completion: @escaping (CGImage?) -> Void
    ) {
        guard let entry = selectedEntry else {
            completion(nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let image = Self.fullImage(url: entry.imageURL)
            DispatchQueue.main.async { completion(image) }
        }
    }

    @objc private func dateFilterChanged() {
        if startPicker.dateValue > endPicker.dateValue {
            endPicker.dateValue = startPicker.dateValue
        }
        beginDate = startPicker.dateValue
        endDate = endPicker.dateValue
        filterActive = true
        apply(entries: entries)
    }

    @objc private func clearDateFilter() {
        filterActive = false
        beginDate = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        endDate = Date()
        startPicker.dateValue = beginDate
        endPicker.dateValue = endDate
        apply(entries: entries)
    }

    @objc private func retentionChanged(_ sender: Any?) {
        let requested = sender as? NSStepper == limitStepper
            ? limitStepper.integerValue
            : limitField.integerValue
        let value = min(
            ScreenshotHistoryStore.maximumLimit,
            max(ScreenshotHistoryStore.minimumLimit, requested)
        )
        applyRetention(value)
        onLimitChanged?(value)
        store.setLimit(value)
    }

    @objc private func editSelected() {
        loadSelectedImage { [weak self] image in
            guard let image else {
                self?.showHistoryError(ScreenshotHistoryError.imageDecodingFailed)
                return
            }
            self?.onEdit?(image)
        }
    }

    @objc private func copySelected() {
        loadSelectedImage { [weak self] image in
            guard let image else {
                self?.showHistoryError(ScreenshotHistoryError.imageDecodingFailed)
                return
            }
            self?.onCopy?(image)
        }
    }

    @objc private func showSelectedInFinder() {
        guard let entry = selectedEntry else { return }
        NSWorkspace.shared.activateFileViewerSelecting([entry.imageURL])
    }

    @objc private func deleteSelected() {
        guard let entry = selectedEntry, let window else { return }
        let alert = NSAlert()
        alert.messageText = "删除这张历史截图？"
        alert.informativeText = "只会删除 ScreenshotLab 的历史副本，不会影响你另外保存的文件。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.store.delete(id: entry.id)
        }
    }

    private func showHistoryError(_ error: Error) {
        guard let window else {
            NSSound.beep()
            return
        }
        let alert = NSAlert(error: error)
        alert.beginSheetModal(for: window)
    }
}

private final class HistoryTableCellView: NSTableCellView {
    private let thumbnail = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private(set) var representedEntryID: UUID?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        thumbnail.layer?.cornerRadius = 5
        thumbnail.layer?.masksToBounds = true
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        thumbnail.widthAnchor.constraint(equalToConstant: 56).isActive = true
        thumbnail.heightAnchor.constraint(equalToConstant: 48).isActive = true

        titleLabel.font = AppTheme.font(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = AppTheme.font(ofSize: 10, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail

        let labels = NSStackView(views: [titleLabel, subtitleLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2

        let row = NSStackView(views: [thumbnail, labels])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        with entry: ScreenshotHistoryEntry,
        dateFormatter: DateFormatter,
        byteFormatter: ByteCountFormatter
    ) {
        representedEntryID = entry.id
        thumbnail.image = AppTheme.symbol("photo", size: 18)
        thumbnail.contentTintColor = .tertiaryLabelColor
        titleLabel.stringValue = dateFormatter.string(from: entry.createdAt)
        let size = entry.byteCount > 0 ? byteFormatter.string(fromByteCount: entry.byteCount) : ""
        subtitleLabel.stringValue = "\(entry.pixelWidth) × \(entry.pixelHeight) px\(size.isEmpty ? "" : "  ·  \(size)")"
    }

    func setThumbnail(_ image: NSImage) {
        thumbnail.contentTintColor = nil
        thumbnail.image = image
    }
}
