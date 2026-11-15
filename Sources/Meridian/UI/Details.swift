import AppKit
import FanControlLabKit
import MeridianLocalization
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
                Text(L("暂无活动", "No activity")).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.vertical, 4)
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
                    Text(L("总占用", "Total Usage")).foregroundStyle(.secondary).font(.system(size: 12))
                    Spacer()
                    Text(L("\(s.corePercents.count) 核", "\(s.corePercents.count) cores")).foregroundStyle(.secondary).font(.system(size: 12))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L("每个核心", "Per Core")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
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
            ProcessList(title: L("占用最高的进程", "Top Processes"), rows: model.ranking.byCPU) { String(format: "%.1f%%", $0.cpuPercent) }
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
                    legend(L("应用", "App"), s.memoryApp, .blue)
                    legend(L("联动", "Wired"), s.memoryWired, .orange)
                    legend(L("压缩", "Compressed"), s.memoryCompressed, .purple)
                }
                HStack {
                    StatValue(title: L("可用", "Available"), value: Format.memory(s.memoryTotal > s.memoryUsed ? s.memoryTotal - s.memoryUsed : 0))
                    Spacer()
                    StatValue(title: L("交换", "Swap"), value: "\(Format.memory(s.swapUsed)) / \(Format.memory(s.swapTotal))")
                }
            }
            .padding(12)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            ProcessList(title: L("内存占用最高的进程", "Top Processes by Memory"), rows: model.ranking.byMemory) { Format.memory($0.memoryBytes) }
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
                        Label(L("下载", "Download"), systemImage: "arrow.down").font(.system(size: 11)).foregroundStyle(.cyan)
                        Text(Format.rate(s.netDownPerSecond)).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Label(L("上传", "Upload"), systemImage: "arrow.up").font(.system(size: 11)).foregroundStyle(.orange)
                        Text(Format.rate(s.netUpPerSecond)).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                    Spacer()
                }
            }
            HStack {
                StatValue(title: L("主接口", "Interface"), value: s.netInterface.isEmpty ? "—" : s.netInterface)
                Spacer()
                StatValue(title: L("本机 IP", "Local IP"), value: s.localIP.isEmpty ? "—" : s.localIP)
            }
            .padding(12)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .textSelection(.enabled)
            HStack {
                StatValue(title: L("累计下载", "Total Downloaded"), value: Format.bytes(Double(s.netTotalDownBytes)), color: .cyan)
                Spacer()
                StatValue(title: L("累计上传", "Total Uploaded"), value: Format.bytes(Double(s.netTotalUpBytes)), color: .orange)
            }
            .padding(12)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(L("出口公网 IP", "Public IP")).font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    if !model.publicIPLookupEnabled {
                        EmptyView()
                    } else if model.publicIPLoading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button(L("刷新", "Refresh")) { model.requestPublicIP(force: true) }
                            .buttonStyle(.borderless).font(.system(size: 10))
                    }
                }
                if model.publicIPLookupEnabled {
                    Text(model.publicIPLoading ? L("查询中…", "Looking up…") : (model.publicIP.isEmpty ? L("未获取", "Not fetched") : model.publicIP))
                        .font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
                    if !model.publicIPLocation.isEmpty {
                        Label(model.publicIPLocation, systemImage: "mappin.and.ellipse")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if !model.publicIPProvider.isEmpty {
                        Label(model.publicIPProvider, systemImage: "network")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                } else {
                    // 查询会把出口 IP 交给第三方，先问再连。
                    Text(L("默认不联网查询：会把本机出口 IP 交给 ipinfo.io 与 freeipapi.com。", "Not looked up by default: doing so sends your public IP to ipinfo.io and freeipapi.com."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L("查询公网 IP…", "Look Up Public IP…")) { model.setPublicIPLookupEnabled(true) }
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .textSelection(.enabled)
            ProcessList(title: L("网络活动进程排行", "Top Processes by Network"), rows: model.ranking.byNetwork) {
                "↓ \(Format.rate($0.networkReceivePerSecond))  ↑ \(Format.rate($0.networkSendPerSecond))"
            }
            Text(L("只统计物理网卡（Wi-Fi / 以太网），代理隧道的流量不会重复计算。", "Counts physical interfaces only (Wi-Fi / Ethernet), so proxy tunnel traffic isn't counted twice."))
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
                    StatValue(title: L("读取", "Read"), value: Format.rate(s.diskReadPerSecond), color: .indigo)
                    StatValue(title: L("写入", "Write"), value: Format.rate(s.diskWritePerSecond), color: .pink)
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
                            Text(L("可用 \(Format.bytes(Double(volume.freeBytes))) / \(Format.bytes(Double(volume.totalBytes)))", "\(Format.bytes(Double(volume.freeBytes))) free of \(Format.bytes(Double(volume.totalBytes)))"))
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                        MeterBar(fraction: volume.usedFraction, color: volume.usedFraction > 0.9 ? .red : .indigo)
                    }
                }
            }
            .padding(12)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            ProcessList(title: L("磁盘读写最多的进程", "Top Processes by Disk I/O"), rows: model.ranking.byDisk) {
                Format.compactRate($0.diskReadPerSecond + $0.diskWritePerSecond) + "/s"
            }
        }
        .telemetryDetail(model, kind: .disk)
    }
}

