import Foundation

/// Where NXPocketApple keeps things. Both apps read these names, so they live in one place.
public enum GameLayout {
    public static let gamesFolder = "games"
    public static let incomingFolder = ".incoming"
    /// The complete RomFS image of a game: one file, so it copies at full speed and a partial copy is detectable.
    public static let romfsFile = "romfs.img"
    /// Add-on content, one `<index>.img` per DLC.
    public static let addOnFolder = "aoc"
    /// A Mac app writes this last: the folder is complete and may be imported. A folder without it is a partial transfer.
    public static let completeMarker = ".complete"
    /// A Mac app leaves this, and only this, in a transfer it could not finish: the shell removes such a folder at once.
    public static let abandonedMarker = ".abandoned"
    public static let signingRecord = ".signing.json"
    public static let launchMarker = ".launching"
    public static let importLog = "import-log.txt"
    public static let icon = "icon.png"

    /// An unfinished transfer in which nothing has changed for this long has lost its sender: it is removed. A live copy
    /// writes every second, over the cable or Wi-Fi alike, so ten minutes of silence is not a pause.
    public static let incomingIdleLimit: TimeInterval = 600
    public static let importLogByteLimit = 256 * 1024

    public static func gamesDirectory(in documents: URL) -> URL {
        documents.appendingPathComponent(gamesFolder, isDirectory: true)
    }

    public static func incomingDirectory(in documents: URL) -> URL {
        documents.appendingPathComponent(incomingFolder, isDirectory: true)
    }

    public static func gameDirectory(titleID: TitleID, in documents: URL) -> URL {
        gamesDirectory(in: documents).appendingPathComponent(titleID.description, isDirectory: true)
    }
}

/// The signing state of an installed game: which certificate signed it, and when that certificate runs out.
public struct SigningRecord: Codable, Equatable, Sendable {
    public var certificateSHA256: String
    public var identifier: String
    public var teamID: String
    public var subject: String
    public var signedAt: Date
    public var expires: Date
    /// Which entitlements the signature carries (`SigningIdentity.entitlementsTag`). Nil in a record written before
    /// there was a choice: those games carry the provisioning profile's, as every game did.
    public var entitlements: String?

    public init(certificateSHA256: String, identifier: String, teamID: String, subject: String,
                signedAt: Date, expires: Date, entitlements: String? = nil) {
        self.certificateSHA256 = certificateSHA256
        self.identifier = identifier
        self.teamID = teamID
        self.subject = subject
        self.signedAt = signedAt
        self.expires = expires
        self.entitlements = entitlements
    }

    /// What a record without an `entitlements` field means.
    public static let defaultEntitlementsTag = "profile"

    /// The app refreshes a game's signature before the certificate runs out, not after.
    public static let refreshWindow: TimeInterval = 24 * 3600

    public func needsResign(against identity: SigningIdentity, now: Date = Date()) -> Bool {
        certificateSHA256 != identity.certificateSHA256
            || identifier != identity.identifier
            || expires.timeIntervalSince(now) < Self.refreshWindow
            // A game signed with other entitlements than the ones that now load on this phone (the app switched after
            // iOS refused the first choice) is signed again, with no click from the player.
            || (identity.entitlementsTag.map { $0 != (entitlements ?? Self.defaultEntitlementsTag) } ?? false)
    }
}

/// A certificate that can sign code, as the app sees it. Held in the keychain, never on disk.
public struct SigningIdentity: Equatable, Sendable {
    public var identifier: String
    public var teamID: String
    public var certificateSHA256: String
    public var subject: String
    public var expires: Date
    /// Which entitlements a game is signed with: `"profile"` (the provisioning profile's) or `"app"` (the ones in the
    /// running app's own signature). Nil leaves the choice to the signer.
    public var entitlementsTag: String?

    public init(identifier: String, teamID: String, certificateSHA256: String, subject: String, expires: Date,
                entitlementsTag: String? = nil) {
        self.identifier = identifier
        self.teamID = teamID
        self.certificateSHA256 = certificateSHA256
        self.subject = subject
        self.expires = expires
        self.entitlementsTag = entitlementsTag
    }

    public var isExpired: Bool { expires <= Date() }
}

/// Signing a framework on the device, the way LiveContainer does. The iOS app implements this with zsign; the
/// Mac app and the tests use implementations that do not need a certificate.
public protocol FrameworkSigner: Sendable {
    func sign(framework: URL, identity: SigningIdentity) throws -> CodeSignatureInfo
}
