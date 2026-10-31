import AppKit
import FanControlLabKit
import MonitoringLabKit
import SwiftUI

/// 可见期间请求进程排行与 1 秒采样。
private struct DetailVisibility: ViewModifier {
    let model: TelemetryModel
    let kind: TelemetryDetailKind
    func body(content: Content) -> some View {
        content
            .onAppear { model.beginDetail(kind) }
            .onDisappear { model.endDetail(kind) }
    }
}

extension View {
    func telemetryDetail(_ model: TelemetryModel, kind: TelemetryDetailKind) -> some View {
        modifier(DetailVisibility(model: model, kind: kind))
    }
}

struct ChartBox<Header: View>: View {
    var height: CGFloat = 70
    let values: [Double]
    var secondary: [Double] = []
    var maxValue: Double? = nil
    var color: Color = .green
    var secondaryColor: Color = .orange
    @ViewBuilder var header: Header

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Sparkline(values: values, secondary: secondary, maxValue: maxValue, color: color, secondaryColor: secondaryColor)
                .frame(height: height)
        }
        .padding(12)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct ProcessList: View {
    let title: String
    let rows: [ProcessActivity]
    let value: (ProcessActivity) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if rows.isEmpty {
                Text("暂无活动").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.vertical, 4)
            }
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Image(nsImage: ProcessIcon.icon(for: row.path))
                        .resizable().frame(width: 16, height: 16)
                    Text(row.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(value(row)).font(.system(size: 11.5, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

enum ProcessIcon {
    private static var cache: [String: NSImage] = [:]
    private static let generic = NSWorkspace.shared.icon(for: .unixExecutable)

    static func icon(for path: String?) -> NSImage {
        guard let path else { return generic }
        let bundlePath = path.components(separatedBy: ".app/").first.map { $0 + ".app" } ?? path
        if let cached = cache[bundlePath] { return cached }
        let image = path.contains(".app/") ? NSWorkspace.shared.icon(forFile: bundlePath) : generic
        if cache.count > 300 { cache.removeAll() }
        cache[bundlePath] = image
        return image
    }
}

// MARK: - CPU

struct CPUDetail: View {
    @ObservedObject var model: TelemetryModel

    var body: some View {
        let s = model.snapshot
        VStack(spacing: 10) {
            ChartBox(values: model.cpuHistory, maxValue: 100, color: .green) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Format.percent(s.cpuPercent)).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("总占用").foregroundStyle(.secondary).font(.system(size: 12))
                    Spacer()
                    Text("\(s.corePercents.count) 核").foregroundStyle(.secondary).font(.system(size: 12))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("每个核心").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 6) {
                    ForEach(Array(s.corePercents.enumerated()), id: \.offset) { index, value in
                        HStack(spacing: 6) {
                            Text("\(index + 1)").font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary)
                                .frame(width: 14, alignment: .trailing)
                            MeterBar(fraction: value / 100, color: value > 80 ? .orange : .green)
                            Text(Format.percent(value)).font(.system(size: 10, design: .rounded)).monospacedDigit()
                                .frame(width: 30, alignment: .trailing)
                        }
                    }
                }
            }
            .padding(12)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            ProcessList(title: "占用最高的进程", rows: model.ranking.byCPU) { String(format: "%.1f%%", $0.cpuPercent) }
        }
        .telemetryDetail(model, kind: .cpu)
    }
}

// MARK: - 内存

struct MemoryDetail: View {
    @ObservedObject var model: TelemetryModel

