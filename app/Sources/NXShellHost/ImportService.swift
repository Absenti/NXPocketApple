import Foundation
import NXPocketKit

/// What the shell does with a finished transfer: verify the package, sign its framework with the user's certificate,
/// then move it into the library. An unfinished transfer is never touched.
public final class ImportService: @unchecked Sendable {
    public struct Progress: Sendable {
        public var stage: ImportStage
        public var fraction: Double
        public var detail: String
    }

    public let documents: URL
    public let importer: GameImporter
    private let signer: FrameworkSigner
    private let log: ImportLog?
    private let fileManager: FileManager

    public init(documents: URL, signer: FrameworkSigner, fileManager: FileManager = .default) {
        self.documents = documents
        self.importer = GameImporter(documents: documents, fileManager: fileManager)
        self.signer = signer
        self.log = ImportLog.standard(in: documents)
        self.fileManager = fileManager
    }

    /// Transfers that carry `.complete`, oldest first.
    public func pending() -> [URL] {
        importer.completedIncoming()
    }

    /// What one pass over the finished transfers did: the games it installed, and each transfer it refused with why.
    public struct Report: Sendable {
        public var imported: [InstalledGame] = []
        public var refused: [(transfer: String, error: NXPocketError)] = []
    }

    /// Imports every finished transfer. A certificate is required: an unsigned framework would be moved into the
    /// library and then refuse to load, so a game is only installed when it can be signed.
    @discardableResult
    public func importAll(identity: SigningIdentity?, options: ImportOptions = .default,
                          progress: (Progress) -> Void = { _ in }) throws -> [InstalledGame] {
        let report = try importEach(identity: identity, options: options, progress: progress)
        if report.imported.isEmpty, let first = report.refused.first { throw first.error }
        return report.imported
    }

    /// Imports every finished transfer and says what became of each: a refusal of one does not hide the others, and any
    /// error, not only the importer's own, is a refusal of that transfer rather than the end of the pass.
    public func importEach(identity: SigningIdentity?, options: ImportOptions = .default, skipping: Set<String> = [],
                           progress: (Progress) -> Void = { _ in }) throws -> Report {
        guard let identity else {
            throw NXPocketError(.noCertificate, "import a certificate before importing a game")
        }
        var report = Report()
        let folders = pending().filter { !skipping.contains($0.lastPathComponent) }
        for (index, folder) in folders.enumerated() {
            progress(Progress(stage: .verifying, fraction: Double(index) / Double(max(folders.count, 1)),
                              detail: folder.lastPathComponent))
            // Written before the import and removed after it, however it ends: what is left is an import the app did not survive.
            ImportGuard.begin(folder.lastPathComponent, in: documents)
            defer { ImportGuard.end(in: documents) }
            do {
                report.imported.append(try importer.install(folder, identity: identity, signer: signer,
                                                            options: options,
                                                            availableCapacity: VolumeSpace.available(documents: documents)))
            } catch {
                let refusal = (error as? NXPocketError)
                    ?? NXPocketError(.transferFailed, "\(folder.lastPathComponent): \(error.localizedDescription)")
                log?.append("import of \(folder.lastPathComponent) refused: \(refusal)")
                // A refusal about the certificate or the space leaves the folder for a retry once that is fixed. Any
                // other is about the package itself (a wrong hash, a damaged framework): importing it again would
                // fail the same way, so it is removed and the game has to be sent again.
                if !Self.keepsTheTransfer.contains(refusal.code), (try? fileManager.removeItem(at: folder)) != nil {
                    log?.append("removed the refused transfer \(folder.lastPathComponent): send the game again")
                }
                report.refused.append((folder.lastPathComponent, refusal))
                if refusal.code == .certificateExpired || refusal.code == .teamMismatch || refusal.code == .wrongSigner {
                    // The same certificate would refuse every other transfer the same way.
                    break
                }
            }
        }
        return report
    }

    /// Signs a game that is already installed again, after a certificate renewal.
    @discardableResult
    public func resign(_ game: InstalledGame, identity: SigningIdentity) throws -> SigningRecord {
        guard let framework = game.frameworkURL else {
            throw NXPocketError(.packageMissing, "\(game.directory.lastPathComponent) has no framework")
        }
        // As the importer refuses it: signing takes minutes and gives a framework the system will not load.
        guard !identity.isExpired else {
            throw NXPocketError(.certificateExpired,
                                "the certificate expired on \(identity.expires.formatted(date: .abbreviated, time: .omitted))")
        }
        let signature = try signer.sign(framework: framework, identity: identity)
        guard signature.hasCertificate, signature.identifier == identity.identifier else {
            throw NXPocketError(.wrongSigner, "the framework came back as \"\(signature.identifier)\"")
        }
        let record = SigningRecord(certificateSHA256: identity.certificateSHA256, identifier: identity.identifier,
                                   teamID: identity.teamID, subject: identity.subject,
                                   signedAt: Date(), expires: identity.expires, entitlements: identity.entitlementsTag)
        try GameLibrary.writeSigning(record, in: game.directory, fileManager: fileManager)
        log?.append("signed \(game.titleID) again for \(identity.teamID), with the \(identity.entitlementsTag ?? SigningRecord.defaultEntitlementsTag) entitlements")
        return record
    }

    public func gamesNeedingSignature(_ games: [InstalledGame], identity: SigningIdentity,
                                      now: Date = Date()) -> [InstalledGame] {
        games.filter { !$0.isBroken && $0.needsResign(against: identity, now: now) }
    }

    /// The refusals that say nothing against the package: importing it again can succeed once the user has acted.
    static let keepsTheTransfer: Set<NXPocketError.Code> = [
        .noCertificate, .certificateExpired, .teamMismatch, .wrongSigner, .signingFailed, .notEnoughSpace,
        .transferFailed, .cancelled,
    ]

    /// Transfers that will never finish (`GameImporter.cleanStaleIncoming`).
    @discardableResult
    public func cleanUnfinishedTransfers(now: Date = Date()) -> [URL] {
        importer.cleanStaleIncoming(now: now)
    }
}

/// Removes a game's files, keeping its saves unless asked otherwise.
public enum GameRemoval {
    /// Without `includingSaves`, everything but the `save*` entries goes from the game's folder, in place: the saves are
    /// never moved, so an interruption cannot leave them in a folder nothing looks at.
    public static func remove(_ game: InstalledGame, includingSaves: Bool, fileManager: FileManager = .default) throws {
        let directory = game.directory
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let names = try fileManager.contentsOfDirectory(atPath: directory.path)
        guard !includingSaves, names.contains(where: { $0.hasPrefix("save") }) else {
            try fileManager.removeItem(at: directory)
            return
        }
        for name in names where !name.hasPrefix("save") {
            try fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Everything under the `save*` entries of a game: a folder counts for what it holds, not for its own size.
    public static func saveBytes(of game: InstalledGame, fileManager: FileManager = .default) -> Int64 {
        let names = (try? fileManager.contentsOfDirectory(atPath: game.directory.path)) ?? []
        var total: Int64 = 0
        for name in names where name.hasPrefix("save") {
            let url = game.directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                total += Int64((try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0)
                continue
            }
            if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) {
                for case let child as URL in enumerator {
                    let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                    if values?.isDirectory == true { continue }
                    total += Int64(values?.fileSize ?? 0)
                }
            }
        }
        return total
    }
}
