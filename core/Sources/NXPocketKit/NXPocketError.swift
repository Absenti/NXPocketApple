import Foundation

/// Every failure iPorterNX reports, with a stable code the UI and the tests match on.
public struct NXPocketError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Code: String, Sendable {
        case packageMissing
        case packageDamaged
        case packageUnsupported
        case packageInconsistent
        case unsafePath
        case symbolicLink
        case hashMismatch
        case sizeMismatch
        case notAMachO
        case wrongArchitecture
        case wrongMachOType
        case fatBinary
        case hiddenMachO
        case forbiddenDependency
        case minimumOSNewer
        case notSigned
        case wrongSigner
        case teamMismatch
        case noCertificate
        case certificateExpired
        case signingFailed
        case notEnoughSpace
        case deviceUnavailable
        case transferFailed
        case engineMissing
        case engineFailed
        case cancelled
    }

    public let code: Code
    public let detail: String
    /// The file the failure is about, when there is one.
    public let path: String?

    public init(_ code: Code, _ detail: String, path: String? = nil) {
        self.code = code
        self.detail = detail
        self.path = path
    }

    public var description: String {
        guard let path else { return "\(code.rawValue): \(detail)" }
        return "\(code.rawValue): \(detail) [\(path)]"
    }

    public var localizedDescription: String { detail }
}
