import AppKit

final class CaptureController {
    var onEdit: ((CGImage) -> Void)?
    var onGIF: ((GIFCaptureRegion) -> Void)?
    var onPin: ((CGImage, CGRect?) -> Void)?
    var onCopy: ((CGImage) -> Void)?
    var onSave: ((CGImage) -> Void)?
    var onQuickSave: ((CGImage) -> Void)?
    var onOCR: ((CGImage, CGRect?) -> Void)?
    var onCaptured: ((CGImage) -> Void)?
    var onError: ((Error) -> Void)?

    private var overlayWindow: CaptureOverlayWindow?
    private var captureTask: Task<Void, Never>?
    private var delayedCaptureWorkItem: DispatchWorkItem?
    private var lastSelectionByDisplay: [CGDirectDisplayID: CGRect] = [:]

    var isCapturing: Bool {
        overlayWindow != nil || captureTask != nil || delayedCaptureWorkItem != nil
    }

    func beginCapture(
        usingLastSelection: Bool = false,
        fullScreen: Bool = false,
        forGIF: Bool = false,
        autoAction: CaptureAction? = nil
    ) {
        guard !isCapturing else {
            return
        }

        let allowed = ScreenCaptureService.requestPermissionIfNeeded()
        if !allowed {
            onError?(ScreenCaptureError.permissionDenied)
            return
        }

        captureTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                let snapshot = try await ScreenCaptureService.capture()
                guard !Task.isCancelled else {
                    return
                }
                self.captureTask = nil
                let initialSelection: CGRect?
                if fullScreen {
                    initialSelection = CGRect(
                        origin: .zero,
                        size: snapshot.screenFrame.size
                    )
                } else if usingLastSelection {
                    initialSelection = self.lastSelectionByDisplay[snapshot.displayID]
                } else {
                    initialSelection = nil
                }
                self.presentOverlay(snapshot: snapshot, initialSelection: initialSelection, forGIF: forGIF, autoAction: autoAction)
            } catch {
                self.captureTask = nil
                self.onError?(error)
            }
        }
    }

    func cancel() {
        delayedCaptureWorkItem?.cancel()
        delayedCaptureWorkItem = nil
        captureTask?.cancel()
        captureTask = nil
        overlayWindow?.close()
        overlayWindow = nil
    }

    func beginDelayedCapture(seconds: TimeInterval) {
        guard !isCapturing else {
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.delayedCaptureWorkItem = nil
            self.beginCapture()
        }
        delayedCaptureWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: workItem)
    }

    func beginWindowCapture(ownerPID: pid_t) {
        guard !isCapturing else {
            return
        }
        let allowed = ScreenCaptureService.requestPermissionIfNeeded()
        if !allowed {
            onError?(ScreenCaptureError.permissionDenied)
            return
        }

        captureTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                let image = try await ScreenCaptureService.captureWindow(ownerPID: ownerPID)
                guard !Task.isCancelled else {
                    return
                }
                self.captureTask = nil
                self.onEdit?(image)
            } catch {
                self.captureTask = nil
                self.onError?(error)
            }
        }
    }

    @MainActor
    func beginDemoCapture() {
        guard !isCapturing else {
            return
        }
        let snapshot = DebugFixtures.makeSnapshot()
        let selection = CGRect(
            x: 92,
            y: 130,
            width: min(980, snapshot.screenFrame.width - 184),
            height: min(620, snapshot.screenFrame.height - 260)
        )
        presentOverlay(snapshot: snapshot, initialSelection: selection)
    }

    private func presentOverlay(
        snapshot: ScreenSnapshot,
        initialSelection: CGRect?,
        forGIF: Bool = false,
        autoAction: CaptureAction? = nil
    ) {
        let window = CaptureOverlayWindow(
            snapshot: snapshot,
            initialSelection: initialSelection,
            forGIF: forGIF,
            autoAction: autoAction,
            onAction: { [weak self] action in
                self?.finish(snapshot: snapshot, action: action)
            },
            onCancel: { [weak self] in
                self?.cancel()
            }
        )
        overlayWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.overlayView)
#if DEBUG
        if CommandLine.arguments.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                window.overlayView.writeDebugSnapshot(
                    to: URL(fileURLWithPath: "/tmp/screenshotlab-overlay-offscreen.png")
                )
            }
        }
#endif
    }

    private func finish(snapshot: ScreenSnapshot, action: CaptureAction) {
        guard let window = overlayWindow else {
            return
        }
        let selection = window.overlayView.currentSelection
        guard !selection.isEmpty else {
            NSSound.beep()
            return
        }

        lastSelectionByDisplay[snapshot.displayID] = selection
        window.close()
        overlayWindow = nil

        if case .gif = action {
            onGIF?(
                GIFCaptureRegion(
                    displayID: snapshot.displayID,
                    screenFrame: snapshot.screenFrame,
                    selection: selection
                )
            )
            return
        }

        let cropStarted = DispatchTime.now().uptimeNanoseconds
        guard let image = ImageCropper.crop(
            snapshot: snapshot,
            localSelection: selection
        ) else {
            NSSound.beep()
            return
        }
        NSLog("[Capture] crop %dx%d in %.0f ms", image.width, image.height,
              Double(DispatchTime.now().uptimeNanoseconds - cropStarted) / 1_000_000)

        // The overlay view is screen-local; shift the selection into global
        // screen coordinates so pins and OCR panels can stay where the user
        // selected the region.
        let screenSelection = selection.offsetBy(
            dx: snapshot.screenFrame.minX,
            dy: snapshot.screenFrame.minY
        )

        onCaptured?(image)
        switch action {
        case .gif:
            break
        case .edit:
            onEdit?(image)
        case .pin:
            onPin?(image, screenSelection)
        case .copy:
            onCopy?(image)
        case .save:
            onSave?(image)
        case .quickSave:
            onQuickSave?(image)
        case .ocr:
            onOCR?(image, screenSelection)
        }
    }

    func beginFullScreenCapture() {
        beginCapture(fullScreen: true)
    }
}
