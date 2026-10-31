import CoreGraphics
import Foundation
import IOKit

/// Reads the connected display's EDID out of the IO registry and derives HDR
/// capability from the CTA-861 extension. On Apple Silicon the EDID lives in
/// dictionary-valued properties of DCPAVServiceProxy/framebuffer nodes (the
/// same nodes AVServiceLocator ranks), reachable with a recursive property
/// search — no IOAVServiceCopyEDID call, which crashes on this OS build.
///
/// The decisive field is the HDR Static Metadata Data Block's EOTF bitmap:
/// a panel that only declares traditional SDR gamma (no PQ/ST2084, no HLG)
/// cannot show HDR10 content, so toggling macOS's HDR state has no visible
/// effect — exactly the "fake HDR" many gaming monitors ship with.
public enum EDIDCapability {
    public struct HDRInfo: Equatable {
        /// SMPTE ST2084 (PQ) — the transfer function of HDR10 content.
        public let pqSupported: Bool
        /// Hybrid log-gamma.
        public let hlgSupported: Bool
        /// "Traditional gamma — HDR" (rare, not HDR10).
        public let traditionalHDRSupported: Bool
        /// Declared desired-content max luminance in cd/m² (≈ value-50 per
        /// CTA-861); nil when the field is absent or below SDR levels.
        public let maxLuminanceCDm2: Int?
    }

    private static let cacheLock = NSLock()
    private static var cache: [CGDirectDisplayID: HDRInfo?] = [:]

    /// Returns nil when the EDID is unreadable or carries no CTA-861 HDR
    /// metadata block; callers then fall back to the SkyLight capability probe.
    /// The registry walk runs once per display per session (the menu rebuilds
    /// on every open).
    public static func hdrInfo(for display: CGDirectDisplayID) -> HDRInfo? {
        cacheLock.lock()
        if let cached = cache[display] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let vendor = Int(CGDisplayVendorNumber(display))
        let product = Int(CGDisplayModelNumber(display))
        var info: HDRInfo?
        for edid in registryEDIDs() where matches(edid: edid, vendor: vendor, product: product) {
            info = parseHDR(from: edid)
            break
        }

        cacheLock.lock()
        cache[display] = info
        cacheLock.unlock()
        return info
    }

    // MARK: - Registry access

    /// EDID bytes from every registry entry carrying an "EDID" property. On
    /// Apple Silicon the block lives on the HDMI port controller node under
    /// the DCP AV service tree (class AppleHDMIPortController), so no class
    /// filter is applied — the vendor/product check picks the matching panel.
    private static func registryEDIDs() -> [Data] {
        var iterator: io_iterator_t = 0
        let status = IORegistryCreateIterator(
            kIOMainPortDefault,
            kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        )
        guard status == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var results: [Data] = []
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }
            // IORegistryEntrySearchCFProperty imports as an autoreleasing
            // CFTypeRef (no Unmanaged wrapper) on this SDK. A direct-property
            // search is enough: the recursive iterator already visits the
            // port controller node itself.
            guard let value = IORegistryEntrySearchCFProperty(
                entry,
                kIOServicePlane,
                "EDID" as CFString,
                kCFAllocatorDefault,
                IOOptionBits(0)
            ) else {
                continue
            }
            if let data = value as? Data, data.count >= 128, data.count % 128 == 0 {
                results.append(data)
            }
        }
        return results
    }

    /// EDID base block: vendor number is bytes 8-9 read as one big-endian
    /// word, product code is bytes 10-11 read little-endian.
    private static func matches(edid: Data, vendor: Int, product: Int) -> Bool {
        let edidVendor = Int(edid[8]) << 8 | Int(edid[9])
        let edidProduct = Int(edid[10]) | Int(edid[11]) << 8
        return edidVendor == vendor && edidProduct == product
    }

    // MARK: - CTA-861 parsing

    private static func parseHDR(from edid: Data) -> HDRInfo? {
        let extensionCount = Int(edid[126])
        for index in 0..<extensionCount {
            let base = 128 * (index + 1)
            guard base + 128 <= edid.count, edid[base] == 0x02 else { continue } // CTA-861
            let ctaBlock = edid[base..<(base + 128)]
            let dtdStart = Int(ctaBlock[ctaBlock.startIndex + 2])
            guard dtdStart >= 4, dtdStart <= 127 else { continue }

            var offset = base + 4
            let end = base + dtdStart
            while offset < end {
                let header = edid[offset]
                let tag = header >> 5
                let length = Int(header & 0x1F)
                defer { offset += 1 + length }
                guard tag == 7, length >= 4 else { continue } // ext tag + flags + EOTF + CLL
                let extendedTag = edid[offset + 1]
                guard extendedTag == 0x06 else { continue } // HDR static metadata
                // Payload: [0] flags, [1] EOTF bitmap, [2] max CLL, [3] max FALL.
                let eotfBitmap = edid[offset + 3]
                let maxCLL = Int(edid[offset + 4])
                let luminance = maxCLL > 50 ? maxCLL - 50 : nil
                return HDRInfo(
                    pqSupported: eotfBitmap & 0x04 != 0,
                    hlgSupported: eotfBitmap & 0x08 != 0,
                    traditionalHDRSupported: eotfBitmap & 0x02 != 0,
                    maxLuminanceCDm2: luminance
                )
            }
        }
        return nil
    }
}
