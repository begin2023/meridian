import AppKit
import Carbon.HIToolbox

/// 全局快捷键对应的动作。由宿主统一注册，执行交给各功能。
enum HotKeyAction: String, CaseIterable, Identifiable {
    case capture
    case ocr
    case pin
    case gif
    case toggleScroll
    case controlCenter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .capture: return "截图"
        case .ocr: return "截图识字"
        case .pin: return "截图并贴图"
        case .gif: return "录制 GIF"
        case .toggleScroll: return "暂停 / 恢复滚动增强"
        case .controlCenter: return "打开控制中心"
        }
    }

    var detail: String {
        switch self {
        case .capture: return "拖选区域后标注、复制、保存或贴图"
        case .ocr: return "松开鼠标即识别选区文字"
        case .pin: return "松开鼠标即把选区钉在屏幕上"
        case .gif: return "选择区域开始录制，再按一次停止"
        case .toggleScroll: return "临时停用，不改变设置"
        case .controlCenter: return "在菜单栏弹出快捷面板"
        }
    }

    var feature: Feature? {
        switch self {
        case .capture, .ocr, .pin, .gif: return .capture
        case .toggleScroll: return .pointer
        case .controlCenter: return nil
        }
    }

    static let defaults: [HotKeyAction: KeyCombo] = [
        .capture: KeyCombo(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | shiftKey)),
        .ocr: KeyCombo(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(cmdKey | shiftKey)),
        .gif: KeyCombo(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(optionKey | shiftKey)),
    ]
}

struct KeyCombo: Equatable, Hashable {
    var keyCode: UInt32
    /// Carbon 修饰键位（cmdKey / shiftKey / optionKey / controlKey）。
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        let code = UInt32(event.keyCode)
        let isFunctionKey = KeyCombo.functionKeys.keys.contains(code)
        // 没有修饰键的普通字符会和日常输入冲突，只允许 F 键单独使用
        guard carbon != 0 || isFunctionKey else { return nil }
        keyCode = code
        modifiers = carbon
    }

    var displayString: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + KeyCombo.keyName(keyCode)
    }

    private static let functionKeys: [UInt32: String] = [
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15",
    ]

    private static let specialKeys: [UInt32: String] = [
        UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥", UInt32(kVK_Space): "空格", UInt32(kVK_Delete): "⌫",
        UInt32(kVK_Escape): "⎋", UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓", UInt32(kVK_ForwardDelete): "⌦",
        UInt32(kVK_Home): "↖", UInt32(kVK_End): "↘", UInt32(kVK_PageUp): "⇞", UInt32(kVK_PageDown): "⇟",
    ]

    static func keyName(_ code: UInt32) -> String {
        if let name = functionKeys[code] ?? specialKeys[code] { return name }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "#\(code)"
        }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "#\(code)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// Carbon 全局快捷键：不需要辅助功能权限，适合截图类高频入口。
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    var handler: ((HotKeyAction) -> Void)?
    /// 注册失败（被其他应用占用）的动作。
    private(set) var conflicts: Set<HotKeyAction> = []

    private var refs: [HotKeyAction: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x54_42_58_32 // 'TBX2'

    private init() {}

    func apply(_ bindings: [HotKeyAction: KeyCombo], enabled: (HotKeyAction) -> Bool) {
        installHandlerIfNeeded()
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        conflicts.removeAll()
        for action in HotKeyAction.allCases {
            guard let combo = bindings[action], enabled(action) else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: signature, id: UInt32(HotKeyAction.allCases.firstIndex(of: action)! + 1))
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[action] = ref
            } else {
                conflicts.insert(action)
            }
        }
    }

    /// 录制快捷键期间暂停全部注册，避免按下的组合直接触发动作。
    func suspend() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let index = Int(hotKeyID.id) - 1
            guard HotKeyAction.allCases.indices.contains(index) else { return noErr }
            let action = HotKeyAction.allCases[index]
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeyCenter.shared.handler?(action) }
            }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}
