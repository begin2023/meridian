import Combine
import Foundation
import MonitoringLabKit

enum TelemetryDetailKind: Hashable {
    case cpu
    case memory
    case network
    case disk
}

/// 系统监控：采样在后台串行队列执行；进程排行只在有界面在看时扫描。
@MainActor
final class TelemetryModel: ObservableObject {
    static let historyLength = 90

    @Published private(set) var snapshot = SystemSnapshot()
    @Published private(set) var ranking = ProcessRanking()
    @Published private(set) var publicIP = ""
    @Published private(set) var publicIPLocation = ""
    @Published private(set) var publicIPProvider = ""
    @Published private(set) var publicIPLoading = false
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memoryHistory: [Double] = []
    @Published private(set) var downHistory: [Double] = []
    @Published private(set) var upHistory: [Double] = []
    @Published private(set) var readHistory: [Double] = []
    @Published private(set) var writeHistory: [Double] = []
    @Published private(set) var running = false

    private let sampler = SystemSampler()
    private let queue = DispatchQueue(label: "meridian.telemetry", qos: .utility)
    private let rankingSampler = SystemSampler()
    private let rankingQueue = DispatchQueue(label: "meridian.telemetry.ranking", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var interval: Double = 2
    private var detailCounts: [TelemetryDetailKind: Int] = [:]
    private var rankingTask: Task<Void, Never>?
    private var rankingInFlight = false
    private var rankingPasses = 0
    private var publicIPTask: Task<Void, Never>?
    private var lastPublicIPLookup: Date?

    func start(interval: Double) {
        self.interval = interval
        running = true
        reschedule()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        rankingTask?.cancel()
        rankingTask = nil
        publicIPTask?.cancel()
        publicIPTask = nil
        running = false
    }

    func setInterval(_ value: Double) {
        interval = value
        if running { reschedule() }
    }

    /// 详情只声明自己需要哪类数据。网络排行不会因为打开 CPU/内存/磁盘页而运行。
    func beginDetail(_ kind: TelemetryDetailKind) {
        let hadDetails = hasDetails
        let networkWasVisible = hasDetail(.network)
        detailCounts[kind, default: 0] += 1

        if !hadDetails {
            rankingPasses = 0
            rankingQueue.async { [rankingSampler] in
                rankingSampler.resetProcessBaseline()
            }
        }
        if kind == .network, !networkWasVisible {
            rankingPasses = 0
            rankingQueue.async { [rankingSampler] in
                rankingSampler.resetNetworkBaseline()
            }
            requestPublicIP()
        }
        scheduleRanking(after: 0.05)
        if running { reschedule() }
    }

    func requestPublicIP(force: Bool = false) {
        guard publicIPTask == nil else { return }
        if !force, let lastPublicIPLookup {
            let cooldown: TimeInterval = publicIP.isEmpty ? 60 : 3600
            guard Date().timeIntervalSince(lastPublicIPLookup) > cooldown else { return }
        }
        publicIPLoading = true
        publicIPTask = Task { [weak self] in
            let info = await Self.fetchPublicIPInfo()
            guard let self else { return }
            self.publicIPLoading = false
            self.publicIPTask = nil
            self.lastPublicIPLookup = Date()
            guard !Task.isCancelled, let info else { return }
            self.publicIP = info.address
            self.publicIPLocation = info.location
            self.publicIPProvider = info.provider
        }
    }

    func endDetail(_ kind: TelemetryDetailKind) {
        let count = max(0, detailCounts[kind, default: 0] - 1)
        if count == 0 {
            detailCounts.removeValue(forKey: kind)
        } else {
            detailCounts[kind] = count
        }
        if !hasDetails {
            rankingTask?.cancel()
            rankingTask = nil
            if running { reschedule() }
        }
    }

    private func reschedule() {
        timer?.cancel()
        let effective = hasDetails ? min(interval, 1) : interval
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: effective, leeway: .milliseconds(150))
        source.setEventHandler { [weak self, sampler] in
            let snapshot = sampler.sample()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.publish(snapshot) }
            }
        }
        timer = source
        source.resume()
    }

    private var hasDetails: Bool {
        !detailCounts.isEmpty
    }

    private func hasDetail(_ kind: TelemetryDetailKind) -> Bool {
        (detailCounts[kind] ?? 0) > 0
    }

    private func scheduleRanking(after delay: TimeInterval) {
        rankingTask?.cancel()
        guard hasDetails else { return }
        rankingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.hasDetails else { return }
            self.startRanking()
        }
    }

    private func startRanking() {
        guard !rankingInFlight, hasDetails else { return }
        rankingInFlight = true
        let includeNetwork = hasDetail(.network)
        rankingQueue.async { [weak self, rankingSampler] in
            let value = rankingSampler.rankProcesses(includeNetwork: includeNetwork)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.rankingInFlight = false
                    self.ranking = value
                    self.rankingPasses += 1
                    guard self.hasDetails else { return }
                    // The first pass establishes process/network counter
                    // baselines. Refresh once after one second, then stay at 2s.
                    self.scheduleRanking(after: self.rankingPasses < 2 ? 1 : 2)
                }
            }
        }
    }

    private func publish(_ value: SystemSnapshot) {
        snapshot = value
        push(&cpuHistory, value.cpuPercent)
        push(&memoryHistory, value.memoryFraction * 100)
        push(&downHistory, value.netDownPerSecond)
        push(&upHistory, value.netUpPerSecond)
        push(&readHistory, value.diskReadPerSecond)
        push(&writeHistory, value.diskWritePerSecond)
    }

    private func push(_ history: inout [Double], _ value: Double) {
        history.append(value)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
    }

    private struct PublicIPInfo {
        let address: String
        let location: String
        let provider: String
    }

    private static func fetchPublicIPInfo() async -> PublicIPInfo? {
        if let info = await fetchIPInfo() {
            return info
        }
        return await fetchFreeIPAPI()
    }

    private static func fetchIPInfo() async -> PublicIPInfo? {
        guard let url = URL(string: "https://ipinfo.io/json"),
              let data = await fetchJSON(url) else { return nil }
        guard let address = clean(data["ip"] as? String),
              let location = makeLocation(
                city: data["city"] as? String,
                region: data["region"] as? String,
                country: data["country"] as? String
              ) else { return nil }
        return PublicIPInfo(
            address: address,
            location: location,
            provider: makeProvider(data["org"] as? String)
        )
    }

    private static func fetchFreeIPAPI() async -> PublicIPInfo? {
        guard let url = URL(string: "https://freeipapi.com/api/json"),
              let data = await fetchJSON(url) else { return nil }
        guard let address = clean(data["ipAddress"] as? String),
              let location = makeLocation(
                city: data["cityName"] as? String,
                region: data["regionName"] as? String,
                country: data["countryName"] as? String
              ) else { return nil }
        return PublicIPInfo(address: address, location: location, provider: "")
    }

    private static func fetchJSON(_ url: URL) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (body, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              !Task.isCancelled else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    private static func makeLocation(city: String?, region: String?, country: String?) -> String? {
        let raw = [city, region].compactMap(clean)
        var parts: [String] = []
        for value in raw where !parts.contains(value) {
            parts.append(value)
        }
        if let country = clean(country) {
            let localized = Locale.current.localizedString(forRegionCode: country) ?? country
            let label = localized == country ? country : "\(localized) (\(country))"
            if !parts.contains(label), !parts.contains(country) {
                parts.append(label)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func makeProvider(_ value: String?) -> String {
        guard let value = clean(value) else { return "" }
        let words = value.split(separator: " ")
        if let first = words.first, first.uppercased().hasPrefix("AS") {
            return words.dropFirst().joined(separator: " ")
        }
        return value
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text == "-" ? nil : text
    }
}
