import SwiftUI

struct CapturePage: View {
    @ObservedObject var model: CaptureModel
    @ObservedObject var preferences: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PermissionBanner(permission: .screenRecording, granted: model.permissionGranted) { model.requestPermission() }

            HStack(spacing: 10) {
                ActionTile(symbol: "viewfinder", title: "区域截图", caption: key(.capture), tint: .blue) { model.capture() }
                ActionTile(symbol: "text.viewfinder", title: "截图识字", caption: key(.ocr), tint: .purple) { model.captureOCR() }
                ActionTile(symbol: "pin", title: "截图贴图", caption: key(.pin), tint: .pink) { model.capturePin() }
                ActionTile(symbol: model.gifRecording ? "stop.fill" : "record.circle",
                           title: model.gifRecording ? "停止录制" : "录制 GIF", caption: key(.gif), tint: .red,
                           active: model.gifRecording) { model.toggleGIF() }
            }
            HStack(spacing: 8) {
                ChipButton(symbol: "rectangle.inset.filled", title: "全屏截图") { model.captureFullScreen() }
                ChipButton(symbol: "macwindow", title: "当前窗口") { model.captureWindow() }
                ChipButton(symbol: "arrow.counterclockwise", title: "上次区域") { model.captureLastArea() }
                ChipButton(symbol: "timer", title: "3 秒后") { model.captureDelayed(3) }
                Spacer()
                ChipButton(symbol: "clock.arrow.circlepath", title: "历史") { model.showHistory() }
                ChipButton(symbol: "photo", title: "打开图片") { model.openImage() }
            }

            Group2(title: "快捷键", footer: "截图后可在选区工具条里标注、复制、保存、贴图或识字；按 Esc 取消。快捷键全局生效，不需要额外权限。") {
                ForEach([HotKeyAction.capture, .ocr, .pin, .gif]) { action in
                    Row(title: action.title, detail: action.detail) {
                        HotKeyRecorder(action: action, preferences: preferences)
                    }
                }
            }

            Group2(title: "输出") {
                Row(title: "复制时附带 PNG 文件", detail: "粘贴到 Finder 或聊天软件时得到一个图片文件") {
                    Toggle("", isOn: Binding(get: { model.copyImageAsFile }, commit: { model.update(["copyImageAsFile": $0]) }))
                        .toggleStyle(.switch).labelsHidden()
                }
                Row(title: "快速保存到", detail: model.quickSaveDirectory) {
                    Button("选择…") { model.chooseQuickSaveDirectory() }
                }
                Row(title: "保存尺寸", detail: "Retina 屏上缩小可减小文件体积") {
                    Picker("", selection: Binding(get: { model.screenshotScale }, commit: { model.update(["screenshotScale": $0]) })) {
                        ForEach(CaptureModel.scaleOptions, id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
                    }
                    .labelsHidden().frame(width: 110)
                }
            }

            Group2(title: "历史与贴图") {
                Row(title: "保留最近的截图", detail: "复制、保存和贴图的图片会自动留存在本机") {
                    Stepper("\(model.historyLimit) 张", value: Binding(get: { model.historyLimit },
                                                                     commit: { model.update(["screenshotHistoryLimit": $0]) }),
                            in: 1...100)
                }
                Row(title: "屏幕上的贴图", detail: model.pinCount == 0 ? "当前没有贴图" : "当前 \(model.pinCount) 张") {
                    HStack {
                        Button("全部显示") { model.showPins() }
                        Button("全部隐藏") { model.hidePins() }
                        Button("全部关闭") { model.closePins() }
                    }
                    .disabled(model.pinCount == 0)
                }
            }

            Group2(title: "GIF 录制", footer: "最长 30 秒；录制时屏幕上会出现停止按钮，也可以再按一次快捷键停止。") {
                Row(title: "帧率") {
                    Picker("", selection: Binding(get: { model.gifFPS }, commit: { model.update(["gifFramesPerSecond": $0]) })) {
                        ForEach(CaptureModel.gifFPSOptions, id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                }
                Row(title: "最大宽度") {
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
