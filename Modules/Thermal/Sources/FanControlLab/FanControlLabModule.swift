import AppKit
import CoreFoundation

/// Stable, read-only façade used by the standalone app and ThermalAgent.
///
/// The facade intentionally has no helper installation, fan-mode mutation,
/// arbitrary SMC-key access, or shell primitive. It returns immutable JSON-safe
/// snapshots and routes settings presentation to the unified Shell.
@MainActor
public final class FanControlLabModule: NSObject, NSApplicationDelegate {
    public static let settingsSchemaVersion = 1
    public static let capabilities = [
        "readOnlyFanMonitoring", "temperatureSensors", "sensorWindow",
        "settings", "summary",
    ]

    private let appDelegate: AppDelegate
    private var settingsRevision = 0

    public var onShowPreferences: (() -> Void)? {
        didSet {
            appDelegate.onShowPreferences = onShowPreferences
        }
    }

    public init(embedded: Bool = true) {
        appDelegate = AppDelegate(embedded: embedded)
        super.init()
    }

    public func start() {
        appDelegate.start()
    }

    public func stop() {
        appDelegate.stop()
    }

    public func showPreferences() {
        appDelegate.showPreferences()
    }

    /// Live read-only state. Fan and sensor values are no older than the
    /// configured poll interval, except while the module is stopped or warming.
    public func summary() -> [String: Any] {
        let settings = AppSettings.shared
        let database = appDelegate.database
        let update = appDelegate.latestUpdate
        let fans = update?.fans ?? []
        let sensors = update?.sensors ?? []
        let sampled = update != nil

        var result: [String: Any] = [
            "schemaVersion": Self.settingsSchemaVersion,
            "embedded": appDelegate.isEmbedded,
            "mode": "read_only",
            "readOnly": true,
            "controlArmed": false,
            "writesSupported": false,
            "capabilities": Self.capabilities,
            "sensorWindowVisible": appDelegate.isSensorWindowVisible,
            "settingsSuite": settings.suiteName,
            "settingsRevision": settingsRevision,
            "unit": settings.usesFahrenheit ? "F" : "C",
            "sampled": sampled,
            "warmup": !sampled,
            "sampleAgeSeconds": update.map { max(0, Date().timeIntervalSince($0.timestamp)) } ?? -1,
            "fanCount": fans.count,
            "sensorCount": sensors.count,
            "fans": fans.map { fan in
                [
                    "index": fan.index,
                    "name": fan.name,
                    "minimumRPM": rounded(fan.minimumRPM),
                    "currentRPM": rounded(fan.currentRPM),
                    "maximumRPM": rounded(fan.maximumRPM),
                    "reportedTargetRPM": rounded(fan.targetRPM),
                    "reportedModeByte": Int(fan.modeByte),
                    "controlMode": "system",
                ] as [String: Any]
            },
            "sensors": sensors.sorted {
                $0.temperatureCelsius > $1.temperatureCelsius
            }.prefix(64).map { sensor in
                [
                    "id": sensor.id,
                    "name": sensor.name,
                    "kind": sensorKind(sensor.kind),
                    "temperature": rounded(sensor.temperatureCelsius),
                    "displayTemperature": settings.formattedTemperature(sensor.temperatureCelsius),
                ] as [String: Any]
            },
            "limitations": database?.limitations ?? [
                "SMC has not been sampled yet.",
            ],
        ]

        if let database {
            result["rawModel"] = database.rawModel
            result["model"] = database.canonicalModel
            result["catalogSource"] = database.sensorCatalogSource.rawValue
            result["fanNameSource"] = database.fanNameSource.rawValue
        } else {
            result["model"] = "unknown"
            result["catalogSource"] = SensorCatalogSource.builtInProbe.rawValue
            result["fanNameSource"] = SensorCatalogSource.builtInProbe.rawValue
        }

        if let first = fans.first {
            result["currentRPM"] = rounded(first.currentRPM)
            result["minimumRPM"] = rounded(first.minimumRPM)
            result["maximumRPM"] = rounded(first.maximumRPM)
        }
        if let cpu = MonitorUpdate.groupAverage(of: sensors, kind: .cpu) {
            result["cpuTemperature"] = rounded(cpu)
            result["cpuTemperatureDisplay"] = settings.formattedTemperature(cpu)
        }
        result["text"] = summaryText(update: update, settings: settings)

        if let error = appDelegate.startupError {
            result["degraded"] = true
            result["error"] = error
        } else {
            result["degraded"] = !sampled
        }
        return result
    }

