import CoreGraphics
import DisplayPrivate
import Foundation
import IOKit

public enum AVServiceError: LocalizedError {
    case noCandidate(CGDirectDisplayID)
    case creationFailed(CGDirectDisplayID)

    public var errorDescription: String? {
        switch self {
        case .noCandidate(let identifier):
            return "在 IO 注册表中找不到显示器 \(identifier) 对应的 AV 服务。"
        case .creationFailed(let identifier):
            return "为显示器 \(identifier) 创建 AV 服务失败。"
        }
    }
}

/// Maps a CGDirectDisplayID to its IOAVService, the handle DDC/CI traffic
/// goes through on Apple Silicon. Candidates are the DCPAVServiceProxy and
/// framebuffer-shim nodes in the IO registry; each carries an "EDID UUID"
/// (vendor/product identity) and a service-plane path that can be matched
/// against the display's IODisplayLocation reported by CoreDisplay. This
/// matches the registry identity without relying on IOAVServiceCopyEDID.
public enum AVServiceLocator {
    private static let candidateClasses: Set<String> = [
        "DCPAVServiceProxy",
        "AppleCLCD2",
        "IOMobileFramebufferShim",
    ]

    public static func avService(for display: CGDirectDisplayID) throws -> OpaquePointer {
        let expectedVendor = Int(CGDisplayVendorNumber(display))
        let expectedProduct = Int(CGDisplayModelNumber(display))
        let expectedLocation = displayLocation(for: display)

        let debugEnabled = getenv("DISPLAYLAB_DEBUG_AVSERVICE") != nil
        let isBuiltIn = CGDisplayIsBuiltin(display) != 0
        let locationToken = displayToken(fromLocation: expectedLocation)

        var scored = registryCandidates().map { candidate -> (candidate: Candidate, score: Int) in
            let score = matchScore(
                candidate: candidate,
                expectedVendor: expectedVendor,
                expectedProduct: expectedProduct,
                expectedLocation: expectedLocation,
                locationToken: locationToken,
                isBuiltIn: isBuiltIn
            )
            if debugEnabled {
                NSLog("DisplayLab avService: candidate class=%@ score=%d", candidate.className, score)
            }
            return (candidate, score)
        }
        scored.sort { $0.score > $1.score }

        // Keep every registry object alive until the winning creation attempt
        // is known. Releasing failed candidates inside the probe loop caused a
        // second release below, corrupting IOKit/Foundation memory.
        var createdService: OpaquePointer?
        var winningIndex: Int?
        for (index, ranked) in scored.enumerated() where ranked.score > 0 {
            if let service = IOAVServiceCreateWithService(kCFAllocatorDefault, ranked.candidate.entry) {
                if debugEnabled {
                    NSLog("DisplayLab avService: created from class=%@ score=%d", ranked.candidate.className, ranked.score)
                }
                createdService = service
                winningIndex = index
                break
            }
        }
        // Some OS builds keep the created IOAVService backed by the winning
        // registry entry; retain that entry for the service's lifetime.
        for (index, candidate) in scored.enumerated() where index != winningIndex {
            IOObjectRelease(candidate.candidate.entry)
        }
        if let createdService {
            return createdService
        }
        throw AVServiceError.creationFailed(display)
    }

    /// "IOService:/.../dispext0@84000000/IOMobileFramebufferShim" →
    /// "dispext0"; proxy paths carry the same token ("dispext0:dcpav-...").
    private static func displayToken(fromLocation location: String?) -> String? {
        guard let location else { return nil }
        for component in location.split(separator: "/") {
            if component.hasPrefix("disp") {
                let token = component.split(separator: "@").first
                return token.map(String.init)
            }
        }
        return nil
    }

    // MARK: - Candidate collection

    private struct Candidate {
        let entry: io_service_t
        let className: String
        let path: String
        let edidUUID: String?
        let location: String?
    }

    private static func registryCandidates() -> [Candidate] {
        var iterator: io_iterator_t = 0
        let status = IORegistryCreateIterator(
            kIOMainPortDefault,
            kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        )
        guard status == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var candidates: [Candidate] = []
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }

            var classNameBuffer = [CChar](repeating: 0, count: 128)
            guard IOObjectGetClass(entry, &classNameBuffer) == KERN_SUCCESS else {
                IOObjectRelease(entry)
                continue
            }
            let className = String(cString: classNameBuffer)
            guard candidateClasses.contains(className) else {
                IOObjectRelease(entry)
                continue
            }

            var pathBuffer = [CChar](repeating: 0, count: 1024)
            let path = IORegistryEntryGetPath(entry, kIOServicePlane, &pathBuffer) == KERN_SUCCESS
                ? String(cString: pathBuffer)
                : ""

            candidates.append(
                Candidate(
                    entry: entry,
                    className: className,
                    path: path,
                    edidUUID: stringProperty(entry, name: "EDID UUID"),
                    location: stringProperty(entry, name: "Location")
                )
            )
        }
        return candidates
    }

    private static func stringProperty(_ entry: io_service_t, name: String) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(
            entry,
            name as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return nil
        }
        return value as? String
    }

    // MARK: - Matching

    private static func matchScore(
        candidate: Candidate,
        expectedVendor: Int,
        expectedProduct: Int,
        expectedLocation: String?,
        locationToken: String?,
        isBuiltIn: Bool
    ) -> Int {
        var score = 0

        if let uuid = candidate.edidUUID, let identity = edidIdentity(fromUUID: uuid) {
            if identity.vendor == expectedVendor, identity.product == expectedProduct {
                score += 6
            }
        }

        // The CoreDisplay IODisplayLocation equals the service-plane path of
        // the display's framebuffer node; an exact path hit is decisive.
        if let expectedLocation, !expectedLocation.isEmpty, candidate.path == expectedLocation {
            score += 10
        }

        // Proxy entries live under a path segment named after the display
        // (…/dispext0:dcpav-service-epic:0/DCPAVServiceProxy).
        if let locationToken, candidate.path.contains("/" + locationToken) {
            score += 8
        }

        if let location = candidate.location {
            if isBuiltIn, location == "Internal" {
                score += 2
            }
            if !isBuiltIn, location == "External" {
                score += 2
            }
        }

        return score
    }

    /// "05E30227-..." → vendor 0x05E3, product 0x2702. The product half is
    /// two big-endian-written EDID bytes (0x02, 0x27) that together read
    /// little-endian as 0x2702, matching CGDisplayModelNumber.
    public static func edidIdentity(fromUUID uuid: String) -> (vendor: Int, product: Int)? {
        let hex = uuid.replacingOccurrences(of: "-", with: "")
        guard hex.count >= 8,
              let vendor = Int(hex.prefix(4), radix: 16) else {
            return nil
        }
        let productLow = hex[hex.index(hex.startIndex, offsetBy: 4)..<hex.index(hex.startIndex, offsetBy: 6)]
        let productHigh = hex[hex.index(hex.startIndex, offsetBy: 6)..<hex.index(hex.startIndex, offsetBy: 8)]
        guard let lowByte = Int(productLow, radix: 16),
              let highByte = Int(productHigh, radix: 16) else {
            return nil
        }
        let product = lowByte | highByte << 8
        return (vendor: vendor, product: product)
    }

    private static func displayLocation(for display: CGDirectDisplayID) -> String? {
        guard let info = CoreDisplayBridge.createInfoDictionary(for: display) else {
            return nil
        }
        return info["IODisplayLocation"] as? String
    }
}
