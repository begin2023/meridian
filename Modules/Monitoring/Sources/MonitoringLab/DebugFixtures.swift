import AppKit

// 离屏 UI 验证用的假数据:不依赖真实系统状态,保证渲染冒烟可重复。
enum DebugFixtures {
    static func processes() -> [ProcessSample] {
        [
            ProcessSample(pid: 101, name: "Xcode", cpuPercent: 41.2, memoryBytes: 3_912_192_000,
                          iconPath: "/Applications/Xcode.app/Contents/MacOS/Xcode"),
            ProcessSample(pid: 202, name: "Safari", cpuPercent: 18.6, memoryBytes: 1_854_664_704,
                          iconPath: "/Applications/Safari.app/Contents/MacOS/Safari"),
            ProcessSample(pid: 303, name: "WindowServer", cpuPercent: 9.1, memoryBytes: 921_600_000,
                          iconPath: nil),
            ProcessSample(pid: 404, name: "MonitoringLab", cpuPercent: 2.4, memoryBytes: 148_897_792,
                          iconPath: "/Applications/MonitoringLab.app/Contents/MacOS/MonitoringLab"),
            ProcessSample(pid: 505, name: "mds_stores", cpuPercent: 0.8, memoryBytes: 89_128_960,
                          iconPath: nil),
        ]
    }

    static func waveHistory(count: Int = 120, base: Double = 30, amplitude: Double = 18) -> [Double] {
        (0..<count).map { index -> Double in
            let position = Double(index)
            let primary = amplitude * sin(position / 6.5)
            let secondaryAmplitude = amplitude * 0.4
            let secondary = secondaryAmplitude * sin(position / 2.3)
            return base + primary + secondary
        }
    }
}