    var body: some View {
        let s = model.snapshot
        let total = Double(max(s.memoryTotal, 1))
        VStack(spacing: 10) {
            ChartBox(values: model.memoryHistory, maxValue: 100, color: .blue) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Format.memory(s.memoryUsed)).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("/ \(Format.memory(s.memoryTotal))").foregroundStyle(.secondary).font(.system(size: 12))
                    Spacer()
                    Text(Format.percent(s.memoryFraction * 100)).foregroundStyle(.secondary).font(.system(size: 12))
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                MeterBar(segments: [
                    .init(fraction: Double(s.memoryApp) / total, color: .blue),
                    .init(fraction: Double(s.memoryWired) / total, color: .orange),
                    .init(fraction: Double(s.memoryCompressed) / total, color: .purple),
                ], height: 10)
                HStack {
                    legend("应用", s.memoryApp, .blue)
                    legend("联动", s.memoryWired, .orange)
                    legend("压缩", s.memoryCompressed, .purple)
                }
                HStack {
                    StatValue(title: "可用", value: Format.memory(s.memoryTotal > s.memoryUsed ? s.memoryTotal - s.memoryUsed : 0))
                    Spacer()
                    StatValue(title: "交换", value: "\(Format.memory(s.swapUsed)) / \(Format.memory(s.swapTotal))")
                }
            }
            .padding(12)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            ProcessList(title: "内存占用最高的进程", rows: model.ranking.byMemory) { Format.memory($0.memoryBytes) }
        }
        .telemetryDetail(model, kind: .memory)
    }

    private func legend(_ title: String, _ value: UInt64, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.system(size: 10.5)).foregroundStyle(.secondary)
            Text(Format.memory(value)).font(.system(size: 10.5, design: .rounded)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 网络

struct NetworkDetail: View {
    @ObservedObject var model: TelemetryModel

    var body: some View {
        let s = model.snapshot
        VStack(spacing: 10) {
            ChartBox(height: 90, values: model.downHistory, secondary: model.upHistory, color: .cyan, secondaryColor: .orange) {
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 0) {
                        Label("下载", systemImage: "arrow.down").font(.system(size: 11)).foregroundStyle(.cyan)
                        Text(Format.rate(s.netDownPerSecond)).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Label("上传", systemImage: "arrow.up").font(.system(size: 11)).foregroundStyle(.orange)
                        Text(Format.rate(s.netUpPerSecond)).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                    Spacer()
                }
            }
            HStack {
                StatValue(title: "主接口", value: s.netInterface.isEmpty ? "—" : s.netInterface)
                Spacer()
                StatValue(title: "本机 IP", value: s.localIP.isEmpty ? "—" : s.localIP)
            }
            .padding(12)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .textSelection(.enabled)
            HStack {
                StatValue(title: "累计下载", value: Format.bytes(Double(s.netTotalDownBytes)), color: .cyan)
                Spacer()
                StatValue(title: "累计上传", value: Format.bytes(Double(s.netTotalUpBytes)), color: .orange)
            }
            .padding(12)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("出口公网 IP").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    if model.publicIPLoading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button("刷新") { model.requestPublicIP(force: true) }
                            .buttonStyle(.borderless).font(.system(size: 10))
                    }
                }
                Text(model.publicIPLoading ? "查询中…" : (model.publicIP.isEmpty ? "未获取" : model.publicIP))
                    .font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
                if !model.publicIPLocation.isEmpty {
                    Label(model.publicIPLocation, systemImage: "mappin.and.ellipse")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if !model.publicIPProvider.isEmpty {
                    Label(model.publicIPProvider, systemImage: "network")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .textSelection(.enabled)
            ProcessList(title: "网络活动进程排行", rows: model.ranking.byNetwork) {
                "↓ \(Format.rate($0.networkReceivePerSecond))  ↑ \(Format.rate($0.networkSendPerSecond))"
            }
            Text("只统计物理网卡（Wi-Fi / 以太网），代理隧道的流量不会重复计算。")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
        }
        .telemetryDetail(model, kind: .network)
        .onAppear { model.requestPublicIP() }
    }
}

// MARK: - 磁盘

struct DiskDetail: View {
    @ObservedObject var model: TelemetryModel

