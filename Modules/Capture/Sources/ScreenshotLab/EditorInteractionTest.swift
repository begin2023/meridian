import AppKit

enum EditorInteractionTest {
    @MainActor
    static func run(presence: WindowPresenceController) {
        Task { @MainActor in
            var lines: [String] = []
            var failures = 0
            func record(_ name: String, _ passed: Bool) {
                lines.append("\(passed ? "PASS" : "FAIL") \(name)")
                if !passed { failures += 1 }
            }
            @MainActor func descendants(_ view: NSView) -> [NSView] {
                [view] + view.subviews.flatMap(descendants)
            }
            func key(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                    characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
            }
            @MainActor func mouse(_ type: NSEvent.EventType, at point: CGPoint, window: NSWindow) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }

            let controller = EditorWindowController(image: DebugFixtures.makeSampleImage())
            presence.register(controller.window)
            controller.show()
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let window = controller.window, let content = window.contentView else { exit(1) }
            record("switcher.regular", NSApp.activationPolicy() == .regular)
            record("window.standardTitlebar", !window.styleMask.contains(.fullSizeContentView))
            record("window.windowMenu", !window.isExcludedFromWindowsMenu)

            for width: CGFloat in [1100, 1280, 1440] {
                window.setContentSize(NSSize(width: width, height: 620))
                content.layoutSubtreeIfNeeded()
                content.layoutSubtreeIfNeeded()
                let views = descendants(content)
                let buttons = views.compactMap { $0 as? NSButton }.filter {
                    $0.identifier?.rawValue.hasPrefix("EditorTool.") == true
                        || $0.identifier?.rawValue.hasPrefix("EditorAction.") == true
                }
                record("layout.\(Int(width)).buttonCount", buttons.count == 15)
                record("layout.\(Int(width)).allIcons", buttons.allSatisfy { $0.image != nil && !$0.title.isEmpty })
                record("layout.\(Int(width)).inside", buttons.allSatisfy { button in
                    let rect = button.convert(button.bounds, to: content)
                    return content.bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect)
                })
                let tools = buttons.compactMap { $0 as? AnnotationToolButton }
                record("layout.\(Int(width)).fixedSlots", tools.allSatisfy {
                    $0.iconFrame.minY == 23 && $0.iconFrame.size == CGSize(width: 20, height: 20)
                        && $0.labelFrame.minY == 4 && $0.bounds.height == 48
                })
                record("layout.\(Int(width)).noDuplicateActions", !views.contains {
                    $0.identifier?.rawValue == "EditorMore"
                })
                let actions = buttons.compactMap { $0 as? AnnotationActionButton }
                record("layout.\(Int(width)).actionHeights", actions.count == 4 && actions.allSatisfy {
                    $0.bounds.height == 32 && $0.font?.pointSize == 13
                })
                for tool in [AnnotationTool.mosaic, .arrow, .text] {
                    controller.canvas.tool = tool
                    content.layoutSubtreeIfNeeded()
                    content.layoutSubtreeIfNeeded()
                    let controls = views.compactMap { $0 as? NSControl }.filter { !$0.isHiddenOrHasHiddenAncestor }
                    record("layout.\(Int(width)).\(tool.rawValue).controlsInside", controls.allSatisfy {
                        content.bounds.insetBy(dx: -0.5, dy: -0.5).contains($0.convert($0.bounds, to: content))
                    })
                    let optionControls = controls.filter { $0 is SizeTrackControl
                        || $0.identifier?.rawValue.hasPrefix("MosaicBlock.option.") == true }
                    record("layout.\(Int(width)).\(tool.rawValue).noActionOverlap", optionControls.allSatisfy { option in
                        let frame = option.convert(option.bounds, to: content)
                        return actions.allSatisfy { !frame.intersects($0.convert($0.bounds, to: content)) }
                    })
                }
                controller.canvas.tool = .select
                if let close = window.standardWindowButton(.closeButton) {
                    let closeRect = close.convert(close.bounds, to: nil)
                    record("layout.\(Int(width)).titlebarClear", buttons.allSatisfy { button in
                        !button.convert(button.bounds, to: nil).intersects(closeRect)
                    })
                }
                content.writeDebugPNG(to: URL(fileURLWithPath: "/tmp/screenshotlab-editor-\(Int(width)).png"))
            }

