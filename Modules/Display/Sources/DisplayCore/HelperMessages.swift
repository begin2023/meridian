import Foundation

/// Wire format between the app and the root helper daemon (file protocol).
/// The app writes a HelperCommand, the daemon executes it and writes a
/// HelperResult with the matching id.
public struct HelperCommand: Codable {
    public var id: String
    public var action: String // "write" | "remove" | "list"
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
    public var overrides: [String]?

    public init(id: String, ok: Bool, message: String, overrides: [String]? = nil) {
        self.id = id
        self.ok = ok
        self.message = message
        self.overrides = overrides
    }
}
