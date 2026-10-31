import AppKit

// 弹窗里的"占用最高的进程"区块:标题 + 固定行数的图标/名称/数值行。
final class ProcessListView: NSView {
    private static let iconCache = NSCache<NSString, NSImage>()
    private static let fallbackIcon: NSImage = {
        let icon = NSWorkspace.shared.icon(for: .unixExecutable)
        icon.size = NSSize(width: 14, height: 14)
        return icon
    }()

    private var valueLabels: [NSTextField] = []
    private var nameLabels: [NSTextField] = []
    private var iconViews: [NSImageView] = []

    init(title: String, limit: Int) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = AppTheme.font(ofSize: 11, weight: .medium)
        titleLabel.textColor = AppTheme.secondaryText
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false

        for index in 0..<limit {
            let iconView = NSImageView()
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.setContentHuggingPriority(.required, for: .horizontal)

            let nameLabel = NSTextField(labelWithString: "—")
            nameLabel.font = AppTheme.font(ofSize: 12)
            nameLabel.textColor = AppTheme.primaryText
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let valueLabel = NSTextField(labelWithString: "")
            valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            valueLabel.textColor = AppTheme.secondaryText
            valueLabel.alignment = .right
            valueLabel.setContentHuggingPriority(.required, for: .horizontal)

            let row = NSStackView(views: [iconView, nameLabel, valueLabel])
            row.orientation = .horizontal
            row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            iconView.widthAnchor.constraint(equalToConstant: 14).isActive = true
            iconView.heightAnchor.constraint(equalToConstant: 14).isActive = true

            nameLabels.append(nameLabel)
            valueLabels.append(valueLabel)
            iconViews.append(iconView)
            if index == 0 { row.identifier = NSUserInterfaceItemIdentifier("processRow0") }
        }

        addSubview(titleLabel)
        addSubview(stack)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),

            stack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(samples: [ProcessSample], valueFormatter: (ProcessSample) -> String) {
        for (index, label) in nameLabels.enumerated() {
            if index < samples.count {
                let sample = samples[index]
                label.stringValue = sample.name
                label.textColor = AppTheme.primaryText
                valueLabels[index].stringValue = valueFormatter(sample)
                iconViews[index].image = Self.icon(for: sample.iconPath)
                iconViews[index].isHidden = false
            } else {
                label.stringValue = "—"
                label.textColor = AppTheme.secondaryText.withAlphaComponent(0.4)
                valueLabels[index].stringValue = ""
                iconViews[index].isHidden = true
            }
        }
    }

    // NSWorkspace.icon(forFile:) 只认直接的 .app 路径;Helper 可执行文件在
    // .app 内部,需要向上找到最外层 .app(Chrome Helper → Chrome),
    // 显示名称按可执行路径缓存。
    private static func icon(for path: String?) -> NSImage {
        guard let path else { return fallbackIcon }
        if let cached = iconCache.object(forKey: path as NSString) { return cached }
        let icon: NSImage
        if let bundlePath = Self.outerAppBundle(of: path) {
            icon = NSWorkspace.shared.icon(forFile: bundlePath)
        } else {
            icon = NSWorkspace.shared.icon(forFile: path)
        }
        icon.size = NSSize(width: 14, height: 14)
        iconCache.setObject(icon, forKey: path as NSString)
        return icon
    }

    private static func outerAppBundle(of executablePath: String) -> String? {
        var accumulated = ""
        var found: String?
        for component in (executablePath as NSString).pathComponents {
            if component == "/" { accumulated = "/"; continue }
            accumulated = (accumulated as NSString).appendingPathComponent(component)
            if component.hasSuffix(".app") { found = accumulated }
        }
        return found
    }
}

// 磁盘弹窗的"高占用进程":图标/名称 + 读取/写入两列。
final class DiskProcessListView: NSView {
    private var rows: [(icon: NSImageView, name: NSTextField, read: NSTextField, write: NSTextField)] = []