// MARK: - GPU

struct GPUDetail: View {
    @ObservedObject var model: TelemetryModel

    var body: some View {
        let g = model.snapshot.gpu
        VStack(spacing: 10) {
            ChartBox(values: model.gpuHistory, maxValue: 100, color: .purple) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Format.percent(g.utilization)).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(L("利用率", "Utilization")).foregroundStyle(.secondary).font(.system(size: 12))
                    Spacer()
                    if let mhz = g.averageMegahertz, (g.idleFraction ?? 1) < 0.999 {
                        Text(Format.megahertz(mhz)).foregroundStyle(.secondary).font(.system(size: 12)).monospacedDigit()
                    }
                }
            }
            if g.powerWatts != nil || !model.gpuPowerHistory.isEmpty {
                ChartBox(height: 44, values: model.gpuPowerHistory, color: .orange) {
                    HStack(spacing: 18) {
                        StatValue(title: L("功耗", "Power"), value: g.powerWatts.map(Format.watts) ?? "--", color: .orange)
                        StatValue(title: L("已用内存", "Memory Used"), value: g.memoryInUse > 0 ? Format.memory(g.memoryInUse) : "--")
                        Spacer()
                    }
                }
            }
            if !g.states.isEmpty {
                FrequencyStates(gpu: g)
            }
            ProcessList(title: L("GPU 占用最高的进程", "Top Processes by GPU"), rows: model.ranking.byGPU) { String(format: "%.1f%%", $0.gpuPercent) }
            Text(footer(g))
                .font(.system(size: 10.5)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
        }
        .telemetryDetail(model, kind: .gpu)
    }

    private func footer(_ g: GPUSnapshot) -> String {
        var parts: [String] = []
        if !g.model.isEmpty { parts.append(g.model) }
        if g.coreCount > 0 { parts.append(L("\(g.coreCount) 核", "\(g.coreCount) cores")) }
        if let top = g.maxMegahertz { parts.append(L("最高 \(Format.megahertz(top))", "up to \(Format.megahertz(top))")) }
        let head = parts.isEmpty ? "" : parts.joined(separator: " · ") + L("。", ". ")
        return head + L("利用率包含系统的桌面合成；统一内存没有独立显存，已用内存只显示绝对值。", "Utilization includes system desktop compositing; unified memory has no dedicated VRAM, so memory used is shown as an absolute value.")
    }
}

/// 采样窗口内各频率档的停留时间。每档一根竖条，空闲时间单独列出。
private struct FrequencyStates: View {
    let gpu: GPUSnapshot