            let views = descendants(content)
            let buttons = views.compactMap { $0 as? NSButton }
            // The output actions always share the top row; a tool without
            // style options collapses the bar to a single row.
            @MainActor func actionRowDelta() -> CGFloat? {
                guard let tool = views.compactMap({ $0 as? AnnotationToolButton }).first,
                      let action = views.compactMap({ $0 as? AnnotationActionButton }).first else { return nil }
                let toolRect = tool.convert(tool.bounds, to: content)
                let actionRect = action.convert(action.bounds, to: content)
                return abs(toolRect.midY - actionRect.midY)
            }
            @MainActor func toolbarHeight() -> CGFloat? {
                views.compactMap { $0 as? EditorToolbarView }.first?.frame.height
            }
            for width: CGFloat in [1100, 1440] {
                window.setContentSize(NSSize(width: width, height: 620))
                content.layoutSubtreeIfNeeded()
                content.layoutSubtreeIfNeeded()
                record("toolbar.\(Int(width)).actionsTopRow", actionRowDelta().map { $0 < 20 } ?? false)
            }
            window.setContentSize(NSSize(width: 1440, height: 620))
            content.layoutSubtreeIfNeeded()
            content.layoutSubtreeIfNeeded()
            let collapsedHeight = toolbarHeight() ?? -1
            record("toolbar.selectCollapsed", abs(collapsedHeight - EditorToolbarView.compactHeight) < 0.5)
            controller.canvas.tool = .mosaic
            content.layoutSubtreeIfNeeded()
            content.layoutSubtreeIfNeeded()
            let expandedHeight = toolbarHeight() ?? -1
            record("toolbar.mosaicFullHeight", abs(expandedHeight - EditorToolbarView.fullHeight) < 0.5)
            controller.canvas.tool = .select
            content.layoutSubtreeIfNeeded()
            content.layoutSubtreeIfNeeded()
            for tool in AnnotationTool.allCases {
                if let button = buttons.first(where: { $0.identifier?.rawValue == "EditorTool.\(tool.rawValue)" }) {
                    button.performClick(nil)
                    record("tool.click.\(tool.rawValue)", controller.canvas.tool == tool)
                } else {
                    record("tool.click.\(tool.rawValue)", false)
                }
                controller.canvas.keyDown(with: key("v", code: 9))
                record("tool.shortcutSync.\(tool.rawValue)", controller.canvas.tool == .select
                    && buttons.first(where: { $0.identifier?.rawValue == "EditorTool.select" })?.state == .on)
            }
            controller.canvas.tool = .mosaic
            content.layoutSubtreeIfNeeded()
            content.writeDebugPNG(to: URL(fileURLWithPath: "/tmp/screenshotlab-editor-mosaic-options.png"))
            controller.canvas.tool = .arrow
            content.layoutSubtreeIfNeeded()
            content.writeDebugPNG(to: URL(fileURLWithPath: "/tmp/screenshotlab-editor-arrow-options.png"))
            controller.canvas.tool = .rectangle
            let canvas = controller.canvas
            let sizingControls = views.compactMap { $0 as? SizeTrackControl }
            record("size.noPopup", !views.contains { $0 is NSPopUpButton })
            for (tool, label, expected) in [
                (AnnotationTool.mosaic, "马赛克笔刷直径", CGFloat(128)),
                (.pen, "标注线宽", CGFloat(32)),
                (.text, "文字字号", CGFloat(64))
            ] {
                canvas.tool = tool
                content.layoutSubtreeIfNeeded()
                if let track = sizingControls.first(where: { $0.accessibilityLabel() == label }) {
                    let small = track.convert(track.nodeCenter(at: 0), to: nil)
                    let large = track.convert(track.nodeCenter(at: CGFloat(track.values.count - 1)), to: nil)
                    track.mouseDown(with: mouse(.leftMouseDown, at: small, window: window))
                    record("size.\(label).clickSmall", track.selectedIndex == 0)
                    track.mouseUp(with: mouse(.leftMouseUp, at: small, window: window))
                    try? await Task.sleep(nanoseconds: 230_000_000)
                    let smallDiameter = track.previewDiameter
                    track.mouseDown(with: mouse(.leftMouseDown, at: large, window: window))
                    track.mouseUp(with: mouse(.leftMouseUp, at: large, window: window))
                    let target = CGFloat(track.values.count - 1)
                    let reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    record("size.\(label).clickStartsAnimation", reducesMotion || track.displayedPosition < target)
                    try? await Task.sleep(nanoseconds: 75_000_000)
                    record("size.\(label).clickAnimatesPositionAndSize", reducesMotion
                        || (track.displayedPosition > 0 && track.displayedPosition < target
                            && track.previewDiameter > smallDiameter))
                    try? await Task.sleep(nanoseconds: 170_000_000)
                    record("size.\(label).clickSettles", abs(track.displayedPosition - target) < 0.01
                        && track.previewDiameter > smallDiameter * 3)
                    let middle = track.convert(track.nodeCenter(at: 2.35), to: nil)
                    track.mouseDown(with: mouse(.leftMouseDown, at: large, window: window))
                    track.mouseDragged(with: mouse(.leftMouseDragged, at: middle, window: window))
                    record("size.\(label).dragFollows", abs(track.selectedPosition - 2.35) < 0.01
                        && abs(track.displayedPosition - 2.35) < 0.01)
                    let interpolated = track.values[2] + (track.values[3] - track.values[2]) * 0.35
                    let actualMiddle = label == "马赛克笔刷直径" ? canvas.mosaicBrushSize
                        : label == "文字字号" ? canvas.textFontSize : canvas.strokeWidth
                    record("size.\(label).continuousSize", abs(actualMiddle - interpolated) < 0.01)
                    track.mouseUp(with: mouse(.leftMouseUp, at: middle, window: window))
                    record("size.\(label).releaseKeepsSize", abs(track.displayedPosition - 2.35) < 0.01)
                    // Recompute node coordinates: the live value label changes
                    // width as the value changes, shifting the track.
                    let dragStart = track.convert(track.nodeCenter(at: 0), to: nil)
                    let dragEnd = track.convert(track.nodeCenter(at: CGFloat(track.values.count - 1)), to: nil)
                    track.mouseDown(with: mouse(.leftMouseDown, at: dragStart, window: window))
                    track.mouseDragged(with: mouse(.leftMouseDragged, at: dragEnd, window: window))
                    track.mouseUp(with: mouse(.leftMouseUp, at: dragEnd, window: window))
                    let actual = label == "马赛克笔刷直径" ? canvas.mosaicBrushSize
                        : label == "文字字号" ? canvas.textFontSize : canvas.strokeWidth
                    record("size.\(label).dragUpdatesCanvas", actual == expected && !track.isHidden)
                    record("size.\(label).previewInside", track.trackWidth == 2
                        && track.bounds.contains(track.previewFrame))
                    track.keyDown(with: key("", code: 123))
                    record("size.\(label).keyboard", track.selectedIndex == track.values.count - 2)
                    _ = track.accessibilityPerformIncrement()
                    record("size.\(label).accessibility", track.selectedValue == expected)
                } else { record("size.\(label)", false) }
            }
            canvas.tool = .arrow
            content.layoutSubtreeIfNeeded()
            // The arrow no longer uses a continuous slider: three discrete
            // presets emit shaft width and head size together.
            if let presets = views.compactMap({ $0 as? ArrowPresetControl }).first {
                record("size.arrow.threePresets", !presets.isHidden
                    && presets.lineWidths == [2, 4, 8] && presets.headSizes == [12, 24, 40])
                record("size.arrow.noSlider", !sizingControls.contains {
                    $0.accessibilityLabel() == "箭头大小"
                })
                for (index, button) in presets.buttons.enumerated() {
                    button.performClick(nil)
                    record("size.arrow.preset.\(index)", presets.selectedIndex == index
                        && canvas.strokeWidth == presets.lineWidths[index]
                        && canvas.arrowHeadSize == presets.headSizes[index]
                        && presets.buttons.filter { $0.state == .on }.count == 1)
                }
                presets.select(index: 0, notify: true)
                presets.keyDown(with: key("", code: 124))
                record("size.arrow.keyboard", presets.selectedIndex == 1
                    && canvas.arrowHeadSize == presets.headSizes[1])
                presets.buttons[1].performClick(nil)
            } else {
                record("size.arrow.presets", false)
            }
            canvas.tool = .mosaic
            content.layoutSubtreeIfNeeded()
            if let grid = views.compactMap({ $0 as? MosaicBlockGridView }).first {
                let options = grid.optionButtons
                record("mosaic.grid.inlineTable", !grid.isHidden && options.count == 6
                    && Set(options.map { $0.frame.midY }).count == 2
                    && Set(options.map { $0.frame.midX }).count == 3)
                let brushSize = canvas.mosaicBrushSize
                for index in grid.values.indices {
                    options[index].performClick(nil)
                    record("mosaic.grid.click.\(index)", grid.selectedIndex == index
                        && canvas.mosaicBlockSize == grid.values[index]
                        && options.filter { $0.state == .on }.count == 1
                        && options[index].state == .on)
                }
                record("mosaic.grid.independentOfBrush", canvas.mosaicBrushSize == brushSize)
                record("mosaic.grid.accessibility", options.allSatisfy {
                    $0.accessibilityLabel()?.isEmpty == false && $0.toolTip != nil
                })
                record("mosaic.grid.onlyBrushSlides", sizingControls.filter { !$0.isHidden }.count == 1)
                if let track = sizingControls.first(where: { $0.sampleStyle == .mosaic }) {
                    let coarse = track.mosaicCellSize
                    options[0].performClick(nil)
                    record("mosaic.grid.previewTextureFollows", track.mosaicCellSize < coarse)
                }
                options[2].performClick(nil)
            } else { record("mosaic.grid.present", false) }
            if let well = views.compactMap({ $0 as? NSColorWell }).first {
                canvas.tool = .mosaic
                record("size.mosaic.noColor", well.isHiddenOrHasHiddenAncestor)
                record("size.mosaic.texture", sizingControls.filter { !$0.isHidden }.allSatisfy {
                    $0.sampleStyle == .mosaic
                })
                canvas.tool = .pen
                well.color = .systemBlue
                _ = well.sendAction(well.action, to: well.target)
                record("size.pen.currentColor", !well.isHidden && sizingControls.filter {
                    $0.sampleStyle == .ink
                }.allSatisfy { $0.inkColor == well.color } && canvas.strokeColor == well.color)
            }
            // Blur exposes a labelled strength preset row and no color.
            canvas.tool = .blur
            content.layoutSubtreeIfNeeded()
            content.layoutSubtreeIfNeeded()
            if let chips = views.compactMap({ $0 as? PresetChipControl }).first {
                record("blur.strengthOptions", !chips.isHidden
                    && chips.titles == ["弱", "中", "强"] && chips.buttons.count == 3)
                chips.buttons[2].performClick(nil)
                record("blur.strongSetsRadius", chips.selectedIndex == 2 && canvas.blurRadius == 36)
                chips.buttons[0].performClick(nil)
                record("blur.weakSetsRadius", canvas.blurRadius == 8)
                chips.buttons[1].performClick(nil)
                record("blur.mediumRestored", canvas.blurRadius == 18)
            } else {
                record("blur.strengthOptions", false)
            }
            record("blur.noColor", views.compactMap { $0 as? NSColorWell }.first.map {
                $0.isHiddenOrHasHiddenAncestor
            } ?? false)
            window.setContentSize(NSSize(width: 1100, height: 620))
            for tool in [AnnotationTool.mosaic, .arrow, .pen] {
                canvas.tool = tool
                window.makeFirstResponder(canvas)
                content.layoutSubtreeIfNeeded()
                try? await Task.sleep(nanoseconds: 250_000_000)
                content.writeDebugPNG(to: URL(fileURLWithPath: "/tmp/screenshotlab-editor-\(tool.rawValue)-options.png"))
            }
            canvas.tool = .mosaic
            if let track = sizingControls.first(where: { $0.sampleStyle == .mosaic }) {
                @MainActor func brushPreview(_ position: CGFloat, name: String) {
                    let point = track.convert(track.nodeCenter(at: position), to: nil)
                    track.mouseDragged(with: mouse(.leftMouseDragged, at: point, window: window))
                    content.writeDebugPNG(to: URL(fileURLWithPath: "/tmp/screenshotlab-editor-brush-\(name)-options.png"))
                }
                brushPreview(0, name: "small")
                brushPreview(2.35, name: "medium")
                brushPreview(CGFloat(track.values.count - 1), name: "large")
                let last = track.convert(track.nodeCenter(at: CGFloat(track.values.count - 1)), to: nil)
                track.mouseUp(with: mouse(.leftMouseUp, at: last, window: window))
            }
            canvas.strokeWidth = 4
            canvas.tool = .rectangle
            let start = canvas.convert(CGPoint(x: canvas.bounds.midX - 100, y: canvas.bounds.midY - 50), to: nil)
            let end = CGPoint(x: start.x + 160, y: start.y + 90)
            canvas.mouseDown(with: mouse(.leftMouseDown, at: start, window: window))
            canvas.mouseDragged(with: mouse(.leftMouseDragged, at: end, window: window))
            canvas.mouseUp(with: mouse(.leftMouseUp, at: end, window: window))
            record("annotation.draw", canvas.hasAnnotations && canvas.canUndo)
            window.makeFirstResponder(canvas)
            _ = window.performKeyEquivalent(with: key("z", code: 6, flags: .command))
            record("annotation.undo", !canvas.hasAnnotations && canvas.canRedo)
            _ = window.performKeyEquivalent(with: key("z", code: 6, flags: [.command, .shift]))
            record("annotation.redo", canvas.hasAnnotations)
            canvas.keyDown(with: key("", code: 53))
            record("annotation.escape", canvas.tool == .select)
            let center = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: start.x + 1, y: center.y), window: window))
            canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: start.x + 1, y: center.y), window: window))
            record("annotation.select", canvas.hasSelection)
            canvas.keyDown(with: key("", code: 51))
            record("annotation.delete", !canvas.hasAnnotations)
            // Esc with nothing left to cancel asks the window to exit.
            var escExitRequests = 0
            canvas.onRequestExit = { escExitRequests += 1 }
            canvas.keyDown(with: key("", code: 53))
            record("annotation.escIdleExits", escExitRequests == 1)
            canvas.onRequestExit = nil

            var actions: [EditorAction] = []
            controller.onAction = { action, _ in actions.append(action) }
            _ = window.performKeyEquivalent(with: key("c", code: 8, flags: .command))
            _ = window.performKeyEquivalent(with: key("s", code: 1, flags: .command))
            _ = window.performKeyEquivalent(with: key("s", code: 1, flags: [.command, .option]))
            record("commands.copySaveQuickSave", actions.count == 3)

            canvas.tool = .text
            canvas.mouseDown(with: mouse(.leftMouseDown, at: center, window: window))
            if let field = canvas.subviews.compactMap({ $0 as? NSTextField }).first {
                field.stringValue = "Pending text is included in exported image"
                let count = actions.count
                _ = window.performKeyEquivalent(with: key("c", code: 8, flags: .command))
                record("text.copyDoesNotExportImage", actions.count == count)
                controller.performAction(.copy)
                record("text.exportCommitsPendingText", canvas.hasAnnotations
                    && canvas.subviews.compactMap({ $0 as? NSTextField }).isEmpty)
            } else {
                record("text.inputField", false)
            }
            window.miniaturize(nil)
            try? await Task.sleep(nanoseconds: 300_000_000)
            record("switcher.minimizedStillRegular", NSApp.activationPolicy() == .regular)
            presence.bringForward()
            try? await Task.sleep(nanoseconds: 300_000_000)
            record("window.restore", !window.isMiniaturized && window.isVisible)
            window.close()
            try? await Task.sleep(nanoseconds: 300_000_000)
            record("switcher.accessoryWhenClosed", NSApp.activationPolicy() == .accessory)
            // Fine checkerboard makes every successful brush stroke measurable,
            // including horizontal/vertical strokes rejected by the old code.
            let context = CGContext(data: nil, width: 400, height: 240, bitsPerComponent: 8,
                bytesPerRow: 1600, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            for y in 0..<240 {
                for x in 0..<400 {
                    let bright: CGFloat = (x / 2 + y / 2) % 2 == 0 ? 0.1 : 0.7
                    context.setFillColor(NSColor(calibratedRed: bright + CGFloat(x % 37) / 200,
                        green: bright + CGFloat(y % 29) / 200, blue: bright, alpha: 1).cgColor)
                    context.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
            let fixture = context.makeImage()!
            func bytes(_ image: CGImage) -> Data {
                let rep = NSBitmapImageRep(cgImage: image)
                return Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh)
            }
            for (name, points) in [
                ("horizontal", [CGPoint(x: 80, y: 120), CGPoint(x: 300, y: 120)]),
                ("vertical", [CGPoint(x: 200, y: 40), CGPoint(x: 200, y: 200)]),
                ("click", [CGPoint(x: 200, y: 120)]),
                ("zigzag", [CGPoint(x: 80, y: 60), CGPoint(x: 280, y: 180), CGPoint(x: 90, y: 180)]),
                ("edge", [CGPoint(x: 0, y: 0), CGPoint(x: 400, y: 0)])
            ] {
                let testCanvas = AnnotationCanvasView(image: fixture)
                let testWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 456, height: 296),
                    styleMask: [.titled], backing: .buffered, defer: false)
                testWindow.isReleasedWhenClosed = false
                testWindow.contentView = testCanvas
                testCanvas.tool = .mosaic
                @MainActor func viewPoint(_ point: CGPoint) -> CGPoint {
                    testCanvas.convert(CGPoint(x: 28 + point.x, y: 28 + point.y), to: nil)
                }
                let before = testCanvas.renderFinalImage()
                testCanvas.mouseDown(with: mouse(.leftMouseDown, at: viewPoint(points[0]), window: testWindow))
                for point in points.dropFirst() {
                    testCanvas.mouseDragged(with: mouse(.leftMouseDragged, at: viewPoint(point), window: testWindow))
                }
                testCanvas.mouseUp(with: mouse(.leftMouseUp, at: viewPoint(points.last!), window: testWindow))
                let after = testCanvas.renderFinalImage()
                record("mosaic.\(name).changesPixels", testCanvas.hasAnnotations && bytes(before) != bytes(after))
                if name == "horizontal" {
                    let x = 80
                    let y = 120
                    let a = NSBitmapImageRep(cgImage: before).colorAt(x: x, y: y)!
                    let b = NSBitmapImageRep(cgImage: after).colorAt(x: x, y: y)!
                    record("mosaic.strokeStartCovered", a != b)
                }
                testCanvas.undo()
                record("mosaic.\(name).undo", bytes(before) == bytes(testCanvas.renderFinalImage()))
                testCanvas.redo()
                record("mosaic.\(name).redo", bytes(after) == bytes(testCanvas.renderFinalImage()))
                try? ImageOutput.writePNG(after, to: URL(fileURLWithPath: "/tmp/screenshotlab-mosaic-\(name).png"))
                testWindow.close()
            }
            let effectCanvas = AnnotationCanvasView(image: fixture)
            let effectWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 456, height: 296),
                styleMask: [.titled], backing: .buffered, defer: false)
            effectWindow.isReleasedWhenClosed = false
            effectWindow.contentView = effectCanvas
            @MainActor func paint(_ tool: AnnotationTool, from start: CGPoint, to end: CGPoint) {
                effectCanvas.tool = tool
                let a = effectCanvas.convert(CGPoint(x: 28 + start.x, y: 28 + start.y), to: nil)
                let b = effectCanvas.convert(CGPoint(x: 28 + end.x, y: 28 + end.y), to: nil)
                effectCanvas.mouseDown(with: mouse(.leftMouseDown, at: a, window: effectWindow))
                effectCanvas.mouseDragged(with: mouse(.leftMouseDragged, at: b, window: effectWindow))
                effectCanvas.mouseUp(with: mouse(.leftMouseUp, at: b, window: effectWindow))
            }
            effectCanvas.mosaicBrushSize = 12
            paint(.mosaic, from: CGPoint(x: 80, y: 120), to: CGPoint(x: 300, y: 120))
            let smallBrush = bytes(effectCanvas.renderFinalImage())
            effectCanvas.undo()
            effectCanvas.mosaicBrushSize = 96
            paint(.mosaic, from: CGPoint(x: 80, y: 120), to: CGPoint(x: 300, y: 120))
            let largeBrush = bytes(effectCanvas.renderFinalImage())
            let baseline = bytes(fixture)
            let smallChange = zip(baseline, smallBrush).filter { $0 != $1 }.count
            let largeChange = zip(baseline, largeBrush).filter { $0 != $1 }.count
            record("size.brushChangesCoverage", largeChange > smallChange * 3)
            effectCanvas.undo()
            effectCanvas.mosaicBlockSize = 4
            paint(.mosaic, from: CGPoint(x: 80, y: 120), to: CGPoint(x: 300, y: 120))
            let fineBlocks = bytes(effectCanvas.renderFinalImage())
            effectCanvas.undo()
            effectCanvas.mosaicBlockSize = 32
            paint(.mosaic, from: CGPoint(x: 80, y: 120), to: CGPoint(x: 300, y: 120))
            record("size.blockChangesResult", fineBlocks != bytes(effectCanvas.renderFinalImage()))
            effectCanvas.undo()
            for tool in [AnnotationTool.pen, .arrow] {
                effectCanvas.strokeWidth = 2
                effectCanvas.arrowHeadSize = 8
                paint(tool, from: CGPoint(x: 80, y: 120), to: CGPoint(x: 300, y: 120))
                let small = bytes(effectCanvas.renderFinalImage())
                effectCanvas.undo()
                effectCanvas.strokeWidth = 20
                effectCanvas.arrowHeadSize = 64
                paint(tool, from: CGPoint(x: 80, y: 120), to: CGPoint(x: 300, y: 120))
                record("size.\(tool.rawValue).changesPixels", small != bytes(effectCanvas.renderFinalImage()))
                effectCanvas.undo()
            }
            // WYSIWYG: style values are screen points, so the painted pixel
            // width shrinks by the display scale when the image is magnified.
            let wysiwygWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 470),
                styleMask: [.titled], backing: .buffered, defer: false)
            wysiwygWindow.isReleasedWhenClosed = false
            let wysiwygCanvas = AnnotationCanvasView(image: fixture)
            wysiwygWindow.contentView = wysiwygCanvas
            wysiwygWindow.contentView?.layoutSubtreeIfNeeded()
            let wysiwygScale = wysiwygCanvas.displayScale
            record("wysiwyg.scale", abs(wysiwygScale - 1.61) < 0.03)
            func changedRowCount(_ before: CGImage, _ after: CGImage, column x: Int) -> Int {
                let a = NSBitmapImageRep(cgImage: before)
                let b = NSBitmapImageRep(cgImage: after)
                var count = 0
                for y in 0..<a.pixelsHigh where a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) {
                    count += 1
                }
                return count
            }
            @MainActor func strokeExtent(_ canvas: AnnotationCanvasView, tool: AnnotationTool,
                                         from start: CGPoint, to end: CGPoint, column x: Int,
                                         window: NSWindow) -> Int {
                let before = canvas.renderFinalImage()
                canvas.tool = tool
                let a = canvas.convert(CGPoint(x: 28 + start.x, y: 28 + start.y), to: nil)
                let b = canvas.convert(CGPoint(x: 28 + end.x, y: 28 + end.y), to: nil)
                canvas.mouseDown(with: mouse(.leftMouseDown, at: a, window: window))
                canvas.mouseDragged(with: mouse(.leftMouseDragged, at: b, window: window))
                canvas.mouseUp(with: mouse(.leftMouseUp, at: b, window: window))
                let count = changedRowCount(before, canvas.renderFinalImage(), column: x)
                canvas.undo()
                return count
            }
            wysiwygCanvas.strokeWidth = 32
            let penExtent = strokeExtent(wysiwygCanvas, tool: .pen,
                from: CGPoint(x: 80, y: 120), to: CGPoint(x: 300, y: 120), column: 190, window: wysiwygWindow)
            record("wysiwyg.penMatchesScale", abs(CGFloat(penExtent) - 32 / wysiwygScale) <= 3)
            wysiwygCanvas.mosaicBrushSize = 96
            let mosaicExtent = strokeExtent(wysiwygCanvas, tool: .mosaic,
                from: CGPoint(x: 80, y: 120), to: CGPoint(x: 300, y: 120), column: 190, window: wysiwygWindow)
            record("wysiwyg.mosaicMatchesScale", abs(CGFloat(mosaicExtent) - 96 / wysiwygScale) <= 5)
            // Blur with the selected strength visibly changes the region.
            effectCanvas.blurRadius = 36
            let blurExtent = strokeExtent(effectCanvas, tool: .blur,
                from: CGPoint(x: 60, y: 60), to: CGPoint(x: 200, y: 180), column: 130, window: effectWindow)
            record("blur.regionChangesPixels", blurExtent > 0)
            wysiwygWindow.close()
            effectCanvas.tool = .text
            let textPoint = effectCanvas.convert(CGPoint(x: 90, y: 150), to: nil)
            effectCanvas.mouseDown(with: mouse(.leftMouseDown, at: textPoint, window: effectWindow))
            effectCanvas.subviews.compactMap { $0 as? NSTextField }.first?.stringValue = "Secret 12345"
            let textBefore = bytes(effectCanvas.renderFinalImage())
            effectCanvas.mosaicBrushSize = 64
            paint(.mosaic, from: CGPoint(x: 60, y: 110), to: CGPoint(x: 340, y: 110))
            let textAfter = effectCanvas.renderFinalImage()
            record("mosaic.coversAddedText", textBefore != bytes(textAfter))
            try? ImageOutput.writePNG(textAfter, to: URL(fileURLWithPath: "/tmp/screenshotlab-mosaic-added-text.png"))
            effectWindow.close()
            lines.append(failures == 0 ? "EDITOR_INTERACTION_PASS" : "EDITOR_INTERACTION_FAIL")
            try? (lines.joined(separator: "\n") + "\n").write(
                to: URL(fileURLWithPath: "/tmp/screenshotlab-editor-interaction.txt"), atomically: true, encoding: .utf8
            )
            exit(failures == 0 ? 0 : 1)
        }
    }
}
