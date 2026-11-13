import Foundation
import NXPocketKit

/// When iOS refuses a game's code: trying the other entitlements, and saying why in words a person can act on.
extension ShellHostModel {
    /// dyld refusing the game's executable, as opposed to the game failing after it loaded.
    nonisolated static func isCodeRefusal(_ error: Error) -> Bool {
        guard let error = error as? NXPocketError, error.code == .notSigned else { return false }
        return error.detail.hasPrefix("dlopen refused")
    }

    /// dyld refused with the *sandbox* message, not the code-signing one: the process's own sandbox policy denies mapping
    /// code from that path. How the game is signed cannot change it.
    nonisolated static func isSandboxDenial(_ error: Error) -> Bool {
        ((error as? NXPocketError)?.detail ?? "").contains("file system sandbox blocked mmap")
    }

    /// dyld's answer is a paragraph that repeats the same path six times; this is the part that names the cause.
    nonisolated static func shortReason(_ error: Error) -> String {
        let text = (error as? NXPocketError)?.detail ?? error.localizedDescription
        if text.contains("sandbox blocked mmap") { return "dlopen refused the game's executable: the file system sandbox blocked mmap()" }
        return text.count > 300 ? String(text.prefix(300)) + "…" : text
    }

    /// When the app's own signature and its profile hold different entitlements, a refused game is signed again with
    /// the ones it was not signed with, and handed to `retry` to be loaded once more (with the choice that was
    /// refused, so a second refusal can be recorded). Returns false, doing nothing, when there is nothing else to try.
    ///
    /// The profile's entitlements are the default because they are proven under SideStore; a store that signs with
    /// its own profile can leave the profile and the app's signature disagreeing, and then the app's own are the ones
    /// iOS compares a loaded image with. The choice that loads is kept for this installation (`SigningPreference`).
    @discardableResult
    func signWithOtherEntitlements(_ game: InstalledGame, after error: Error,
                                   then retry: @escaping (InstalledGame, EntitlementsChoice) -> Void) -> Bool {
        // A refusal by the sandbox is decided before any signature is looked at: signing again would cost minutes and
        // change nothing.
        guard !Self.isSandboxDenial(error) else {
            log.append("launch of \(game.titleID) refused by the sandbox, not by code signing: signing it again would change nothing")
            return false
        }
        guard let alternative = SigningPreference.currentAlternative, !importState.isRunning else { return false }
        let first = SigningPreference.current
        log.append("launch of \(game.titleID) refused: \(Self.shortReason(error))")
        log.append("signing \(game.titleID) again with the \(alternative.tag) entitlements instead of the \(first.tag) ones")
        SigningPreference.remember(alternative)
        guard let identity = signingIdentity else {
            SigningPreference.remember(first)
            return false
        }
        let resigning = "\(text(.resigning)) \(name(of: game))"
        if case .launching = launch { launch = .launching(resigning) }
        if loadTest.isRunning { loadTest = .running(resigning) }
        Task { [importer] in
            do {
                _ = try await Task.detached(priority: .userInitiated) { try importer.resign(game, identity: identity) }.value
            } catch {
                // The load that follows says whether the old signature still stands.
                self.log.append("signing \(game.titleID) again with the \(alternative.tag) entitlements failed: \(error)")
            }
            retry(self.current(game), first)
        }
        return true
    }

    /// What the app can tell about a refused game: the facts it can read from its own signature, its profile, the
    /// certificate and the game's signature, and the difference that stands out.
    func signingDiagnosis(for game: InstalledGame, plan: EngineLaunchPlan, sandboxDenial: Bool = false) -> SigningDiagnosis {
        let profile = ProvisioningProfile.dictionary()
        return SigningDiagnosis.make(
            appIdentifier: AppSignature.currentIdentifier, appTeam: AppSignature.currentTeam,
            appSigned: AppSignature.entitlements, profileTeams: profile?["TeamIdentifier"] as? [String] ?? [],
            profileCertificateHashes: ProvisioningProfile.certificateHashes(), certificateSHA256: certificate?.sha256,
            certificateTeam: certificate?.teamID, game: GameSignatureFacts.read(executable: plan.frameworkExecutable),
            profileKind: profile.map { ProvisioningProfile.kind(of: $0) },
            choice: EntitlementsChoice(rawValue: game.signing?.entitlements ?? SigningRecord.defaultEntitlementsTag),
            sandboxDenial: sandboxDenial)
    }

    /// The text for a game iOS refused: what to do first, then what was checked. The same facts go to the log, so a
    /// report from the phone says what the app saw instead of dyld's bare "sandbox blocked mmap()".
    func refusalMessage(for game: InstalledGame, plan: EngineLaunchPlan, error: Error) -> String {
        let diagnosis = signingDiagnosis(for: game, plan: plan, sandboxDenial: Self.isSandboxDenial(error))
        log.append("launch of \(game.titleID) failed: \(Self.shortReason(error))")
        for line in diagnosis.lines { log.append("signing: \(line)") }
        for line in SigningFacts.current.lines { log.append("signing: \(line)") }
        let head: String
        switch diagnosis.verdict {
        case .certificateNotInProfile, .teamMismatch: head = text(.loadRefusedCertificate)
        case .identifierMismatch, .applicationIdentifierMismatch, .entitlementsDiffer: head = text(.loadRefusedEntitlements)
        case .distributionProfile: head = text(.loadRefusedDistribution)
        case .sandboxDenied: head = text(.loadRefusedSandbox)
        case .nothingFound: head = text(.loadRefusedUnknown)
        }
        return ([head, Self.shortReason(error)] + diagnosis.lines).joined(separator: "\n")
    }
}