    var body: some View {
        let top = max(gpu.states.map(\.residency).max() ?? 0, 0.01)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("频率分布", "Frequency Distribution")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if let idle = gpu.idleFraction {
                    Text(L("空闲 \(Format.percent(idle * 100))", "Idle \(Format.percent(idle * 100))")).font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(gpu.states.enumerated()), id: \.offset) { _, state in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(state.residency > 0.005 ? Color.purple : Color.secondary.opacity(0.18))
                            .frame(height: max(2, 34 * state.residency / top))
                    }
                    .frame(maxWidth: .infinity)
                    .help(state.megahertz > 0
                          ? "\(Format.megahertz(state.megahertz)) · \(Format.percent(state.residency * 100))"
                          : Format.percent(state.residency * 100))
                }
            }
            .frame(height: 34)
            if let low = gpu.states.first?.megahertz, let high = gpu.states.last?.megahertz, high > 0 {
                HStack {
                    Text(Format.megahertz(low))
                    Spacer()
                    Text(Format.megahertz(high))
                }
                .font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(12)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                Text(model.running ? L("没有读到风扇。", "No fans found.") : L("散热功能已关闭。", "Thermal control is off.")).font(.callout).foregroundStyle(.secondary)
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
                Text(L("最低 \(Int(fan.minimumRPM))", "Min \(Int(fan.minimumRPM))")).font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
                if fan.mode != .automatic {
                    Text(L("目标 \(Int(fan.targetRPM))", "Target \(Int(fan.targetRPM))")).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    Spacer()
                }
                Text(L("最高 \(Int(fan.maximumRPM))", "Max \(Int(fan.maximumRPM))")).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            switch fan.mode {
            case .constant:
                FixedRPMSlider(model: model, fan: fan)
            case .sensor(let sensorID, let low, let high):
                CurveEditor(model: model, fan: fan, appliedSensor: sensorID, appliedLow: low, appliedHigh: high)
            case .automatic:
                Text(L("由系统固件按温度自动调节。", "Adjusted automatically by system firmware based on temperature.")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var modeTitle: String {
        switch fan.mode {
        case .automatic: return L("自动", "Auto")
        case .sensor: return L("温控", "Curve")
        case .constant(let rpm): return Double(rpm) >= fan.maximumRPM * 0.99 ? L("全速", "Full Speed") : L("固定", "Fixed")
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
            Picker(L("依据传感器", "Sensor"), selection: $sensor) {
                ForEach(sensorChoices, id: \.id) { sensor in
                    Text("\(sensor.name)  \(model.temperature(sensor.celsius))").tag(sensor.id)
                }
            }
            .controlSize(.small)
            HStack {
                Text(L("开始提速", "Ramp Up")).font(.system(size: 11)).frame(width: 64, alignment: .leading)
                Slider(value: Binding(get: { low }, set: { low = $0.rounded(); if high < low + 5 { high = min(low + 5, 105) } }),
                       in: 40...90).controlSize(.small)
                Text("\(Int(low))°C").font(.system(size: 11, design: .rounded)).monospacedDigit().frame(width: 36)
            }
            HStack {
                Text(L("满速温度", "Full Speed")).font(.system(size: 11)).frame(width: 64, alignment: .leading)
                Slider(value: Binding(get: { high }, set: { high = max($0.rounded(), low + 5) }), in: 60...105).controlSize(.small)
                Text("\(Int(high))°C").font(.system(size: 11, design: .rounded)).monospacedDigit().frame(width: 36)
            }
            HStack(alignment: .center) {
                Text(L("低于 \(Int(low))°C 保持最低转速，到 \(Int(high))°C 时达到 \(Int(fan.effectiveMaximumRPM)) RPM，中间线性提速。", "Minimum speed below \(Int(low))°C, rising linearly to \(Int(fan.effectiveMaximumRPM)) RPM at \(Int(high))°C."))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if dirty {
                    Button(L("还原", "Revert")) { reset() }.controlSize(.small)
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
            Text(dirty ? L("应用", "Apply") : L("已应用", "Applied")).frame(minWidth: 44)
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
            Text(L("温度传感器（\(sensors.count)）", "Temperature Sensors (\(sensors.count))")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(shown) { sensor in
                HStack {
                    Image(systemName: sensor.kind == .gpu ? "cpu.fill" : sensor.kind == .cpu ? "cpu" : "thermometer.medium")
                        .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
                    Text(sensor.name).font(.system(size: 11.5)).lineLimit(1)
                    if sensor.isGroupAverage {
                        Text(L("平均", "Avg")).font(.system(size: 9)).padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.fill.tertiary, in: Capsule())
                    }
                    Spacer()
                    Text(model.temperature(sensor.celsius)).font(.system(size: 11.5, design: .rounded)).monospacedDigit()
                        .foregroundStyle(sensor.celsius > 85 ? .red : sensor.celsius > 70 ? .orange : .primary)
                }
            }
            if let limit, sensors.count > limit {
                Button(expanded ? L("收起", "Show Less") : L("显示全部 \(sensors.count) 个", "Show All \(sensors.count)")) { expanded.toggle() }
                    .buttonStyle(.link).font(.system(size: 11))
            }
        }
        .padding(12)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
