import MeridianLocalization
import SwiftUI

struct CapturePage: View {
    @ObservedObject var model: CaptureModel
    @ObservedObject var preferences: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PermissionBanner(permission: .screenRecording, granted: model.permissionGranted) { model.requestPermission() }

            HStack(spacing: 10) {
                ActionTile(symbol: "viewfinder", title: L("区域截图", "Capture Area"), caption: key(.capture), tint: .blue) { model.capture() }
                ActionTile(symbol: "text.viewfinder", title: L("截图识字", "Capture Text"), caption: key(.ocr), tint: .purple) { model.captureOCR() }
                ActionTile(symbol: "pin", title: L("截图贴图", "Capture & Pin"), caption: key(.pin), tint: .pink) { model.capturePin() }
                ActionTile(symbol: model.gifRecording ? "stop.fill" : "record.circle",
                           title: model.gifRecording ? L("停止录制", "Stop Recording") : L("录制 GIF", "Record GIF"), caption: key(.gif), tint: .red,
                           active: model.gifRecording) { model.toggleGIF() }
            }
            HStack(spacing: 8) {
                ChipButton(symbol: "rectangle.inset.filled", title: L("全屏截图", "Full Screen")) { model.captureFullScreen() }
                ChipButton(symbol: "macwindow", title: L("当前窗口", "Window")) { model.captureWindow() }
                ChipButton(symbol: "arrow.counterclockwise", title: L("上次区域", "Last Area")) { model.captureLastArea() }
                ChipButton(symbol: "timer", title: L("3 秒后", "In 3 s")) { model.captureDelayed(3) }
                Spacer()
                ChipButton(symbol: "clock.arrow.circlepath", title: L("历史", "History")) { model.showHistory() }
                ChipButton(symbol: "photo", title: L("打开图片", "Open Image")) { model.openImage() }
            }

            Group2(title: L("快捷键", "Shortcuts"), footer: L("截图后可在选区工具条里标注、复制、保存、贴图或识字；按 Esc 取消。快捷键全局生效，不需要额外权限。", "After capturing, use the selection toolbar to annotate, copy, save, pin, or extract text; press Esc to cancel. Shortcuts work system-wide and need no extra permissions.")) {
                ForEach([HotKeyAction.capture, .ocr, .pin, .gif]) { action in
                    Row(title: action.title, detail: action.detail) {
                        HotKeyRecorder(action: action, preferences: preferences)
                    }
                }
            }

            Group2(title: L("输出", "Output")) {
                Row(title: L("复制时附带 PNG 文件", "Include PNG File When Copying"), detail: L("粘贴到 Finder 或聊天软件时得到一个图片文件", "Pasting into Finder or chat apps gives you an image file")) {
                    Toggle("", isOn: Binding(get: { model.copyImageAsFile }, commit: { model.update(["copyImageAsFile": $0]) }))
                        .toggleStyle(.switch).labelsHidden()
                }
                Row(title: L("快速保存到", "Quick Save To"), detail: model.quickSaveDirectory) {
                    Button(L("选择…", "Choose…")) { model.chooseQuickSaveDirectory() }
                }
                Row(title: L("保存尺寸", "Save Scale"), detail: L("Retina 屏上缩小可减小文件体积", "Scaling down on Retina displays makes files smaller")) {
                    Picker("", selection: Binding(get: { model.screenshotScale }, commit: { model.update(["screenshotScale": $0]) })) {
                        ForEach(CaptureModel.scaleOptions, id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
                    }
                    .labelsHidden().frame(width: 110)
                }
            }

            Group2(title: L("历史与贴图", "History & Pins")) {
                Row(title: L("保留最近的截图", "Keep Recent Screenshots"), detail: L("复制、保存和贴图的图片会自动留存在本机", "Copied, saved, and pinned images are kept on this Mac automatically")) {
                    Stepper(L("\(model.historyLimit) 张", "\(model.historyLimit)"), value: Binding(get: { model.historyLimit },
                                                                     commit: { model.update(["screenshotHistoryLimit": $0]) }),
                            in: 1...100)
                }
                Row(title: L("屏幕上的贴图", "Pins on Screen"), detail: model.pinCount == 0 ? L("当前没有贴图", "No pins right now") : L("当前 \(model.pinCount) 张", "\(model.pinCount) on screen")) {
                    HStack {
                        Button(L("全部显示", "Show All")) { model.showPins() }
                        Button(L("全部隐藏", "Hide All")) { model.hidePins() }
                        Button(L("全部关闭", "Close All")) { model.closePins() }
                    }
                    .disabled(model.pinCount == 0)
                }
            }

            Group2(title: L("GIF 录制", "GIF Recording"), footer: L("最长 30 秒；录制时屏幕上会出现停止按钮，也可以再按一次快捷键停止。", "Up to 30 seconds. A stop button appears on screen while recording, or press the shortcut again to stop.")) {
                Row(title: L("帧率", "Frame Rate")) {
                    Picker("", selection: Binding(get: { model.gifFPS }, commit: { model.update(["gifFramesPerSecond": $0]) })) {
                        ForEach(CaptureModel.gifFPSOptions, id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                }
                Row(title: L("最大宽度", "Maximum Width")) {
                    Picker("", selection: Binding(get: { model.gifWidth }, commit: { model.update(["gifMaximumWidth": $0]) })) {
                        ForEach(CaptureModel.gifWidthOptions, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                }
            }

            if let error = model.lastError {
                InlineMessage(text: error) { model.lastError = nil }
            }
        }
        .onAppear { model.refreshState() }
    }

    private func key(_ action: HotKeyAction) -> String? { preferences.hotKeys[action]?.displayString }
}
