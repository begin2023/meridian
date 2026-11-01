import DiskArbitration
import Foundation

/// 挂载卷过滤：DMG、虚拟盘这类“虚拟接口”设备会出现在 /Volumes 下，但
/// 不是真正的磁盘。例如 BetterDisplay 从 DMG 运行时，面板里会多出一行
/// 159 MB 的 “BetterDisplay” 用量。内置盘和外接物理磁盘仍然保留。
enum MountedVolumeFilter {
    static func isVirtualDevice(_ url: URL, session: DASession) -> Bool {
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any]
        else { return false }
        let model = description[kDADiskDescriptionDeviceModelKey as String] as? String
        let proto = description[kDADiskDescriptionDeviceProtocolKey as String] as? String
        let path = description[kDADiskDescriptionDevicePathKey as String] as? String
        return model == "Disk Image"
            || proto == "Virtual Interface"
            || (path?.contains("IOHDIXController") ?? false)
    }
}
