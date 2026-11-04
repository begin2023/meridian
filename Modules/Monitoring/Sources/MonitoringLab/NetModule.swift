import AppKit
import Darwin

// 网络模块:主接口上下行速率 + 接口累计/会话累计 + 当前 IP 与归属地。
final class NetModule: BaseModule {
    struct Snapshot {
        var upBytesPerSecond: Double = 0
        var downBytesPerSecond: Double = 0
        /// 物理网卡自开机或计数器复位以来的累计上传与下载字节；计数器回绕不会让它变小。
        var interfaceTotalUpBytes: UInt64 = 0
        var interfaceTotalDownBytes: UInt64 = 0
        /// 主接口的 IPv4(无则 IPv6)地址。
        var ipAddress: String = ""
    }

    // 采样队列独占的差分状态
    private var trafficSampler = NetworkTrafficSampler()

    // 主线程消费
    private var snapshot = Snapshot()
    private var downHistory: [Double] = []
    private var upHistory: [Double] = []

    private var downValueLabel: NSTextField?
    private var upValueLabel: NSTextField?
    private var graphView: LineGraphView?
    private var interfaceLabel: NSTextField?
    private var ipRow: LegendRowView?
    private var geoRow: LegendRowView?
    private var totalUpRow: LegendRowView?
    private var totalDownRow: LegendRowView?

    init() {
        super.init(id: "net", displayName: "网络")
    }

