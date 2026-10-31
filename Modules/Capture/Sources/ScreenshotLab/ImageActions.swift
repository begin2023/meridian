import AppKit
import UniformTypeIdentifiers

enum ImageActions {
    static func copyToPasteboard(
        _ image: CGImage,
        includeFile: Bool,
        pasteboard: NSPasteboard = .general
    ) throws {
        let nsImage = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
        pasteboard.clearContents()

        if includeFile, let fileURL = try? ImageOutput.makeTemporaryPNG(image) {
            pasteboard.writeObjects([nsImage, fileURL as NSURL])
        } else {
            pasteboard.writeObjects([nsImage])
        }
    }

    static func saveWithPanel(
        _ image: CGImage,
        completion: ((Result<URL, Error>) -> Void)? = nil
    ) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Screenshot-\(timestamp()).png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                return
            }
            do {
                try ImageOutput.write(image, to: url)
                completion?(.success(url))
            } catch {
                completion?(.failure(error))
            }
        }
    }

    static func quickSave(
        _ image: CGImage,
        to directory: URL
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent(
            "Screenshot-\(timestamp()).png"
        )
        try ImageOutput.write(image, to: url)
        return url
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
