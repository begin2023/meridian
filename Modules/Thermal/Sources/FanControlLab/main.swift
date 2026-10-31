import AppKit

// 无头模式：读一次风扇与传感器后退出，供冒烟测试与诊断使用。
if CommandLine.arguments.contains("--probe") {
    let client = SMCClient()
    do {
        try client.open()
    } catch {
        print("SMC open failed: \(error)")
        exit(2)
    }
    guard let fanCount = client.readUInt8("FNum") else {
        print("FNum unreadable")
        exit(2)
    }
    print("fans: \(fanCount)")
    for index in 0..<fanCount {
        let prefix = "F\(index)"
        let current = client.readRPM("\(prefix)Ac") ?? 0
        let minimum = client.readRPM("\(prefix)Mn") ?? 0
        let maximum = client.readRPM("\(prefix)Mx") ?? 0
        print("fan\(index): min=\(minimum) current=\(current) max=\(maximum)")
    }
    if let database = SensorDatabase.load() {
        print("model: \(database.canonicalModel)")
        var printed = 0
        for definition in database.sensors {
            if let temperature = client.readTemperatureCelsius(definition.key), temperature > 0, printed < 6 {
                print("sensor: \(definition.key) \(definition.name) \(temperature)")
                printed += 1
            }
        }
        print("sensors-known: \(database.sensors.count)")
    } else {
        print("sensor database: unavailable")
    }
    client.close()
    exit(0)
}

if !CommandLine.arguments.contains("--test-instance"),
   let bundleIdentifier = Bundle.main.bundleIdentifier {
    let existingInstance = NSRunningApplication
        .runningApplications(withBundleIdentifier: bundleIdentifier)
        .first { $0.processIdentifier != getpid() }
    if let existingInstance {
        existingInstance.activate()
        exit(EXIT_SUCCESS)
    }
}

let application = NSApplication.shared
let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.setActivationPolicy(.accessory)

// 未捕获 ObjC 异常落盘，便于闪退诊断（崩溃报告里常常缺 asi 段）。
NSSetUncaughtExceptionHandler { exception in
    let stack = exception.callStackSymbols.joined(separator: "\n")
    let text = """
    [\(Date())] \(exception.name.rawValue): \(exception.reason ?? "-")
    \(stack)

    """
    let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/FanControlLab-exceptions.log")
    if let handle = FileHandle(forWritingAtPath: url.path) {
        handle.seekToEndOfFile()
        handle.write(text.data(using: .utf8)!)
        try? handle.close()
    } else {
        try? text.write(toFile: url.path, atomically: true, encoding: .utf8)
    }
}

application.run()