    var body: some View {
        let s = model.snapshot
        VStack(spacing: 10) {
            ChartBox(values: model.readHistory, secondary: model.writeHistory, color: .indigo, secondaryColor: .pink) {
                HStack(spacing: 18) {
                    StatValue(title: "读取", value: Format.rate(s.diskReadPerSecond), color: .indigo)
                    StatValue(title: "写入", value: Format.rate(s.diskWritePerSecond), color: .pink)
                    Spacer()
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(s.volumes) { volume in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: volume.mountPath == "/" ? "internaldrive" : "externaldrive").foregroundStyle(.secondary)
                            Text(volume.name).font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text("可用 \(Format.bytes(Double(volume.freeBytes))) / \(Format.bytes(Double(volume.totalBytes)))")
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                        MeterBar(fraction: volume.usedFraction, color: volume.usedFraction > 0.9 ? .red : .indigo)
                    }
                }
            }
            .padding(12)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            ProcessList(title: "磁盘读写最多的进程", rows: model.ranking.byDisk) {
                Format.compactRate($0.diskReadPerSecond + $0.diskWritePerSecond) + "/s"
            }
        }
        .telemetryDetail(model, kind: .disk)
    }
}

// MARK: - 散热

struct ThermalDetail: View {
    @ObservedObject var model: ThermalModel
    var showsSensorsLimit: Int? = 12

    var body: some View {
        VStack(spacing: 10) {
            ForEach(model.fans) { fan in
                FanCard(model: model, fan: fan)
            }
            if model.fans.isEmpty {
                Text(model.running ? "没有读到风扇。" : "散热功能已关闭。").font(.callout).foregroundStyle(.secondary)
            }
            SensorList(model: model, limit: showsSensorsLimit)
        }
    }
}

struct FanCard: View {
    @ObservedObject var model: ThermalModel
    let fan: ThermalFan

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "fan.fill").foregroundStyle(.orange)
                Text(fan.name).font(.system(size: 13, weight: .semibold))
                Text(modeTitle).font(.system(size: 10.5)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.fill.tertiary, in: Capsule())
                Spacer()
                Text("\(Int(fan.currentRPM.rounded())) RPM").font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit().contentTransition(.numericText())
            }
            MeterBar(fraction: (fan.currentRPM - fan.minimumRPM) / max(fan.maximumRPM - fan.minimumRPM, 1), color: .orange)
            HStack {
                Text("最低 \(Int(fan.minimumRPM))").font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
                if fan.mode != .automatic {
                    Text("目标 \(Int(fan.targetRPM))").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    Spacer()
                }
                Text("最高 \(Int(fan.maximumRPM))").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            switch fan.mode {
            case .constant:
                FixedRPMSlider(model: model, fan: fan)
            case .sensor(let sensorID, let low, let high):
                CurveEditor(model: model, fan: fan, appliedSensor: sensorID, appliedLow: low, appliedHigh: high)
            case .automatic:
                Text("由系统固件按温度自动调节。").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var modeTitle: String {
        switch fan.mode {
        case .automatic: return "自动"
        case .sensor: return "温控"
        case .constant(let rpm): return Double(rpm) >= fan.maximumRPM * 0.99 ? "全速" : "固定"
        }
    }
}

/// 温控曲线编辑：拖动只改草稿，按“应用”后才下发给风扇，避免拖动过程中转速来回变化。
private struct CurveEditor: View {
    @ObservedObject var model: ThermalModel
    let fan: ThermalFan
    let appliedSensor: String
    let appliedLow: Double
    let appliedHigh: Double
    @Local private var sensor: String
    @Local private var low: Double
    @Local private var high: Double

    init(model: ThermalModel, fan: ThermalFan, appliedSensor: String, appliedLow: Double, appliedHigh: Double) {
        self.model = model
        self.fan = fan
        self.appliedSensor = appliedSensor
        self.appliedLow = appliedLow
        self.appliedHigh = appliedHigh
        _sensor = Local(wrappedValue: appliedSensor)
        _low = Local(wrappedValue: appliedLow.rounded())
        _high = Local(wrappedValue: appliedHigh.rounded())
    }

    private var dirty: Bool {
        sensor != appliedSensor || abs(low - appliedLow) >= 0.5 || abs(high - appliedHigh) >= 0.5
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("依据传感器", selection: $sensor) {
                ForEach(sensorChoices, id: \.id) { sensor in
                    Text("\(sensor.name)  \(model.temperature(sensor.celsius))").tag(sensor.id)
                }
            }
            .controlSize(.small)
            HStack {
                Text("开始提速").font(.system(size: 11)).frame(width: 56, alignment: .leading)
                Slider(value: Binding(get: { low }, set: { low = $0.rounded(); if high < low + 5 { high = min(low + 5, 105) } }),
                       in: 40...90).controlSize(.small)
                Text("\(Int(low))°C").font(.system(size: 11, design: .rounded)).monospacedDigit().frame(width: 36)
            }
            HStack {
                Text("满速温度").font(.system(size: 11)).frame(width: 56, alignment: .leading)
                Slider(value: Binding(get: { high }, set: { high = max($0.rounded(), low + 5) }), in: 60...105).controlSize(.small)
                Text("\(Int(high))°C").font(.system(size: 11, design: .rounded)).monospacedDigit().frame(width: 36)
            }
            HStack(alignment: .center) {
                Text("低于 \(Int(low))°C 保持最低转速，到 \(Int(high))°C 时达到 \(Int(fan.effectiveMaximumRPM)) RPM，中间线性提速。")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if dirty {
                    Button("还原") { reset() }.controlSize(.small)
                }
                ApplyButton(dirty: dirty) {
                    model.setMode(.sensor(sensorID: sensor, increaseAt: low, maxAt: high), for: fan.index)
                }
            }
        }
        .onChange(of: fan.mode) { _, _ in reset() }
    }

    private func reset() {
        sensor = appliedSensor
        low = appliedLow.rounded()
        high = appliedHigh.rounded()
    }

    private var sensorChoices: [ThermalSensor] {
        let sensors = model.reading?.sensors ?? []
        let groups = sensors.filter(\.isGroupAverage)
        let others = sensors.filter { !$0.isGroupAverage }.sorted { $0.name < $1.name }
        var list = groups + others
        if !list.contains(where: { $0.id == sensor }) {
            list.insert(ThermalSensor(id: sensor, name: sensor, celsius: 0, kind: .other, isGroupAverage: false), at: 0)
        }
        return list
    }
}

