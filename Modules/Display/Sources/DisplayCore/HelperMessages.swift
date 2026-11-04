import Foundation

/// Wire format between the app and the root helper daemon (authenticated socket).
/// The app sends a `HelperCommand` as one framed message; the helper replies with
/// a `HelperResult` carrying the same id.
public struct HelperCommand: Codable {
    public var id: String
    public var action: String // "write" | "remove"
    public var vendorID: UInt32?
    public var productID: UInt32?
    public var productName: String?
    public var scaleResolutions: [String]? // base64 blobs
    public var targetDefaultPPMM: Double?

    public init(
        id: String,
        action: String,
        vendorID: UInt32?,
        productID: UInt32?,
        productName: String?,
        scaleResolutions: [String]?,
        targetDefaultPPMM: Double?
    ) {
        self.id = id
        self.action = action
        self.vendorID = vendorID
        self.productID = productID
        self.productName = productName
        self.scaleResolutions = scaleResolutions
        self.targetDefaultPPMM = targetDefaultPPMM
    }
}

public struct HelperResult: Codable {
    public var id: String
    public var ok: Bool
    public var message: String

    public init(id: String, ok: Bool, message: String) {
        self.id = id
        self.ok = ok
        self.message = message
    }
}
