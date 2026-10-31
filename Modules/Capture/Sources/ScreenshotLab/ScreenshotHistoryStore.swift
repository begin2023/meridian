import AppKit
import ImageIO
import UniformTypeIdentifiers

struct ScreenshotHistoryEntry: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let imageURL: URL
    let thumbnailURL: URL
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int64
}

enum ScreenshotHistoryError: LocalizedError {
    case cannotCreateDirectory
    case imageEncodingFailed
    case thumbnailEncodingFailed
    case indexEncodingFailed
    case imageDecodingFailed

    var errorDescription: String? {
        switch self {
        case .cannotCreateDirectory:
            return "无法创建截图历史目录。"
        case .imageEncodingFailed:
            return "无法写入截图历史图片。"
        case .thumbnailEncodingFailed:
            return "无法生成截图历史缩略图。"
        case .indexEncodingFailed:
            return "无法写入截图历史索引。"
        case .imageDecodingFailed:
            return "无法读取截图历史图片。"
        }
    }
}

/// Disk-backed screenshot history. Full-size images never remain in memory
/// after a write completes; the history window only borrows a downsampled
/// preview and small thumbnails.
final class ScreenshotHistoryStore {
    static let defaultLimit = 10
    static let minimumLimit = 1
    static let maximumLimit = 100
    static let dataRootEnvironmentKey = "MERIDIAN_CAPTURE_DATA_ROOT"

    var onChange: (([ScreenshotHistoryEntry]) -> Void)?
    var onError: ((Error) -> Void)?

    let rootURL: URL
    private let imagesURL: URL
    private let thumbnailsURL: URL
    private let indexURL: URL
    private let queue = DispatchQueue(label: "app.meridian.screenshot.history", qos: .utility)
    private let stateLock = NSLock()
    private var storedEntries: [ScreenshotHistoryEntry] = []
    private var storedLimit = ScreenshotHistoryStore.defaultLimit

    init(rootURL: URL? = nil) {
        let root = rootURL ?? Self.defaultRootURL()
        self.rootURL = root
        imagesURL = root.appendingPathComponent("Images", isDirectory: true)
        thumbnailsURL = root.appendingPathComponent("Thumbnails", isDirectory: true)
        indexURL = root.appendingPathComponent("index.json")
        queue.sync { loadFromDisk() }
    }