    init(title: String, limit: Int) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = AppTheme.font(ofSize: 11, weight: .medium)
        titleLabel.textColor = AppTheme.secondaryText
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // 表头结构与数据行完全一致(icon 占位 14 + spacing 6 + 两列 62),保证对齐
        let iconPlaceholder = NSView()
        iconPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        let header = NSStackView(views: [iconPlaceholder])
        header.orientation = .horizontal
        header.spacing = 6
        header.distribution = .fill
        header.translatesAutoresizingMaskIntoConstraints = false
        header.arrangedSubviews[0].widthAnchor.constraint(equalToConstant: 14).isActive = true
        header.arrangedSubviews[0].heightAnchor.constraint(equalToConstant: 1).isActive = true

        let nameHeader = NSTextField(labelWithString: "进程")
        nameHeader.font = AppTheme.font(ofSize: 10)
        nameHeader.textColor = AppTheme.secondaryText.withAlphaComponent(0.7)
        let readHeader = NSTextField(labelWithString: "读取")
        readHeader.font = AppTheme.font(ofSize: 10)
        readHeader.textColor = NSColor(calibratedRed: 0.35, green: 0.62, blue: 1.0, alpha: 1)
        readHeader.alignment = .right
        let writeHeader = NSTextField(labelWithString: "写入")
        writeHeader.font = AppTheme.font(ofSize: 10)
        writeHeader.textColor = NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.35, alpha: 1)
        writeHeader.alignment = .right
        header.addArrangedSubview(nameHeader)
        header.addArrangedSubview(readHeader)
        header.addArrangedSubview(writeHeader)
        nameHeader.setContentHuggingPriority(.init(1), for: .horizontal)
        readHeader.widthAnchor.constraint(equalToConstant: 62).isActive = true
        writeHeader.widthAnchor.constraint(equalToConstant: 62).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false

        for _ in 0..<limit {
            let iconView = NSImageView()
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.setContentHuggingPriority(.required, for: .horizontal)
            let nameLabel = NSTextField(labelWithString: "")
            nameLabel.font = AppTheme.font(ofSize: 12)
            nameLabel.textColor = AppTheme.primaryText
            nameLabel.lineBreakMode = .byTruncatingTail
            // 弹性全部给名称,两列数值才能各就各位
            nameLabel.setContentHuggingPriority(.init(1), for: .horizontal)
            nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let readLabel = NSTextField(labelWithString: "")
            readLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            readLabel.textColor = AppTheme.secondaryText
            readLabel.alignment = .right
            readLabel.setContentHuggingPriority(.required, for: .horizontal)
            let writeLabel = NSTextField(labelWithString: "")
            writeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            writeLabel.textColor = AppTheme.secondaryText
            writeLabel.alignment = .right
            writeLabel.setContentHuggingPriority(.required, for: .horizontal)

            let row = NSStackView(views: [iconView, nameLabel, readLabel, writeLabel])
            row.orientation = .horizontal
            row.spacing = 6
            row.distribution = .fill
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            iconView.widthAnchor.constraint(equalToConstant: 14).isActive = true
            iconView.heightAnchor.constraint(equalToConstant: 14).isActive = true
            readLabel.widthAnchor.constraint(equalToConstant: 62).isActive = true
            writeLabel.widthAnchor.constraint(equalToConstant: 62).isActive = true
            rows.append((iconView, nameLabel, readLabel, writeLabel))
        }

        addSubview(titleLabel)
        addSubview(header)
        addSubview(stack)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),

            header.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.widthAnchor.constraint(equalTo: widthAnchor),

            stack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(samples: [DiskProcessSample]) {
        for (index, row) in rows.enumerated() {
            if index < samples.count {
                let sample = samples[index]
                row.name.stringValue = sample.name
                row.icon.image = ProcessListView.iconForExternalUse(for: sample.iconPath)
                row.icon.isHidden = false
                row.read.stringValue = Format.decimalBytes(sample.readBytesPerSecond, perSecond: true)
                row.write.stringValue = Format.decimalBytes(sample.writeBytesPerSecond, perSecond: true)
            } else {
                row.name.stringValue = ""
                row.icon.isHidden = true
                row.read.stringValue = ""
                row.write.stringValue = ""
            }
        }
    }
}


extension ProcessListView {
    /// 供其他视图复用的图标解析(含最外层 .app 归属与缓存)。
    static func iconForExternalUse(for path: String?) -> NSImage {
        icon(for: path)
    }
}
