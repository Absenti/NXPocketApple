import NXPocketKit
import NXShellUI
import SwiftUI

public struct ShellSettingsView: View {
    @EnvironmentObject private var model: ShellHostModel
    @State private var importingP12 = false
    @State private var passphrase = ""
    @State private var pendingData: Data?
    @State private var error: String?
    @State private var showingLogs = false

    private enum Page: Hashable { case touch, memory, signing, updates, about }

    public init() {}

    public var body: some View {
        NavigationStack {
            root
                .containerBackground(.clear, for: .navigation)
                .navigationDestination(for: Page.self) { page in detail(page) }
                .toolbar(.hidden, for: .navigationBar)
        }
        .tint(ShellInk.accent)
    }

    /// The settings as the design has them: the certificate in a card of its own, then one short list, a row for each part
    /// that opens its own screen.
    private var root: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(model.text(.settings)).font(ShellFont.display(32))
                        .foregroundStyle(ShellInk.primary).padding(.top, 8)
                    certificateCard
                    VStack(spacing: 0) {
                        link(.touch, dot: Color(red: 0.95, green: 0.72, blue: 0.40), model.text(.touchControls), model.text(.arrangeControls))
                        link(.memory, dot: Color(red: 0.50, green: 0.83, blue: 0.60), model.text(.memory),
                             MemoryBudget.hasIncreasedLimit ? model.text(.memoryActive) : model.text(.memoryInactive))
                        link(.signing, dot: Color(red: 0.95, green: 0.55, blue: 0.52), model.text(.resignAll),
                             model.pendingTransfers > 0 ? "\(model.pendingTransfers)" : "")
                        Button { showingLogs = true } label: {
                            listRow(dot: Color(red: 0.54, green: 0.66, blue: 0.95), model.text(.logs), "", last: false)
                        }
                        .buttonStyle(.plain)
                        link(.updates, dot: Color(red: 0.50, green: 0.83, blue: 0.60), model.text(.updates), updatesValue)
                        link(.about, dot: Color(red: 0.78, green: 0.60, blue: 0.95), model.text(.about), "", last: true)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 4)
                    .background(ShellInk.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
                    Text(model.text(.noKeysNotice)).font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
                        .lineSpacing(2).padding(.horizontal, 4)
                }
                .padding(20)
                .padding(.bottom, 96)
            }
        }
        .sheet(isPresented: $showingLogs) {
            LogsView().environmentObject(model).presentationBackground(ShellInk.background)
        }
        .sheet(isPresented: $importingP12) {
            DocumentPicker(onPick: { url in
                importingP12 = false
                readP12(at: url)
            }, onCancel: { importingP12 = false })
            .ignoresSafeArea()
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

    private var updatesValue: String {
        if case .done(.newer(let release)) = model.updates.state { return release.version }
        return ""
    }

    private func link(_ page: Page, dot: Color, _ title: String, _ value: String, last: Bool = false) -> some View {
        NavigationLink(value: page) { listRow(dot: dot, title, value, last: last) }.buttonStyle(.plain)
    }

    /// A dot in the part's own colour, its name, a short word on where it stands, and a chevron.
    private func listRow(dot: Color, _ title: String, _ value: String, last: Bool) -> some View {
        HStack(spacing: 12) {
            Circle().fill(dot).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(title).font(.system(size: 15)).foregroundStyle(ShellInk.primary).lineLimit(1).layoutPriority(1)
            Spacer(minLength: 8)
            if !value.isEmpty {
                Text(value).font(.system(size: 12)).foregroundStyle(ShellInk.secondary).lineLimit(1).truncationMode(.tail)
            }
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white.opacity(0.35))
                .accessibilityHidden(true)
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { if !last { Divider().overlay(Color.white.opacity(0.07)) } }
    }

    @ViewBuilder
    private func detail(_ page: Page) -> some View {
        ZStack {
            ShellInk.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch page {
                    case .touch: TouchControlsCard()
                    case .memory: memoryCard
                    case .signing: transfersCard
                    case .updates: UpdatesCard(updates: model.updates)
                    case .about: aboutCard
                    }
                }
                .padding(20)
                .padding(.bottom, 96)
            }
        }
        .navigationTitle(title(of: page))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private func title(of page: Page) -> String {
        switch page {
        case .touch: return model.text(.touchControls)
        case .memory: return model.text(.memory)
        case .signing: return model.text(.resignAll)
        case .updates: return model.text(.updates)
        case .about: return model.text(.about)
        }
    }

    /// Reads the picked file (a copy the picker made) and deletes the copy at once: it holds a private key.
    private func readP12(at url: URL) {
        // A .p12 is a few kilobytes; anything picked by mistake is refused, not read whole.
        let data = BoundedRead.dataIfPresent(at: url, limit: 1 << 20)
        try? FileManager.default.removeItem(at: url)
        guard let data else {
            error = model.labelled(.certificateUnreadable, "the file is not a .p12 (too large, or not readable)")
            return
        }
        error = nil
        // The password alert waits for the picker to be gone: an alert asked for while a sheet closes is dropped.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            passphrase = ""
            pendingData = data
        }
    }

    private var certificateCard: some View {
        let has = model.certificate != nil
        return VStack(alignment: .leading, spacing: 10) {
            Text(model.text(.certificate).uppercased()).font(.system(size: 12, weight: .semibold)).tracking(1.2)
                .foregroundStyle(Color.white.opacity(0.65))
            if let certificate = model.certificate {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(certificate.daysLeft)").font(ShellFont.display(40))
                        .foregroundStyle(certificate.daysLeft > 1 ? ShellInk.good : ShellInk.bad)
                    Text(model.text(.daysLeft)).font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.7))
                }
                Text("\(certificate.subject) · \(certificate.teamID)").font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.6)).lineLimit(2)
                row(model.text(.certificateExpires), certificate.expires.formatted(date: .abbreviated, time: .shortened))
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
                if model.installIsForDistribution {
                    Text(model.text(.distributionInstallWarning)).font(.system(size: 12)).foregroundStyle(ShellInk.bad)
                }
                HStack(spacing: 10) {
                    Button(model.text(.certificateReplace)) { importingP12 = true }.buttonStyle(ShellButtonStyle())
                    Button(model.text(.certificateRemove)) { model.removeCertificate() }.buttonStyle(ShellButtonStyle())
                }
                .padding(.top, 4)
            } else {
                if let problem = model.certificateProblem {
                    Text(model.labelled(.certificateUnreadable, problem)).font(.system(size: 14)).foregroundStyle(ShellInk.bad)
                    CopyReportButton(error: model.labelled(.certificateUnreadable, problem), appLog: true)
                } else {
                    Text(model.text(.certificateNone)).font(.system(size: 20, weight: .bold)).foregroundStyle(Color(red: 0.95, green: 0.55, blue: 0.52))
                }
                Text(model.text(.certificateBody)).font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.6)).lineSpacing(2)
                Button(model.text(.certificateImport)) { importingP12 = true }
                    .buttonStyle(ShellButtonStyle(prominent: true))
                    .padding(.top, 4)
            }
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(ShellInk.bad).textSelection(.enabled)
                CopyReportButton(error: error, appLog: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [has ? Color(red: 0.09, green: 0.19, blue: 0.12) : Color(red: 0.21, green: 0.10, blue: 0.10), ShellInk.surface],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
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
                row(model.text(.appLabel), Bundle.main.bundleIdentifier ?? "dev.nxpocketapple.app")
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