    /// Pure, JSON-compatible last-known-good module settings. Product login
    /// items and the fan safety policy remain owned by the unified Shell.
    public func settingsSnapshot() -> [String: Any] {
        let settings = AppSettings.shared
        return [
            "schemaVersion": Self.settingsSchemaVersion,
            "revision": settingsRevision,
            "suite": settings.suiteName,
            "refreshInterval": settings.refreshInterval,
            "fahrenheit": settings.usesFahrenheit,
            "menuBarShowsTemperature": settings.menuBarShowsTemperature,
            "maximumRPMFraction": settings.maximumRPMFraction,
            "defaultIncreaseAt": settings.defaultIncreaseAt,
            "defaultMaxAt": settings.defaultMaxAt,
            "launchAtLogin": settings.launchAtLogin,
            "controlArmed": false,
        ]
    }

    /// Atomically validates and applies the safe monitor-preferences subset.
    /// No fan mode or fan-write setting is accepted.
    public func updateSettings(_ changes: [String: Any]) -> [String: Any] {
        let settings = AppSettings.shared
        var refreshInterval = settings.refreshInterval
        var fahrenheit = settings.usesFahrenheit
        var menuBarShowsTemperature = settings.menuBarShowsTemperature
        var maximumRPMFraction = settings.maximumRPMFraction
        var defaultIncreaseAt = settings.defaultIncreaseAt
        var defaultMaxAt = settings.defaultMaxAt

        for (key, rawValue) in changes {
            switch key {
            case "refreshInterval":
                guard let value = number(rawValue), (1.0...5.0).contains(value) else {
                    return failure("refreshInterval must be a number in 1...5")
                }
                refreshInterval = value
            case "fahrenheit":
                guard let value = bool(rawValue) else {
                    return failure("fahrenheit must be a boolean")
                }
                fahrenheit = value
            case "menuBarShowsTemperature":
                guard let value = bool(rawValue) else {
                    return failure("menuBarShowsTemperature must be a boolean")
                }
                menuBarShowsTemperature = value
            case "maximumRPMFraction":
                guard let value = number(rawValue), (0.5...1.0).contains(value) else {
                    return failure("maximumRPMFraction must be a number in 0.5...1.0")
                }
                maximumRPMFraction = value
            case "defaultIncreaseAt":
                guard let value = number(rawValue), (40.0...90.0).contains(value) else {
                    return failure("defaultIncreaseAt must be a number in 40...90")
                }
                defaultIncreaseAt = value
            case "defaultMaxAt":
                guard let value = number(rawValue), (60.0...105.0).contains(value) else {
                    return failure("defaultMaxAt must be a number in 60...105")
                }
                defaultMaxAt = value
            case "launchAtLogin":
                return failure("launchAtLogin is owned by the unified Shell")
            default:
                return failure("unknown or write-controlled settings key: \(key)")
            }
        }
        guard defaultMaxAt >= defaultIncreaseAt + 5 else {
            return failure("defaultMaxAt must be at least 5 degrees above defaultIncreaseAt")
        }

        settings.refreshInterval = refreshInterval
        settings.usesFahrenheit = fahrenheit
        settings.menuBarShowsTemperature = menuBarShowsTemperature
        settings.maximumRPMFraction = maximumRPMFraction
        settings.defaultIncreaseAt = defaultIncreaseAt
        settings.defaultMaxAt = defaultMaxAt
        settingsRevision += 1
        NotificationCenter.default.post(name: .fanControlSettingsChanged, object: nil)
        return ["ok": true, "settings": settingsSnapshot()]
    }

