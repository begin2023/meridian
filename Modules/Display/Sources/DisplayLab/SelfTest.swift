import AppKit
import DisplayCore

/// Pure-logic regression for the protocol and encoding layers, no hardware
/// involved. Reports to /tmp/displaylab-self-test.txt with a final
/// SELF_TEST_PASS/FAIL marker.
enum SelfTest {
    static func run() {
        var failures = 0
        var report: [String] = []

        func check(_ condition: Bool, _ label: String) {
            if condition {
                report.append("ok \(label)")
            } else {
                failures += 1
                report.append("FAIL \(label)")
            }
        }

        // DDC set packet: 6 bytes, checksum reproducible by XOR.
        let setPacket = DDCProtocol.setPacket(vcp: 0x10, value: 63)
        check(setPacket.count == 6, "set packet length")
        check(setPacket[0] == 0x84 && setPacket[1] == 0x03 && setPacket[2] == 0x10, "set packet framing")
        check(setPacket[3] == 0 && setPacket[4] == 63, "set packet payload")
        var expected: UInt8 = DDCProtocol.sinkAddress ^ DDCProtocol.sourceAddress
        for byte in setPacket.prefix(5) {
            expected ^= byte
        }
        check(setPacket[5] == expected, "set packet checksum")

        // Get reply parsing: max 100, current 63, checksum seeds with 0x50.
        var reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x3F, 0x00]
        var checksum: UInt8 = DDCProtocol.replyChecksumSeed
        for byte in reply.prefix(10) {
            checksum ^= byte
        }
        reply[10] = checksum
        let parsed = DDCProtocol.parseGetReply(reply)
        check(parsed?.max == 100 && parsed?.current == 63, "get reply parse")

        // Corrupted checksum must be rejected.
        var corrupt = reply
        corrupt[10] ^= 0xFF
        check(DDCProtocol.parseGetReply(corrupt) == nil, "get reply checksum rejects corruption")

        // scale-resolutions blobs.
        let hidpiBlob = OverrideSupport.scaleResolutionBlob(pixelWidth: 5120, pixelHeight: 2880, hiDPI: true)
        let lodpiBlob = OverrideSupport.scaleResolutionBlob(pixelWidth: 2560, pixelHeight: 1440, hiDPI: false)
        check(hidpiBlob.count == 16, "hidpi blob size")
        check(lodpiBlob.count == 8, "lodpi blob size")
        check(hidpiBlob[0] == 0x00 && hidpiBlob[1] == 0x00 && hidpiBlob[2] == 0x14 && hidpiBlob[3] == 0x00, "hidpi blob width BE (5120)")
        check(hidpiBlob[8] == 0x00 && hidpiBlob[9] == 0x00 && hidpiBlob[10] == 0x00 && hidpiBlob[11] == 0x01, "hidpi blob flags")
        check(hidpiBlob[12] == 0x00 && hidpiBlob[13] == 0x01 && hidpiBlob[14] == 0x00 && hidpiBlob[15] == 0x00, "hidpi blob scale 1.0")

        // EDID UUID identity parsing.
        let identity = AVServiceLocator.edidIdentity(fromUUID: "05E30227-0000-0000-2921-0103803C2278")
        check(identity?.vendor == 0x05E3, "edid uuid vendor")
        check(identity?.product == 0x2702, "edid uuid product")

        // Override path derivation.
        check(OverrideSupport.overridePath(vendorID: 0x05E3, productID: 0x2702).hasSuffix("DisplayVendorID-5e3/DisplayProductID-2702"), "override path layout")

        // Validation rejects malformed blobs.
        check(OverrideSupport.validateScaleResolutions([hidpiBlob, lodpiBlob]), "validation accepts well formed")
        check(!OverrideSupport.validateScaleResolutions([Data([0x00])]), "validation rejects short blob")

        report.append(failures == 0 ? "SELF_TEST_PASS" : "SELF_TEST_FAIL")
        let text = report.joined(separator: "\n")
        try? text.write(toFile: "/tmp/displaylab-self-test.txt", atomically: true, encoding: .utf8)
        fflush(stdout)
        print(text)
        exit(failures == 0 ? 0 : 1)
    }
}
