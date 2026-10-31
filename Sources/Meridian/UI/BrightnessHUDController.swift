import AppKit
import DisplayLabKit
import SwiftUI

@MainActor
private final class BrightnessHUDState: ObservableObject {
    @Published var values: [BrightnessHUDValue] = []
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
                        ProgressView(value: min(1, max(0, value.fraction)))
                            .tint(.yellow)
                    }
                }
            }
            .frame(width: 205)
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
    }
}

@MainActor
final class BrightnessHUDController {
    private let state = BrightnessHUDState()
    private let panel: NSPanel
    private var dismissWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentViewController: NSHostingController(rootView: BrightnessHUDView(state: state)))
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.setContentSize(NSSize(width: 300, height: 92))
    }

    func show(_ values: [BrightnessHUDValue]) {
        guard !values.isEmpty else { return }
        state.values = values
        panel.setContentSize(NSSize(width: 300, height: CGFloat(54 + min(values.count, 3) * 38)))
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let screen {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2,
                                         y: frame.maxY - panel.frame.height - 36))
        }
        panel.orderFrontRegardless()
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25, execute: work)
    }
}