    /// Narrow allow-listed command surface for the stdio Agent.
    public func execute(
        command: String,
        payload: [String: Any]
    ) -> [String: Any] {
        switch command {
        case "summary", "status", "health":
            return ["ok": true, "result": summary()]
        case "settingsSnapshot", "getSettings":
            return ["ok": true, "result": settingsSnapshot()]
        case "updateSettings":
            guard let changes = payload["changes"] as? [String: Any] else {
                return failure("payload.changes must be an object")
            }
            return updateSettings(changes)
        case "showPreferences":
            showPreferences()
            return [
                "ok": true,
                "handled": appDelegate.isEmbedded ? onShowPreferences != nil : true,
            ]
        case "refresh":
            appDelegate.refreshNow()
            return ["ok": true]
        case "showMainWindow", "showAllWindows":
            appDelegate.bringWindowsForward()
            return ["ok": true]
        default:
            if isWriteCommand(command) {
                return [
                    "ok": false,
                    "error": "control_unarmed",
                    "message": "Fan writes and helper installation are disabled in this build.",
                ]
            }
            return failure("unknown command: \(command)")
        }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        start()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        stop()
    }

    private func summaryText(
        update: MonitorUpdate?,
        settings: AppSettings
    ) -> String {
        guard let update else { return "等待首次采样" }
        var parts: [String] = []
        if let fan = update.fans.first {
            parts.append(String(format: "%.0f RPM", fan.currentRPM))
        }
        if settings.menuBarShowsTemperature,
           let cpu = MonitorUpdate.groupAverage(of: update.sensors, kind: .cpu) {
            parts.append(settings.formattedTemperature(cpu))
        }
        return parts.isEmpty ? "未检测到风扇" : parts.joined(separator: " · ")
    }

    private func isWriteCommand(_ command: String) -> Bool {
        let normalized = command.lowercased()
        let exact: Set<String> = [
            "fullblast", "sensorcurve", "automatic", "setfanmode", "writefan",
            "installhelper", "uninstallhelper", "arm", "disarm",
        ]
        return exact.contains(normalized)
            || normalized.hasPrefix("fan.")
            || normalized.hasPrefix("smc.")
            || normalized.hasPrefix("helper.")
            || normalized.contains("write")
    }

    private func sensorKind(_ kind: SensorKind) -> String {
        switch kind {
        case .cpu: return "cpu"
        case .gpu: return "gpu"
        case .other: return "other"
        }
    }

    private func rounded(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private func bool(_ raw: Any) -> Bool? {
        if let value = raw as? Bool { return value }
        if let number = raw as? NSNumber,
           CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue
        }
        return nil
    }

    private func number(_ raw: Any) -> Double? {
        let value: Double?
        if let number = raw as? Double {
            value = number
        } else if let number = raw as? Int {
            value = Double(number)
        } else if let number = raw as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() {
            value = number.doubleValue
        } else {
            value = nil
        }
        guard let value, value.isFinite else { return nil }
        return value
    }

    private func failure(_ message: String) -> [String: Any] {
        ["ok": false, "error": message]
    }
}

/// One-shot probe used by the standalone `--probe` entry point and smoke test.
public enum FanControlLabProbe {
    public static func report() -> [String: Any] {
        let client = SMCClient()
        do {
            try client.open()
        } catch {
            return ["ok": false, "error": "SMC open failed: \(error)"]
        }
        defer { client.close() }

        guard let fanCount = client.readUInt8("FNum") else {
            return ["ok": false, "error": "FNum unreadable"]
        }
        var fans: [[String: Any]] = []
        for index in 0..<fanCount {
            let prefix = "F\(index)"
            fans.append([
                "index": Int(index),
                "minimumRPM": client.readRPM("\(prefix)Mn") ?? 0,
                "currentRPM": client.readRPM("\(prefix)Ac") ?? 0,
                "maximumRPM": client.readRPM("\(prefix)Mx") ?? 0,
            ])
        }

        let database = SensorDatabase.load()
        var sensors: [[String: Any]] = []
        for definition in database.sensors {
            guard let temperature = client.readTemperatureCelsius(definition.key),
                  temperature > 0 else { continue }
            sensors.append([
                "id": definition.key,
                "name": definition.name,
                "temperature": temperature,
            ])
        }
        sensors.sort {
            ($0["temperature"] as? Double ?? 0) > ($1["temperature"] as? Double ?? 0)
        }
        return [
            "ok": true,
            "fanCount": Int(fanCount),
            "fans": fans,
            "model": database.canonicalModel,
            "rawModel": database.rawModel,
            "catalogSource": database.sensorCatalogSource.rawValue,
            "fanNameSource": database.fanNameSource.rawValue,
            "knownSensorCount": database.sensors.count,
            "sensors": sensors,
            "limitations": database.limitations,
        ]
    }
}
