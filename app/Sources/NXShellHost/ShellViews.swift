import NXPocketKit
import NXShellUI
import SwiftUI

public struct ShellSettingsView: View {
    @EnvironmentObject private var model: ShellHostModel
    @Environment(\.dismiss) private var dismiss

    @State private var importingP12 = false
    @State private var passphrase = ""
    @State private var pendingData: Data?
    @State private var error: String?
    @State private var showingLogs = false

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack {
                ShellInk.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        certificateCard
                        TouchControlsCard()
                        memoryCard
                        transfersCard
                        logsCard
                        UpdatesCard(updates: model.updates)
                        aboutCard
                        Spacer(minLength: 0)
                    }
                    .padding(20)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(model.text(.done)) { dismiss() } }
            }
            .navigationTitle(model.text(.settings))
            .sheet(isPresented: $showingLogs) {
                LogsView().environmentObject(model).presentationBackground(ShellInk.background)
            }
            .fileImporter(isPresented: $importingP12, allowedContentTypes: [.data]) { result in
                switch result {
                case .success(let url):
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    // A .p12 is a few kilobytes; anything picked by mistake is refused, not read whole.
                    pendingData = BoundedRead.dataIfPresent(at: url, limit: 1 << 20)
                    passphrase = ""
                case .failure(let failure):
                    error = failure.localizedDescription
                }
            }
            .alert(model.text(.certificatePassphrase), isPresented: Binding(get: { pendingData != nil },
                                                                           set: { if !$0 { pendingData = nil } })) {
                SecureField("••••••", text: $passphrase)
                Button(model.text(.cancel), role: .cancel) { pendingData = nil }
                Button(model.text(.certificateImport)) { importP12() }
            } message: {
                Text(model.text(.p12PasswordHint))
            }
        }
    }

    private var certificateCard: some View {
        ShellCard {
            VStack(alignment: .leading, spacing: 10) {
                ShellSectionLabel(model.text(.certificate))
                if let certificate = model.certificate {
                    row(model.text(.certificateSubject), certificate.subject)
                    row(model.text(.certificateTeam), certificate.teamID)
                    row(model.text(.certificateExpires), certificate.expires.formatted(date: .abbreviated, time: .shortened))
                    row(model.text(.daysLeft), "\(certificate.daysLeft)")
                    row(model.text(.signingIdentifier), model.appIdentifier)
                    if let inProfile = model.certificateInAppProfile {
                        row(model.text(.certificateInProfile), inProfile ? model.text(.yes) : model.text(.no))
                        if !inProfile {
                            Text(model.text(.certificateNotInProfile)).font(.system(size: 12)).foregroundStyle(ShellInk.bad)
                        }
                    }
                    if !model.certificateTeamMatchesApp {
                        Text(model.text(.certificateWrongTeam)).font(.system(size: 12)).foregroundStyle(ShellInk.bad)
                    }
                } else if let problem = model.certificateProblem {
                    Text(model.labelled(.certificateUnreadable, problem)).font(.system(size: 13)).foregroundStyle(ShellInk.bad)
                    CopyReportButton(error: model.labelled(.certificateUnreadable, problem), appLog: true)
                } else {
                    Text(model.text(.certificateNone)).font(.system(size: 13)).foregroundStyle(ShellInk.bad)
                }
                Text(model.text(.certificateBody)).font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
                HStack(spacing: 10) {
                    Button(model.certificate == nil ? model.text(.certificateImport) : model.text(.certificateReplace)) {
                        importingP12 = true
                    }
                    .buttonStyle(ShellButtonStyle(prominent: model.certificate == nil))
                    if model.certificate != nil {
                        Button(model.text(.certificateRemove)) { model.removeCertificate() }.buttonStyle(ShellButtonStyle())
                    }
                }
                if let error {
                    Text(error).font(.system(size: 12)).foregroundStyle(ShellInk.bad).textSelection(.enabled)
                    CopyReportButton(error: error, appLog: true)
                }
            }
        }
    }

    private var memoryCard: some View {
        ShellCard {
            VStack(alignment: .leading, spacing: 10) {
                ShellSectionLabel(model.text(.memory))
                ShellPill(MemoryBudget.hasIncreasedLimit ? model.text(.memoryActive) : model.text(.memoryInactive),
                          color: MemoryBudget.hasIncreasedLimit ? ShellInk.good : ShellInk.secondary)
                row(model.text(.availableNow), MemoryBudget.availableText)
                row(model.text(.deviceMemory), MemoryBudget.physicalText)
                row(model.text(.gamesOnDisk), model.totalText)
                row(model.text(.freeSpace), model.freeText)
                Text(model.text(.memoryBody)).font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
            }
        }
    }

    private var transfersCard: some View {
        ShellCard {
            VStack(alignment: .leading, spacing: 10) {
                ShellSectionLabel(model.text(.transfers))
                row(model.text(.waiting), "\(model.pendingTransfers)")
                HStack(spacing: 10) {
                    Button(model.text(.resignAll)) { model.resignAll() }
                        .buttonStyle(ShellButtonStyle())
                        .disabled(model.signingIdentity == nil)
                    Button(model.text(.importGame)) { model.importPendingTransfers() }
                        .buttonStyle(ShellButtonStyle())
                        .disabled(model.pendingTransfers == 0)
                }
            }
        }
    }

    private var logsCard: some View {
        ShellCard {
            VStack(alignment: .leading, spacing: 10) {
                ShellSectionLabel(model.text(.logs))
                Text(model.text(.logsBody)).font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
                Button(model.text(.logs)) { showingLogs = true }.buttonStyle(ShellButtonStyle())
            }
        }
    }

    private var aboutCard: some View {
        ShellCard {
            VStack(alignment: .leading, spacing: 10) {
                ShellSectionLabel(model.text(.about)
                )
                row(model.text(.appLabel), Bundle.main.bundleIdentifier ?? "dev.nxpocket.app")
                row(model.text(.signatureLabel), AppSignature.description)
                row(model.text(.installedBy), ProvisioningProfile.teamID() ?? model.text(.unknownTeam))
                row(model.text(.engineHost), model.engineHost.isAvailable
                    ? "\(model.text(.engineInEachGame)) (glue v\(FrameworkEngineHost.glueVersion))" : model.text(.noEngineInBuild))
                // Where Files shows the app's folder, not the sandbox path with its UUID.
                row(model.text(.folderLabel), model.text(.folderInFiles))
                Text(model.text(.noKeysNotice))
                    .font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
                Text(model.text(.networkNotice))
                    .font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 12)).foregroundStyle(ShellInk.primary)
                .multilineTextAlignment(.trailing).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)   // wraps rather than cutting a long value short
        }
    }

    private func importP12() {
        defer { pendingData = nil }
        guard let data = pendingData else { return }
        do {
            try model.importCertificate(p12: data, passphrase: passphrase)
            error = nil
        } catch let failure as NXPocketError {
            error = failure.detail
        } catch {
            self.error = error.localizedDescription
        }
    }
}
