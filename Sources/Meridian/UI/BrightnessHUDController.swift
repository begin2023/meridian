import AppKit
import DisplayLabKit
import SwiftUI

@MainActor
private final class BrightnessHUDState: ObservableObject {
    @Published var values: [BrightnessHUDValue] = []

    private(set) var isHovering = false
    private(set) var isDragging = false
    var onBrightnessChange: ((CGDirectDisplayID, Double) -> Void)?
    var onInteractionChange: (() -> Void)?

    var isInteracting: Bool { isHovering || isDragging }

    func setFraction(_ fraction: Double, for id: CGDirectDisplayID) {
        guard fraction.isFinite,
              values.contains(where: { $0.id == id }) else {
            return
        }
        let clamped = min(1, max(0, fraction))
        let targets = values.map(\.id)
        values = values.map {
            BrightnessHUDValue(id: $0.id, name: $0.name, fraction: clamped)
        }
        for target in targets {
            onBrightnessChange?(target, clamped)
        }
    }

    func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        onInteractionChange?()
    }

    func setDragging(_ dragging: Bool) {
        guard dragging != isDragging else { return }
        isDragging = dragging
        onInteractionChange?()
    }

    func resetInteraction() {
        isHovering = false
        isDragging = false
    }
}

@MainActor
private struct BrightnessHUDView: View {
    @ObservedObject var state: BrightnessHUDState

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.yellow)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(state.values.enumerated()), id: \.offset) { item in
                    let value = item.element
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(value.name).lineLimit(1)
                            Spacer(minLength: 18)
                            Text("\(Int((value.fraction * 100).rounded()))%")
                                .monospacedDigit().fontWeight(.semibold)
                        }
                        .font(.system(size: 11.5))
                        Slider(
                            value: Binding(
                                get: {
                                    state.values.first(where: { $0.id == value.id })?.fraction
                                        ?? value.fraction
                                },
                                set: { state.setFraction($0, for: value.id) }
                            ),
                            in: 0...1,
                            onEditingChanged: { state.setDragging($0) }
                        )
                        .controlSize(.small)
                        .frame(height: 14)
                        .tint(.yellow)
                        .accessibilityLabel("\(value.name) 亮度")
                        .accessibilityValue("\(Int((value.fraction * 100).rounded()))%")
                    }
                }
            }
            .frame(width: 220)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .padding(4)
        .fixedSize()
        .onHover { state.setHovering($0) }
    }
}

@MainActor
private final class BrightnessHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class BrightnessHUDController {
    private let state = BrightnessHUDState()
    private let panel: BrightnessHUDPanel
    private var dismissWork: DispatchWorkItem?

    init(onBrightnessChange: @escaping (CGDirectDisplayID, Double) -> Void) {
        panel = BrightnessHUDPanel(
            contentViewController: NSHostingController(rootView: BrightnessHUDView(state: state))
        )
        state.onBrightnessChange = onBrightnessChange
        state.onInteractionChange = { [weak self] in self?.refreshDismissal() }
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.setContentSize(NSSize(width: 320, height: 98))
    }

    func show(_ values: [BrightnessHUDValue]) {
        guard !values.isEmpty else { return }
        state.resetInteraction()
        state.values = values
        panel.setContentSize(NSSize(width: 320, height: CGFloat(58 + min(values.count, 3) * 42)))
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        if let screen {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2,
                                         y: frame.maxY - panel.frame.height - 36))
        }
        panel.orderFrontRegardless()
        scheduleDismiss()
    }

    private func refreshDismissal() {
        if state.isInteracting {
            dismissWork?.cancel()
            dismissWork = nil
        } else {
            scheduleDismiss()
        }
    }

    private func scheduleDismiss() {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
}