    override func sample() {
        let traffic = trafficSampler.sample()
        let primary = traffic.primaryInterface
        let primaryIP = primary.flatMap { Self.primaryIPAddress(of: $0) } ?? ""

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snapshot.downBytesPerSecond = max(traffic.downBytesPerSecond, 0)
            self.snapshot.upBytesPerSecond = max(traffic.upBytesPerSecond, 0)
            self.snapshot.interfaceTotalDownBytes = traffic.totalDownBytes
            self.snapshot.interfaceTotalUpBytes = traffic.totalUpBytes
            self.snapshot.ipAddress = primaryIP
            self.currentInterfaceNames = primary ?? "无活动接口"
            if AppSettings.shared.networkGeoLookupEnabled, primaryIP != self.lastLookedUpIP {
                self.lastLookedUpIP = primaryIP
                GeoResolver.shared.lookupIfNeeded()
            }
            self.applySnapshot()
        }
    }

    private var currentInterfaceNames: String = ""
    private var lastLookedUpIP: String = ""

    override func applySnapshot() {
        appendHistory(&downHistory, snapshot.downBytesPerSecond)
        appendHistory(&upHistory, snapshot.upBytesPerSecond)

        renderWidget(WidgetContent(
            iconSymbol: "arrow.up.arrow.down",
            text: "↑ \(Format.decimalBytes(snapshot.upBytesPerSecond, perSecond: true))",
            secondaryText: "↓ \(Format.decimalBytes(snapshot.downBytesPerSecond, perSecond: true))",
            fraction: min((snapshot.upBytesPerSecond + snapshot.downBytesPerSecond) / (10 * 1024 * 1024), 1),
            history: downHistory,
            secondaryHistory: upHistory
        ))

        downValueLabel?.stringValue = Format.decimalBytes(snapshot.downBytesPerSecond, perSecond: true)
        upValueLabel?.stringValue = Format.decimalBytes(snapshot.upBytesPerSecond, perSecond: true)
        graphView?.values = downHistory
        graphView?.secondaryValues = upHistory
        interfaceLabel?.stringValue = currentInterfaceNames.isEmpty ? "无活动接口" : currentInterfaceNames

        let lookupEnabled = AppSettings.shared.networkGeoLookupEnabled
        ipRow?.value = lookupEnabled
            ? (GeoResolver.shared.publicIP ?? (snapshot.ipAddress.isEmpty ? "—" : snapshot.ipAddress))
            : (snapshot.ipAddress.isEmpty ? "—" : snapshot.ipAddress)
        geoRow?.value = lookupEnabled ? GeoResolver.shared.currentText : "未启用在线查询"
        totalUpRow?.value = Format.decimalBytes(Double(snapshot.interfaceTotalUpBytes))
        totalDownRow?.value = Format.decimalBytes(Double(snapshot.interfaceTotalDownBytes))
    }

    /// 主接口的 IPv4 地址,无则回退 IPv6。
    static func primaryIPAddress(of interfaceName: String) -> String? {
        var interfacePointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfacePointer) == 0, let firstInterface = interfacePointer else { return nil }
        defer { freeifaddrs(interfacePointer) }

        var ipv6: String?
        var iterator = firstInterface
        while true {
            if let address = iterator.pointee.ifa_addr {
                let name = String(cString: iterator.pointee.ifa_name)
                if name == interfaceName {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let text = String(cString: host)
                        if address.pointee.sa_family == UInt8(AF_INET) {
                            return text
                        }
                        if address.pointee.sa_family == UInt8(AF_INET6), ipv6 == nil {
                            // IPv6 带作用域后缀(%en0),展示时去掉
                            ipv6 = text.split(separator: "%").first.map(String.init)
                        }
                    }
                }
            }
            if let next = iterator.pointee.ifa_next {
                iterator = next
            } else {
                break
            }
        }
        return ipv6
    }

    override func makePopupContentView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        // 头部
        let header = NSStackView(views: [])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8
        let titleLabel = NSTextField(labelWithString: "网络")
        titleLabel.font = AppTheme.font(ofSize: 15, weight: .semibold)
        titleLabel.textColor = AppTheme.primaryText
        let interfaceLabel = NSTextField(labelWithString: "")
        interfaceLabel.font = AppTheme.font(ofSize: 11)
        interfaceLabel.textColor = AppTheme.secondaryText
        interfaceLabel.lineBreakMode = .byTruncatingMiddle
        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(interfaceLabel)
        let settingsButton = HoverButton()
        settingsButton.image = AppTheme.symbol("gearshape", size: 12)
        settingsButton.identifier = NSUserInterfaceItemIdentifier("netSettingsButton")
        settingsButton.target = AppDelegate.shared
        settingsButton.action = #selector(AppDelegate.openPreferencesAction)
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        header.addArrangedSubview(headerSpacer)
        header.addArrangedSubview(settingsButton)
        header.translatesAutoresizingMaskIntoConstraints = false

        // 大数字:↓ 下载 / ↑ 上传
        let valuesRow = NSStackView(views: [])
        valuesRow.orientation = .horizontal
        valuesRow.spacing = 20
        let downTitle = NSTextField(labelWithString: "↓ 下载")
        downTitle.font = AppTheme.font(ofSize: 11, weight: .medium)
        downTitle.textColor = NSColor(calibratedRed: 0.4, green: 0.85, blue: 0.55, alpha: 1)
        let downValue = NSTextField(labelWithString: "0B/s")
        downValue.font = AppTheme.font(ofSize: 21, weight: .semibold)
        downValue.textColor = AppTheme.primaryText
        downValue.identifier = NSUserInterfaceItemIdentifier("netDownValue")
        let downStack = NSStackView(views: [downTitle, downValue])
        downStack.orientation = .vertical
        downStack.alignment = .leading
        downStack.spacing = 1

        let upColor = AppTheme.accent
        let upTitle = NSTextField(labelWithString: "↑ 上传")
        upTitle.font = AppTheme.font(ofSize: 11, weight: .medium)
        upTitle.textColor = upColor
        let upValue = NSTextField(labelWithString: "0B/s")
        upValue.font = AppTheme.font(ofSize: 21, weight: .semibold)
        upValue.textColor = AppTheme.primaryText
        upValue.identifier = NSUserInterfaceItemIdentifier("netUpValue")
        let upStack = NSStackView(views: [upTitle, upValue])
        upStack.orientation = .vertical
        upStack.alignment = .leading
        upStack.spacing = 1

        valuesRow.addArrangedSubview(downStack)
        valuesRow.addArrangedSubview(upStack)
        valuesRow.translatesAutoresizingMaskIntoConstraints = false

        // 曲线:绿色下行 + 橙色上行
        let graph = LineGraphView(frame: .zero)
        graph.lineColor = NSColor(calibratedRed: 0.4, green: 0.85, blue: 0.55, alpha: 1)
        graph.translatesAutoresizingMaskIntoConstraints = false
        graph.heightAnchor.constraint(equalToConstant: 64).isActive = true

        // 明细:当前 IP / 归属地 / 接口累计 / 会话累计
        let legendStack = NSStackView()
        legendStack.orientation = .vertical
        legendStack.spacing = 2
        legendStack.translatesAutoresizingMaskIntoConstraints = false
        let ipRow = LegendRowView(name: "当前 IP", color: NSColor(calibratedWhite: 0.6, alpha: 1))
        let geoRow = LegendRowView(name: "归属地", color: NSColor(calibratedWhite: 0.6, alpha: 1))
        let totalUpRow = LegendRowView(name: "累计上传", color: upColor)
        let totalDownRow = LegendRowView(name: "累计下载", color: NSColor(calibratedRed: 0.4, green: 0.85, blue: 0.55, alpha: 1))
        let legendRows = [ipRow, geoRow, totalUpRow, totalDownRow]
        for row in legendRows {
            legendStack.addArrangedSubview(row)
        }

        stack.addArrangedSubview(header)
        stack.setCustomSpacing(12, after: header)
        stack.addArrangedSubview(valuesRow)
        stack.addArrangedSubview(graph)
        stack.addArrangedSubview(legendStack)

        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        graph.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        legendStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        for row in legendRows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let widthAnchor = stack.widthAnchor.constraint(equalToConstant: 340)
        widthAnchor.priority = .defaultHigh
        widthAnchor.isActive = true

        downValueLabel = downValue
        upValueLabel = upValue
        graphView = graph
        self.interfaceLabel = interfaceLabel
        self.ipRow = ipRow
        self.geoRow = geoRow
        self.totalUpRow = totalUpRow
        self.totalDownRow = totalDownRow
        return stack
    }

    override func readOnlySummary() -> [String: Any] {
        var result = super.readOnlySummary()
        result["upBytesPerSecond"] = snapshot.upBytesPerSecond
        result["downBytesPerSecond"] = snapshot.downBytesPerSecond
        result["interfaceTotalUpBytes"] = snapshot.interfaceTotalUpBytes
        result["interfaceTotalDownBytes"] = snapshot.interfaceTotalDownBytes
        result["ipAddress"] = snapshot.ipAddress
        result["interface"] = currentInterfaceNames
        result["geoLookupEnabled"] = AppSettings.shared.networkGeoLookupEnabled
        result["geoText"] = AppSettings.shared.networkGeoLookupEnabled
            ? GeoResolver.shared.currentText : "未启用在线查询"
        result["downHistory"] = downHistory
        result["upHistory"] = upHistory
        return result
    }
}

