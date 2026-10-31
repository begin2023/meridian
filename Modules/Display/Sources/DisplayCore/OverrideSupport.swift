import Foundation

/// Shared override-plist helpers: path derivation, scale-resolutions blob
/// encoding and ppmm math. The app uses them to build a preview and the
/// helper re-validates everything it receives before touching the filesystem.
public enum OverrideSupport {
    /// /Library/Displays/Contents/Resources/Overrides — the user-level
    /// override root that WindowServer reads on display attach (works with
    /// SIP enabled; the System copy is the read-only fallback).
    public static let overridesRoot = "/Library/Displays/Contents/Resources/Overrides"

    /// Directory for one display, e.g. .../Overrides/DisplayVendorID-5e3.
    public static func vendorDirectory(vendorID: UInt32) -> String {
        "\(overridesRoot)/DisplayVendorID-\(String(vendorID, radix: 16))"
    }

    /// Plist file for one display, e.g. .../DisplayVendorID-5e3/DisplayProductID-2702.
    public static func overridePath(vendorID: UInt32, productID: UInt32) -> String {
        "\(vendorDirectory(vendorID: vendorID))/DisplayProductID-\(String(productID, radix: 16))"
    }

    /// Encodes one scale-resolutions entry. HiDPI entries are 16 bytes:
    /// big-endian uint32 width, height, flags (1 = HiDPI), scale (16.16
    /// fixed point 1.0). Non-HiDPI entries are 8 bytes: width, height.
    public static func scaleResolutionBlob(pixelWidth: Int, pixelHeight: Int, hiDPI: Bool) -> Data {
        var data = Data()
        func appendBEUInt32(_ value: UInt32) {
            var be = value.bigEndian
            withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        }
        appendBEUInt32(UInt32(pixelWidth))
        appendBEUInt32(UInt32(pixelHeight))
        if hiDPI {
            appendBEUInt32(1)          // flags: HiDPI
            appendBEUInt32(0x00010000) // scale: 1.0 in 16.16 fixed point
        }
        return data
    }

    /// Builds the default HiDPI resolution set for a display: 2x native
    /// (full Retina desktop) and 1.5x (more desktop area at lower cost).
    public static func defaultScaleResolutions(nativeWidth: Int, nativeHeight: Int) -> [Data] {
        [
            scaleResolutionBlob(pixelWidth: nativeWidth * 2, pixelHeight: nativeHeight * 2, hiDPI: true),
            scaleResolutionBlob(pixelWidth: nativeWidth * 3 / 2, pixelHeight: nativeHeight * 3 / 2, hiDPI: true),
        ]
    }

    /// Pixels per millimetre from the display's physical size; WindowServer
    /// uses this to pick the default scaled mode.
    public static func targetDefaultPPMM(nativeWidth: Int, widthMillimetres: Int) -> Double {
        guard widthMillimetres > 0 else { return 4.27 }
        return Double(nativeWidth) / Double(widthMillimetres)
    }

    /// Sanity checks applied to client-supplied override payloads before the
    /// helper writes anything.
    public static func validateScaleResolutions(_ blobs: [Data]) -> Bool {
        guard !blobs.isEmpty, blobs.count <= 64 else { return false }
        return blobs.allSatisfy { blob in
            blob.count == 8 || blob.count == 12 || blob.count == 16
        }
    }
}
