import AppKit
import ImageIO

enum HistoryTest {
    static func run() {
        DispatchQueue.global(qos: .userInitiated).async {
            var lines: [String] = []
            var failures = 0
            func record(_ name: String, _ passed: Bool) {
                lines.append("\(passed ? "PASS" : "FAIL") \(name)")
                if !passed { failures += 1 }
            }
            @MainActor func descendants(_ view: NSView) -> [NSView] {
                [view] + view.subviews.flatMap(descendants)
            }
            func waitFor<T>(
                timeout: TimeInterval = 10,
                _ operation: (@escaping (Result<T, Error>) -> Void) -> Void
            ) -> Result<T, Error>? {
                let semaphore = DispatchSemaphore(value: 0)
                var output: Result<T, Error>?
                operation {
                    output = $0
                    semaphore.signal()
                }
                guard semaphore.wait(timeout: .now() + timeout) == .success else {
                    return nil
                }
                return output
            }
            func image(seed: Int, width: Int = 320, height: Int = 200) -> CGImage {
                let context = CGContext(
                    data: nil,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )!
                context.setFillColor(NSColor(
                    calibratedRed: CGFloat((seed * 37) % 255) / 255,
                    green: CGFloat((seed * 71) % 255) / 255,
                    blue: CGFloat((seed * 113) % 255) / 255,
                    alpha: 1
                ).cgColor)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.setFillColor(NSColor.white.withAlphaComponent(0.8).cgColor)
                context.fill(CGRect(x: 20, y: 20, width: 120 + seed, height: 42))
                return context.makeImage()!
            }
            func files(in directory: URL) -> [URL] {
                (try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []
            }

            let parent = FileManager.default.temporaryDirectory
                .appendingPathComponent("ScreenshotLab-HistoryTest-\(UUID().uuidString)", isDirectory: true)
            let root = parent.appendingPathComponent("History", isDirectory: true)
            let userSaved = root.appendingPathComponent("user-saved.png")
            defer { try? FileManager.default.removeItem(at: parent) }
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? ImageOutput.writePNG(image(seed: 999), to: userSaved)

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let firstDate = calendar.date(from: DateComponents(
                year: 2026, month: 10, day: 1, hour: 12
            ))!

            let store = ScreenshotHistoryStore(rootURL: root)
            record("store.defaultLimit", store.limit == 10)
            record("store.initialEmpty", store.entries.isEmpty)

            for index in 0..<12 {
                let date = calendar.date(byAdding: .day, value: index, to: firstDate)!
                let result = waitFor { completion in
                    store.add(image: image(seed: index), createdAt: date, completion: completion)
                }
                guard case .success = result else {
                    record("store.add.\(index)", false)
                    continue
                }
                record("store.add.\(index)", true)
            }
            let snapshot = store.entries
            record("store.defaultRetainsTen", snapshot.count == 10)
            record("store.newestFirst", snapshot.first?.createdAt ==
                calendar.date(byAdding: .day, value: 11, to: firstDate))
            record("store.thumbnailFiles", snapshot.count == 10 && snapshot.allSatisfy {
                FileManager.default.fileExists(atPath: $0.thumbnailURL.path)
                    && $0.thumbnailURL.pathExtension == "jpg"
            })
            let thumbnailsValid = snapshot.allSatisfy { entry in
                guard let source = CGImageSourceCreateWithURL(entry.thumbnailURL as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                        as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
                    return false
                }
                return max(width.intValue, height.intValue) <= 320
            }
            record("store.thumbnailDownsampled", thumbnailsValid)
            record("store.indexAtomicFile", FileManager.default.fileExists(
                atPath: root.appendingPathComponent("index.json").path
            ))

            let octoberThird = calendar.date(from: DateComponents(
                year: 2026, month: 10, day: 3, hour: 9
            ))!
            let octoberFifth = calendar.date(from: DateComponents(
                year: 2026, month: 10, day: 5, hour: 9
            ))!
            let filtered = ScreenshotHistoryStore.filter(
                snapshot,
                from: octoberThird,
                to: octoberFifth,
                calendar: calendar
            )
            record("filter.staticInclusiveDates", filtered.count == 3)
            let localCalendar = Calendar.current
            let localFilterDay = localCalendar.date(from: DateComponents(
                year: 2026, month: 10, day: 10, hour: 12
            ))!
            let instanceFiltered = store.filteredEntries(
                from: localFilterDay,
                to: localFilterDay,
                calendar: localCalendar
            )
            record("filter.instance", instanceFiltered.count == 1)

            var mutableSnapshot = store.entries
            mutableSnapshot.removeAll()
            record("entries.readOnlySnapshot", store.entries.count == 10)

            let restarted = ScreenshotHistoryStore(rootURL: root)
            record("restart.count", restarted.entries.count == 10)
            record("restart.limit", restarted.limit == 10)
            record("restart.order", restarted.entries.first?.id == snapshot.first?.id)

            let limitResult = waitFor { completion in
                restarted.setLimit(3, completion: completion)
            }
            if case .success(let limit) = limitResult {
                record("limit.setThree", limit == 3)
            } else {
                record("limit.setThree", false)
            }
            record("limit.storeCount", restarted.entries.count == 3)
            record("limit.imageFilesPruned",
                files(in: root.appendingPathComponent("Images")).count == 3)
            record("limit.thumbnailFilesPruned",
                files(in: root.appendingPathComponent("Thumbnails")).count == 3)
            record("limit.userSavedUntouched",
                FileManager.default.fileExists(atPath: userSaved.path))

            let restartedAgain = ScreenshotHistoryStore(rootURL: root)
            record("restart.limitPersisted", restartedAgain.limit == 3)
            record("restart.afterPrune", restartedAgain.entries.count == 3)

            let group = DispatchGroup()
            let lock = NSLock()
            var batchFailures = 0
            for index in 12..<16 {
                group.enter()
                let date = calendar.date(byAdding: .day, value: index, to: firstDate)!
                restartedAgain.add(image: image(seed: index), createdAt: date) { result in
                    lock.lock()
                    if case .failure = result { batchFailures += 1 }
                    lock.unlock()
                    group.leave()
                }
            }
            record("async.batchCompletes", group.wait(timeout: .now() + 15) == .success)
            record("async.batchNoErrors", batchFailures == 0)
            record("async.serialLimitApplied", restartedAgain.entries.count == 3)
            record("async.serialNewestFirst", restartedAgain.entries.map(\.createdAt) ==
                restartedAgain.entries.map(\.createdAt).sorted(by: >))

            let uiSemaphore = DispatchSemaphore(value: 0)
            var uiPassed = false
            DispatchQueue.main.async {
                let controller = ScreenshotHistoryWindowController(store: restartedAgain)
                guard let content = controller.window?.contentView else {
                    uiSemaphore.signal()
                    return
                }
                content.layoutSubtreeIfNeeded()
                if let representation = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: representation)
                    try? representation.representation(using: .png, properties: [:])?.write(
                        to: URL(fileURLWithPath: "/tmp/screenshotlab-history-window.png")
                    )
                }
                let views = descendants(content)
                let memoryNote = views.compactMap { $0 as? NSTextField }.first {
                    $0.identifier?.rawValue == "HistoryMemoryNote"
                }
                let table = views.compactMap { $0 as? NSTableView }.first {
                    $0.identifier?.rawValue == "HistoryTable"
                }
                let limitField = views.compactMap { $0 as? NSTextField }.first {
                    $0.identifier?.rawValue == "HistoryLimitField"
                }
                let stepper = views.compactMap { $0 as? NSStepper }.first {
                    $0.identifier?.rawValue == "HistoryLimitStepper"
                }
                uiPassed = controller.window?.title == "截图历史"
                    && controller.displayedEntries.count == 3
                    && memoryNote?.stringValue.contains("少量内存占用") == true
                    && table != nil
                    && limitField?.integerValue == 3
                    && stepper?.minValue == 1
                    && stepper?.maxValue == 100
                uiSemaphore.signal()
            }
            record("window.constructs", uiSemaphore.wait(timeout: .now() + 10) == .success)
            record("window.content", uiPassed)

            let deleteID = restartedAgain.entries.first!.id
            let deleteResult = waitFor { completion in
                restartedAgain.delete(id: deleteID, completion: completion)
            }
            if case .success = deleteResult {
                record("delete.entry", restartedAgain.entries.count == 2
                    && !restartedAgain.entries.contains { $0.id == deleteID })
            } else {
                record("delete.entry", false)
            }
            let clearResult = waitFor { completion in
                restartedAgain.clear(completion: completion)
            }
            if case .success = clearResult {
                record("clear.entries", restartedAgain.entries.isEmpty)
            } else {
                record("clear.entries", false)
            }
            record("clear.imageFiles", files(in: root.appendingPathComponent("Images")).isEmpty)
            record("clear.thumbnailFiles", files(in: root.appendingPathComponent("Thumbnails")).isEmpty)
            record("clear.userSavedUntouched",
                FileManager.default.fileExists(atPath: userSaved.path))

            lines.append(failures == 0 ? "HISTORY_TEST_PASS" : "HISTORY_TEST_FAIL")
            let report = lines.joined(separator: "\n") + "\n"
            try? report.write(
                to: URL(fileURLWithPath: "/tmp/screenshotlab-history-test.txt"),
                atomically: true,
                encoding: .utf8
            )
            DispatchQueue.main.async {
                exit(failures == 0 ? 0 : 1)
            }
        }
    }
}
