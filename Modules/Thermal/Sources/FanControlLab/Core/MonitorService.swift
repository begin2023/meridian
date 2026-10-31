import Foundation

/// 周期轮询 SMC：风扇转速与温度传感器，产出 MonitorUpdate 给 UI。
/// 已知尺寸与类型的读取在用户态完成；写入由控制循环另行处理。
final class MonitorService {
    private let client: SMCClient
    private let database: SensorDatabase?
    private let queue = DispatchQueue(label: "app.meridian.control.fancontrollab.monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private(set) var latest: MonitorUpdate?

    /// 在主线程回调。
    var onUpdate: ((MonitorUpdate) -> Void)?

    init(client: SMCClient, database: SensorDatabase?) {
        self.client = client
        self.database = database
    }

    func start() {
        guard timer == nil else { return }
        scheduleTimer()
        pollOnce() // 立即出第一帧
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func refreshNow() {
        queue.async { [weak self] in
            self?.pollOnce()
        }
    }

    private func scheduleTimer() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + AppSettings.shared.refreshInterval, repeating: AppSettings.shared.refreshInterval)
        source.setEventHandler { [weak self] in
            self?.pollOnce()
        }
        timer = source
        source.resume()
    }

    private func pollOnce() {
        guard client.isOpen else { return }
        let fans = readFans(client: client)
        let sensors = readSensors(client: client)
        let update = MonitorUpdate(fans: fans, sensors: sensors, timestamp: Date())
        latest = update
        if let first = fans.first {
            let settings = AppSettings.shared
            settings.knownMinimumRPM = first.minimumRPM
            settings.knownMaximumRPM = first.maximumRPM
        }
        if let onUpdate {
            DispatchQueue.main.async {
                onUpdate(update)
            }
        }
    }

    private func readFans(client: SMCClient) -> [FanSnapshot] {
        guard let fanCount = client.readUInt8("FNum"), fanCount > 0, fanCount <= 10 else { return [] }
        var snapshots: [FanSnapshot] = []
        for index in 0..<fanCount {
            let prefix = "F\(index)"
            guard let current = client.readRPM("\(prefix)Ac"),
                  let minimum = client.readRPM("\(prefix)Mn"),
                  let maximum = client.readRPM("\(prefix)Mx"),
                  maximum > 0 else { continue }
            let target = client.readRPM("\(prefix)Tg") ?? current
            snapshots.append(
                FanSnapshot(
                    index: Int(index),
                    name: database?.fanName(for: Int(index)) ?? "风扇 \(index)",
                    minimumRPM: minimum,
                    currentRPM: current,
                    maximumRPM: maximum,
                    targetRPM: target,
                    modeByte: client.readUInt8("\(prefix)Md") ?? 0
                )
            )
        }
        return snapshots
    }

    private func readSensors(client: SMCClient) -> [SensorSnapshot] {
        guard let database else { return [] }
        var snapshots: [SensorSnapshot] = []
        for definition in database.sensors {
            guard let temperature = client.readTemperatureCelsius(definition.key), temperature > 0 else { continue }
            snapshots.append(
                SensorSnapshot(
                    id: definition.key,
                    name: definition.name,
                    temperatureCelsius: temperature,
                    kind: definition.kind
                )
            )
        }
        // 根据同类传感器构建组平均值。
        for group in database.groupedSensors {
            let members = snapshots.filter { snapshot in
                group.members.contains { $0.key == snapshot.id }
            }
            guard !members.isEmpty else { continue }
            let average = members.map(\.temperatureCelsius).reduce(0, +) / Double(members.count)
            snapshots.append(
                SensorSnapshot(id: group.slug, name: group.group, temperatureCelsius: average, kind: group.kind)
            )
        }
        return snapshots
    }
}
