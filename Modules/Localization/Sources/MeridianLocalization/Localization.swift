import Foundation

/// 界面语言。中文与英文文案以成对字面量写在调用处（`L("中文", "English")`），
/// 不依赖 .strings 资源包，构建脚本不需要额外复制资源。
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, chinese, english

    public var id: String { rawValue }

    /// 选项名使用各自语言书写，切错语言后仍能认出来。
    public var title: String {
        switch self {
        case .system: return L("跟随系统", "System")
        case .chinese: return "简体中文"
        case .english: return "English"
        }
    }

    /// 偏好保存在应用自己的域（app.meridian.control），各模块在同一进程内共享。
    public static let defaultsKey = "v2.language"

    /// 当前选择；写入后立即生效，已经构建好的 AppKit 界面需要重新打开才会更新。
    public static var current: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            Localization.refresh()
        }
    }
}

public enum Localization {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedIsChinese: Bool?

    /// 最终是否显示中文：手动选择优先，否则看系统首选语言。
    public static var isChinese: Bool {
        lock.lock()
        defer { lock.unlock() }
        if let cachedIsChinese { return cachedIsChinese }
        let resolved: Bool
        switch AppLanguage.current {
        case .chinese: resolved = true
        case .english: resolved = false
        case .system: resolved = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        }
        cachedIsChinese = resolved
        return resolved
    }

    public static func refresh() {
        lock.lock()
        cachedIsChinese = nil
        lock.unlock()
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    public static let didChangeNotification = Notification.Name("app.meridian.languageDidChange")
}

/// 返回当前界面语言对应的文案。
@inline(__always)
public func L(_ chinese: String, _ english: String) -> String {
    Localization.isChinese ? chinese : english
}