#if DEBUG
extension NetModule {
    func debugSnapshot() -> Snapshot { snapshot }

    func loadDebugSnapshot() {
        snapshot = Snapshot(
            upBytesPerSecond: 318_400,
            downBytesPerSecond: 1_742_800,
            interfaceTotalUpBytes: 21_980_000_000,
            interfaceTotalDownBytes: 53_110_000_000,
            ipAddress: "192.0.2.10"
        )
        downHistory = DebugFixtures.waveHistory(base: 1_400_000, amplitude: 900_000)
        upHistory = DebugFixtures.waveHistory(base: 260_000, amplitude: 180_000)
        currentInterfaceNames = "en1"
        GeoResolver.shared.setDebugText("Shanghai, CN · China Telecom")
    }
}
#endif

extension NetModule {
    /// 各接口累计收发字节（64 位）。数据源见 `InterfaceCounters`。
    static func interfaceCounters() -> [String: (received: UInt64, sent: UInt64)] {
        InterfaceCounters.read()
    }
}

#if DEBUG
extension NetModule {
    static func debugDumpBuffer(path: String) {
        var mib: [Int32] = [CTL_NET, AF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        _ = sysctl(&mib, 6, nil, &length, nil, 0)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: 1)
        _ = sysctl(&mib, 6, buffer, &length, nil, 0)
        let data = Data(bytes: buffer, count: length)
        try? data.write(to: URL(fileURLWithPath: path))
        buffer.deallocate()
    }
}
#endif
