import AppKit

enum PinInteractionTest {
    @MainActor
    static func run() {
        let controller = PinWindowController(image: DebugFixtures.makeSampleImage())
        var closeCallbacks = 0
        controller.onClose = { closeCallbacks += 1 }
        controller.show()
        guard let window = controller.window, let content = window.contentView else {
            writeReport("PIN_INTERACTION_FAIL\nmissing pin window\n")
            exit(1)
        }
        content.layoutSubtreeIfNeeded()
        let point = CGPoint(x: content.bounds.midX, y: content.bounds.midY)
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: content.convert(point, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 2,
            pressure: 1
        )!
        content.mouseDown(with: event)

        let closed = !window.isVisible && closeCallbacks > 0

        // A focused pin also closes on Esc.
        let escController = PinWindowController(image: DebugFixtures.makeSampleImage())
        var escCallbacks = 0
        escController.onClose = { escCallbacks += 1 }
        escController.show()
        guard let escWindow = escController.window, let escContent = escWindow.contentView else {
            writeReport("PIN_INTERACTION_FAIL\nmissing esc pin window\n")
            exit(1)
        }
        escWindow.makeKey()
        let escEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: escWindow.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        )!
        escContent.keyDown(with: escEvent)
        let escClosed = !escWindow.isVisible && escCallbacks > 0

        // Dragging moves the window by exactly the mouse delta (manual drag,
        // no system drag session).
        let dragController = PinWindowController(image: DebugFixtures.makeSampleImage())
        dragController.show()
        guard let dragWindow = dragController.window, let dragContent = dragWindow.contentView else {
            writeReport("PIN_INTERACTION_FAIL\nmissing drag pin window\n")
            exit(1)
        }
        let dragFrameBefore = dragWindow.frame
        let grabPoint = CGPoint(x: dragContent.bounds.midX, y: dragContent.bounds.midY)
        func mouse(_ type: NSEvent.EventType, at point: CGPoint, clicks: Int) -> NSEvent {
            NSEvent.mouseEvent(
                with: type,
                location: dragContent.convert(point, to: nil),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: dragWindow.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: clicks,
                pressure: 1
            )!
        }
        dragContent.mouseDown(with: mouse(.leftMouseDown, at: grabPoint, clicks: 1))
        dragContent.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: grabPoint.x + 60, y: grabPoint.y - 40), clicks: 1))
        dragContent.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: grabPoint.x + 60, y: grabPoint.y - 40), clicks: 1))
        let movedFrame = dragWindow.frame
        let dragPassed = abs(movedFrame.minX - dragFrameBefore.minX - 60) <= 1
            && abs(movedFrame.minY - dragFrameBefore.minY + 40) <= 1

        // Scroll zoom: one wheel notch = exactly one 1.1 step, anchored.
        let zoomBefore = dragWindow.frame.width
        func scroll(_ deltaY: CGFloat) -> NSEvent? {
            guard let cg = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .line,
                wheelCount: 1,
                wheel1: Int32(deltaY),
                wheel2: 0,
                wheel3: 0
            ) else { return nil }
            let global = dragWindow.convertToScreen(CGRect(origin: grabPoint, size: .zero)).origin
            cg.location = CGPoint(x: global.x, y:NSScreen.screens[0].frame.maxY - global.y)
            return NSEvent(cgEvent: cg)
        }
        if let event = scroll(10) {
            dragContent.scrollWheel(with: event)
        }
        if let event = scroll(10) {
            dragContent.scrollWheel(with: event)
        }
        let zoomAfter = dragWindow.frame.width
        #if DEBUG
        print("DBG-TEST zoomBefore=\(zoomBefore) zoomAfter=\(zoomAfter) expected=\(zoomBefore * 1.1 * 1.1)")
        #endif
        let zoomPassed = abs(zoomAfter - zoomBefore * 1.1 * 1.1) <= 3

        let passed = closed && escClosed && dragPassed && zoomPassed
        let report = """
        \(closed ? "PASS" : "FAIL") pin.doubleClickCloses
        \(escClosed ? "PASS" : "FAIL") pin.escCloses
        \(dragPassed ? "PASS" : "FAIL") pin.dragMoves
        \(zoomPassed ? "PASS" : "FAIL") pin.scrollStepZoom
        \(passed ? "PIN_INTERACTION_PASS" : "PIN_INTERACTION_FAIL")
        """
        writeReport(report + "\n")
        exit(passed ? 0 : 1)
    }

    private static func writeReport(_ text: String) {
        try? text.write(
            to: URL(fileURLWithPath: "/tmp/screenshotlab-pin-interaction.txt"),
            atomically: true,
            encoding: .utf8
        )
    }
}
