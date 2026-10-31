import Foundation

/// Built-in read-only temperature candidates; no external naming tables are loaded.
struct SensorDefinition: Equatable {
    var key: String
    var name: String
    var groupName: String?
    var kind: SensorKind
}

enum SensorCatalogSource: String {
    case builtInProbe = "built_in_probe"
}

final class SensorDatabase {
    let rawModel: String
    let canonicalModel: String
    private(set) var sensors: [SensorDefinition] = []
    private(set) var fanNames: [Int: String] = [:]
    private(set) var fanNameSource: SensorCatalogSource = .builtInProbe
    private(set) var sensorCatalogSource: SensorCatalogSource = .builtInProbe
    private(set) var limitations: [String] = []

    private init(rawModel: String, canonicalModel: String) {
        self.rawModel = rawModel
        self.canonicalModel = canonicalModel
    }

    /// 使用内置只读候选目录；风扇 RPM 独立读取。
    static func load() -> SensorDatabase {
        let rawModel = SystemInfo.modelIdentifier() ?? "unknown"
        let canonicalModel = rawModel
        let database = SensorDatabase(rawModel: rawModel, canonicalModel: canonicalModel)
        database.installFallbackCatalog()
        database.limitations.append("Fan names are generic; temperature labels are unverified hardware candidates.")
        return database
    }

    /// 组平均传感器使用稳定标识，供温度曲线选择。
    var groupedSensors: [(group: String, slug: String, kind: SensorKind, members: [SensorDefinition])] {
        var result: [(group: String, slug: String, kind: SensorKind, members: [SensorDefinition])] = []
        var seen = Set<String>()
        for definition in sensors {
            guard let group = definition.groupName, !seen.contains(group) else { continue }
            seen.insert(group)
            let members = sensors.filter { $0.groupName == group }
            let kind: SensorKind = members.allSatisfy({ $0.kind == .cpu }) ? .cpu
                : members.allSatisfy({ $0.kind == .gpu }) ? .gpu : .other
            result.append((group, Self.slug(group), kind, members))
        }
        return result
    }

    func fanName(for index: Int) -> String {
        fanNames[index] ?? "风扇 \(index)"
    }

    private func installFallbackCatalog() {
        sensorCatalogSource = .builtInProbe
        sensors = Self.fallbackSensors
        limitations.append("Temperature keys are built-in read-only candidates; names, ranges and model support are not verified.")
    }

    /// 无外部表时的保守探测集。名称刻意保持通用，避免把未核实来源的
    /// 名称或机型映射伪装成完整数据库。
    private static let fallbackSensors: [SensorDefinition] = {
        let cpuKeys = ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L",
                       "Te05", "Te09", "Te0H", "Te0S", "Te0U", "Te0V"]
        let gpuKeys = ["Tg04", "Tg12", "Tg05", "Tg0D", "Tg0L", "Tg0T"]
        let otherKeys = ["Tm1p", "TA0P", "Ta0P", "TW0P"]
        return cpuKeys.map {
            SensorDefinition(key: $0, name: "CPU 候选 \($0)", groupName: "CPU Core Average", kind: .cpu)
        } + gpuKeys.map {
            SensorDefinition(key: $0, name: "GPU 候选 \($0)", groupName: "GPU Core Average", kind: .gpu)
        } + otherKeys.map {
            SensorDefinition(key: $0, name: "温度候选 \($0)", groupName: nil, kind: .other)
        }
    }()

    static func slug(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }
}

enum SystemInfo {
    static var isAppleSilicon: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    static func modelIdentifier() -> String? {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &value, &size, nil, 0)
        return String(cString: value)
    }
}