    var entries: [ScreenshotHistoryEntry] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedEntries
    }

    var limit: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedLimit
    }

    /// The image is encoded and indexed on a serial utility queue. Completion
    /// and all callbacks are delivered on the main queue.
    func add(
        image: CGImage,
        createdAt: Date = Date(),
        completion: ((Result<ScreenshotHistoryEntry, Error>) -> Void)? = nil
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.write(image: image, createdAt: createdAt) }
            switch result {
            case .success:
                self.notifyChange()
            case .failure(let error):
                self.notify(error: error)
            }
            self.deliver(result, completion: completion)
        }
    }

    func setLimit(
        _ requestedLimit: Int,
        completion: ((Result<Int, Error>) -> Void)? = nil
    ) {
        let limit = Self.clampedLimit(requestedLimit)
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.updateLimit(limit) }
            if case .success = result {
                self.notifyChange()
            } else if case .failure(let error) = result {
                self.notify(error: error)
            }
            self.deliver(result, completion: completion)
        }
    }

    func delete(
        id: UUID,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.deleteEntry(id: id) }
            if case .success = result {
                self.notifyChange()
            } else if case .failure(let error) = result {
                self.notify(error: error)
            }
            self.deliver(result, completion: completion)
        }
    }

    func clear(completion: ((Result<Void, Error>) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.clearEntries() }
            if case .success = result {
                self.notifyChange()
            } else if case .failure(let error) = result {
                self.notify(error: error)
            }
            self.deliver(result, completion: completion)
        }
    }

    func filteredEntries(
        from: Date?,
        to: Date?,
        calendar: Calendar = .current
    ) -> [ScreenshotHistoryEntry] {
        Self.filter(entries, from: from, to: to, calendar: calendar)
    }

    /// Date filters are inclusive whole days in the supplied calendar.
    static func filter(
        _ entries: [ScreenshotHistoryEntry],
        from: Date?,
        to: Date?,
        calendar: Calendar = .current
    ) -> [ScreenshotHistoryEntry] {
        let lowerBound = from.map { calendar.startOfDay(for: $0) }
        let upperBound = to.flatMap {
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0))
        }
        return entries.filter { entry in
            if let lowerBound, entry.createdAt < lowerBound { return false }
            if let upperBound, entry.createdAt >= upperBound { return false }
            return true
        }
    }

    private static func defaultRootURL() -> URL {
        if let rawRoot = ProcessInfo.processInfo.environment[
            dataRootEnvironmentKey
        ]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawRoot.isEmpty {
            let dataRoot = URL(
                fileURLWithPath: (rawRoot as NSString).expandingTildeInPath,
                isDirectory: true
            ).standardizedFileURL
            return dataRoot.appendingPathComponent(
                "History",
                isDirectory: true
            )
        }
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("ScreenshotLab", isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
    }

    private static func clampedLimit(_ value: Int) -> Int {
        min(maximumLimit, max(minimumLimit, value))
    }

    @discardableResult
    private func write(image: CGImage, createdAt: Date) throws -> ScreenshotHistoryEntry {
        try createDirectories()
        let id = UUID()
        let imageURL = imagesURL.appendingPathComponent("\(id.uuidString).png")
        let thumbnailURL = thumbnailsURL.appendingPathComponent("\(id.uuidString).jpg")
        do {
            try ImageOutput.writePNG(image, to: imageURL)
        } catch {
            try? FileManager.default.removeItem(at: imageURL)
            throw ScreenshotHistoryError.imageEncodingFailed
        }
        do {
            try writeThumbnail(from: imageURL, to: thumbnailURL)
        } catch {
            try? FileManager.default.removeItem(at: imageURL)
            try? FileManager.default.removeItem(at: thumbnailURL)
            throw ScreenshotHistoryError.thumbnailEncodingFailed
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: imageURL.path)
        let byteCount = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let entry = ScreenshotHistoryEntry(
            id: id,
            createdAt: createdAt,
            imageURL: imageURL,
            thumbnailURL: thumbnailURL,
            pixelWidth: image.width,
            pixelHeight: image.height,
            byteCount: byteCount
        )

        let current = entries
        let candidate = Array(([entry] + current).sorted(by: Self.newestFirst)
            .prefix(limit))
        do {
            try persist(entries: candidate, limit: limit)
        } catch {
            try? FileManager.default.removeItem(at: imageURL)
            try? FileManager.default.removeItem(at: thumbnailURL)
            throw ScreenshotHistoryError.indexEncodingFailed
        }
        replaceEntries(candidate)
        removeFiles(notPresentIn: candidate)
        return entry
    }

    @discardableResult
    private func updateLimit(_ limit: Int) throws -> Int {
        let current = entries
        let candidate = Array(current.prefix(limit))
        try persist(entries: candidate, limit: limit)
        replaceEntries(candidate)
        stateLock.lock()
        storedLimit = limit
        stateLock.unlock()
        removeFiles(notPresentIn: candidate)
        return limit
    }

    private func deleteEntry(id: UUID) throws {
        let current = entries
        guard let entry = current.first(where: { $0.id == id }) else { return }
        let candidate = current.filter { $0.id != id }
        try persist(entries: candidate, limit: limit)
        replaceEntries(candidate)
        try? FileManager.default.removeItem(at: entry.imageURL)
        try? FileManager.default.removeItem(at: entry.thumbnailURL)
    }

    private func clearEntries() throws {
        let current = entries
        try persist(entries: [], limit: limit)
        replaceEntries([])
        for entry in current {
            try? FileManager.default.removeItem(at: entry.imageURL)
            try? FileManager.default.removeItem(at: entry.thumbnailURL)
        }
    }

    private func createDirectories() throws {
        let fileManager = FileManager.default
        do {
            for directory in [rootURL, imagesURL, thumbnailsURL] {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
        } catch {
            throw ScreenshotHistoryError.cannotCreateDirectory
        }
    }

    private func writeThumbnail(from sourceURL: URL, to destinationURL: URL) throws {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            throw ScreenshotHistoryError.thumbnailEncodingFailed
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 320,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ), let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ScreenshotHistoryError.thumbnailEncodingFailed
        }
        CGImageDestinationAddImage(
            destination,
            thumbnail,
            [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenshotHistoryError.thumbnailEncodingFailed
        }
    }

    private func persist(entries: [ScreenshotHistoryEntry], limit: Int) throws {
        try createDirectories()
        let diskEntries = entries.map {
            DiskEntry(
                id: $0.id,
                createdAt: $0.createdAt,
                imageFilename: $0.imageURL.lastPathComponent,
                thumbnailFilename: $0.thumbnailURL.lastPathComponent,
                pixelWidth: $0.pixelWidth,
                pixelHeight: $0.pixelHeight,
                byteCount: $0.byteCount
            )
        }
        let index = DiskIndex(version: 1, limit: limit, entries: diskEntries)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(index) else {
            throw ScreenshotHistoryError.indexEncodingFailed
        }
        do {
            try data.write(to: indexURL, options: .atomic)
        } catch {
            throw ScreenshotHistoryError.indexEncodingFailed
        }
    }

    private func loadFromDisk() {
        do {
            try createDirectories()
            guard FileManager.default.fileExists(atPath: indexURL.path) else {
                replaceEntries([])
                stateLock.lock()
                storedLimit = Self.defaultLimit
                stateLock.unlock()
                return
            }
            let data = try Data(contentsOf: indexURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let index = try decoder.decode(DiskIndex.self, from: data)
            let limit = Self.clampedLimit(index.limit)
            let loaded = index.entries.compactMap { disk -> ScreenshotHistoryEntry? in
                let imageURL = imagesURL.appendingPathComponent(disk.imageFilename)
                let thumbnailURL = thumbnailsURL.appendingPathComponent(disk.thumbnailFilename)
                guard FileManager.default.fileExists(atPath: imageURL.path) else {
                    return nil
                }
                if !FileManager.default.fileExists(atPath: thumbnailURL.path) {
                    try? writeThumbnail(from: imageURL, to: thumbnailURL)
                }
                return ScreenshotHistoryEntry(
                    id: disk.id,
                    createdAt: disk.createdAt,
                    imageURL: imageURL,
                    thumbnailURL: thumbnailURL,
                    pixelWidth: disk.pixelWidth,
                    pixelHeight: disk.pixelHeight,
                    byteCount: disk.byteCount
                )
            }
            .sorted(by: Self.newestFirst)
            let retained = Array(loaded.prefix(limit))
            replaceEntries(retained)
            stateLock.lock()
            storedLimit = limit
            stateLock.unlock()
            if retained.count != loaded.count || index.limit != limit {
                try? persist(entries: retained, limit: limit)
            }
            removeFiles(notPresentIn: retained)
        } catch {
            replaceEntries([])
            stateLock.lock()
            storedLimit = Self.defaultLimit
            stateLock.unlock()
            notify(error: error)
        }
    }

    private func replaceEntries(_ entries: [ScreenshotHistoryEntry]) {
        stateLock.lock()
        storedEntries = entries
        stateLock.unlock()
    }

    private func removeFiles(notPresentIn retained: [ScreenshotHistoryEntry]) {
        let retainedImageNames = Set(retained.map { $0.imageURL.lastPathComponent })
        let retainedThumbnailNames = Set(retained.map { $0.thumbnailURL.lastPathComponent })
        let fileManager = FileManager.default
        for directory in [imagesURL, thumbnailsURL] {
            let retainedNames = directory == imagesURL ? retainedImageNames : retainedThumbnailNames
            let files = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            for file in files where !retainedNames.contains(file.lastPathComponent) {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    private static func newestFirst(
        _ lhs: ScreenshotHistoryEntry,
        _ rhs: ScreenshotHistoryEntry
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id.uuidString > rhs.id.uuidString
    }

    private func notifyChange() {
        let snapshot = entries
        DispatchQueue.main.async { [weak self] in
            self?.onChange?(snapshot)
        }
    }

    private func notify(error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onError?(error)
        }
    }

    private func deliver<T>(
        _ result: Result<T, Error>,
        completion: ((Result<T, Error>) -> Void)?
    ) {
        guard let completion else { return }
        DispatchQueue.main.async { completion(result) }
    }
}

private struct DiskIndex: Codable {
    let version: Int
    let limit: Int
    let entries: [DiskEntry]
}

private struct DiskEntry: Codable {
    let id: UUID
    let createdAt: Date
    let imageFilename: String
    let thumbnailFilename: String
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int64
}
