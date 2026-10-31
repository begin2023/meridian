import AppKit

final class SavedFileWindowController: NSWindowController {
    private let fileURL: URL
    private let previewView = NSImageView()
    private let pathLabel = NSTextField(labelWithString: "")

    init(fileURL: URL) {
        self.fileURL = fileURL
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 520, height: 410),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = fileURL.pathExtension.lowercased() == "gif" ? "GIF 已保存" : "截图已保存"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildInterface()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
#if DEBUG
        if CommandLine.arguments.contains("--demo-saved-file") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.window?.contentView?.writeDebugPNG(
                    to: URL(fileURLWithPath: "/tmp/screenshotlab-saved-file.png")
                )
            }
        }
#endif
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }

        let heading = NSTextField(labelWithString: fileURL.pathExtension.lowercased() == "gif" ? "GIF 已保存" : "截图已保存")
        heading.font = AppTheme.font(ofSize: 18, weight: .semibold)

        pathLabel.stringValue = fileURL.lastPathComponent
        pathLabel.font = AppTheme.font(ofSize: 12, weight: .medium)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.toolTip = fileURL.path

        previewView.image = NSImage(contentsOf: fileURL)
        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.animates = fileURL.pathExtension.lowercased() == "gif"
        previewView.wantsLayer = true
        previewView.layer?.backgroundColor = NSColor.black.cgColor
        previewView.layer?.cornerRadius = 6
        previewView.layer?.masksToBounds = true

        let previewContainer = NSView()
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(previewView)
        NSLayoutConstraint.activate([
            previewView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            previewView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            previewView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
        ])

        let playButton = NSButton(
            title: fileURL.pathExtension.lowercased() == "gif" ? "播放 GIF" : "查看截图",
            target: self,
            action: #selector(openFile)
        )
        playButton.bezelStyle = .rounded
        playButton.keyEquivalent = "\r"

        let finderButton = NSButton(title: "在 Finder 中显示", target: self, action: #selector(showInFinder))
        finderButton.bezelStyle = .rounded

        let copyButton = NSButton(title: "复制文件", target: self, action: #selector(copyFile))
        copyButton.bezelStyle = .rounded

        let actions = NSStackView(views: [copyButton, finderButton, playButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8

        for view in [heading, pathLabel, previewContainer, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        previewContainer.wantsLayer = true
        previewContainer.layer?.backgroundColor = NSColor.black.cgColor
        previewContainer.layer?.cornerRadius = 6
        previewContainer.layer?.masksToBounds = true
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            heading.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            pathLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            pathLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            pathLabel.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            previewContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            previewContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            previewContainer.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 10),
            previewContainer.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -12),
            previewView.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            previewView.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
            previewView.widthAnchor.constraint(lessThanOrEqualTo: previewContainer.widthAnchor, constant: -16),
            previewView.heightAnchor.constraint(lessThanOrEqualTo: previewContainer.heightAnchor, constant: -16),
            actions.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            actions.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            actions.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    @objc private func openFile() {
        NSWorkspace.shared.open(fileURL)
    }

    @objc private func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    @objc private func copyFile() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])
    }
}