/// “应用 / 已应用”按钮：有未应用的修改时可点。
struct ApplyButton: View {
    let dirty: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(dirty ? "应用" : "已应用").frame(minWidth: 44)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(!dirty)
    }
}

struct SensorList: View {
    @ObservedObject var model: ThermalModel
    var limit: Int?
    @Local private var expanded = false

    var body: some View {
        let sensors = (model.reading?.sensors ?? []).sorted { $0.celsius > $1.celsius }
        let shown = expanded || limit == nil ? sensors : Array(sensors.prefix(limit!))
        VStack(alignment: .leading, spacing: 5) {
            Text("温度传感器（\(sensors.count)）").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(shown) { sensor in
                HStack {
                    Image(systemName: sensor.kind == .gpu ? "cpu.fill" : sensor.kind == .cpu ? "cpu" : "thermometer.medium")
                        .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
                    Text(sensor.name).font(.system(size: 11.5)).lineLimit(1)
                    if sensor.isGroupAverage {
                        Text("平均").font(.system(size: 9)).padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.fill.tertiary, in: Capsule())
                    }
                    Spacer()
                    Text(model.temperature(sensor.celsius)).font(.system(size: 11.5, design: .rounded)).monospacedDigit()
                        .foregroundStyle(sensor.celsius > 85 ? .red : sensor.celsius > 70 ? .orange : .primary)
                }
            }
            if let limit, sensors.count > limit {
                Button(expanded ? "收起" : "显示全部 \(sensors.count) 个") { expanded.toggle() }
                    .buttonStyle(.link).font(.system(size: 11))
            }
        }
        .padding(12)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
