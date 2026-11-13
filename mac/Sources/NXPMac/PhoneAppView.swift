import AppKit
import SwiftUI
import NXPMacKit
import NXPMacModel

/// The iPhone app: its IPA, how to install and update it with SideStore, and turning on the larger memory limit.
/// Built from rows, like Settings.
///
/// SideStore's labels below were read in its source at the commit installed on the test iPhone (0.7.0 nightly,
/// 6032424a, 2026-09-11): the "My Apps" and "Settings" tabs, the "+" button of My Apps (a document picker), "Refresh
/// All", "ADVANCED SETTINGS" → "Certificate Management", the certificate's menu "Export Certificate" → "Export Full
/// (.p12)", then "Export". NXPocketApple's own are from app/Sources/NXShellUI/ShellStrings.swift.
struct PhoneAppView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmingMemory = false
    @State private var showSource = false

    var body: some View {
        RowsPage {
            PageTitle(title: "iPhone app", subtitle: "Install it once with SideStore or any other signing store. After that, games reach it from this Mac.")
        } content: {
            installGroup
            stepsGroup
            memoryGroup
            // Building the IPA needs the project's source folder: only a copy of the repository has it.
            if model.repository != nil { sourceSection }
        }
        .onAppear {
            model.refreshPhoneApp()
            model.watchCloudCopy()
            if model.installation == nil { model.findInstallation() }
        }
    }

    // MARK: - Getting the app

    /// What anyone with only this app needs: the project's SideStore source, or the IPA of the latest release.
    private var sourceLink: String { "https://github.com/\(LauncherUpdate.repository)/releases/latest/download/source.json" }

    private var latestIPARelease: LauncherRelease? {
        model.latestRelease.flatMap { PhoneAppDownload.hasIPA($0) ? $0 : nil }
    }

    private var downloadNeeded: Bool {
        model.latestRelease.map { PhoneAppDownload.needsDownload(have: model.phoneIPA, release: $0) } ?? false
    }

    /// The iPhone app, here on this Mac: kept in step with the latest GitHub release, ready to go to the phone.
    private var installGroup: some View {
        SettingsGroup(title: "NXPocketApple for iPhone") {
            versionRow
            downloadStatus
            if let ipa = model.phoneIPA {
                SettingRow(symbol: "icloud.and.arrow.up", title: cloudTitle(ipa), detail: cloudDetail(ipa),
                           detailColor: cloudColor(ipa), detailLines: 3) {
                    Button("Save a copy…") { model.saveIPACopy() }.buttonStyle(QuietButtonStyle(large: true))
                    Button("Copy to iCloud Drive") { model.copyIPAToiCloud() }
                        .buttonStyle(PrimaryButtonStyle(large: true))
                        .disabled(model.cloudCopy == .copying || model.iCloudDrive == nil)
                }
            }
            SettingRow(symbol: "link", title: "SideStore source",
                       detail: "Or add the project's source in SideStore: it installs and updates the app by itself.", detailLines: 2) {
                Button("Copy link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sourceLink, forType: .string)
                }
                .buttonStyle(QuietButtonStyle(large: true))
            }
        }
    }

    @ViewBuilder
    private var versionRow: some View {
        if let ipa = model.phoneIPA {
            SettingRow(symbol: "iphone", title: "NXPocketApple \(ipa.versionText)",
                       detail: "downloaded \(ipa.date.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: ipa.bytes, countStyle: .file))\(versionNote)",
                       detailColor: downloadNeeded || model.ipaIsStale ? Ink.accent : Ink.secondary, detailLines: 2) {
                if downloadNeeded, let release = latestIPARelease, !model.ipaDownload.isRunning {
                    Button("Update") { model.downloadPhoneApp(release) }.buttonStyle(PrimaryButtonStyle(large: true))
                }
                Button("Show in Finder") { model.revealInFinder(ipa.url) }.buttonStyle(QuietButtonStyle(large: true))
            }
        } else {
            SettingRow(symbol: "iphone", title: "Not downloaded yet", detail: emptyDetail, detailLines: 2) {
                if let release = latestIPARelease, !model.ipaDownload.isRunning {
                    Button("Download") { model.downloadPhoneApp(release) }.buttonStyle(PrimaryButtonStyle(large: true))
                }
            }
        }
    }

    private var versionNote: String {
        if downloadNeeded, let release = latestIPARelease { return " · version \(release.version) is out" }
        if model.ipaIsStale { return " · the sources changed since: build it again" }
        return model.latestRelease != nil ? " · up to date" : ""
    }

    private var emptyDetail: String {
        if let release = model.latestRelease {
            return PhoneAppDownload.hasIPA(release) ? "Version \(release.version) is on GitHub." : "The latest release has no iPhone app yet."
        }
        switch model.update {
        case .checking: return "Looking at GitHub…"
        case .noChannel: return "No release is published yet."
        case .failed(let reason): return Friendly.text(reason)
        default: return "It is fetched from GitHub when the app starts."
        }
    }

    @ViewBuilder
    private var downloadStatus: some View {
        switch model.ipaDownload {
        case .idle:
            EmptyView()
        case .running(let fraction, let detail):
            VStack(alignment: .leading, spacing: 6) {
                if let fraction { Bar(fraction: fraction) } else { ProgressView().progressViewStyle(.linear) }
                Text(detail).font(.system(size: 12)).foregroundStyle(Ink.secondary)
            }
            .padding(16).overlay(alignment: .top) { Divider().overlay(Ink.line) }
        case .finished(let message):
            note(message, Ink.good)
        case .failed(let message):
            note(message, Ink.bad)
        }
    }

    /// For someone working from a copy of the repository: building the IPA themselves.
    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showSource.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showSource ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold))
                    Text("Build the IPA yourself").font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(Ink.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.horizontal, 4)
            if showSource { sourceGroup }
        }
    }

    // MARK: - The IPA

    private var sourceGroup: some View {
        SettingsGroup(title: "Build from the source") { buildRow }
    }

    private func cloudTitle(_ ipa: PhoneAppIPA) -> String {
        switch model.cloudCopy {
        case .none: return "iCloud Drive"
        case .copying: return "Copying…"
        case .uploading: return "Uploading to iCloud…"
        case .inCloud(let date): return date < ipa.date.addingTimeInterval(-1) ? "An older copy is in iCloud" : "In iCloud Drive"
        case .failed: return "The copy failed"
        }
    }

    /// Where the copy in iCloud Drive → Downloads stands: the iPhone sees it once it is in iCloud.
    private func cloudDetail(_ ipa: PhoneAppIPA) -> String {
        switch model.cloudCopy {
        case .none:
            return model.iCloudDrive == nil
                ? "iCloud Drive is off on this Mac: turn it on, or save a copy where the iPhone's Files app sees it."
                : "Goes to iCloud Drive → Downloads, where SideStore's + finds it."
        case .copying: return "Copying to iCloud Drive…"
        case .uploading: return "The iPhone sees it once the upload is done."
        case .inCloud(let date):
            return date < ipa.date.addingTimeInterval(-1) ? "iCloud Drive → Downloads has an older NXPocketApple.ipa: copy this one again."
                                                           : "iCloud Drive → Downloads: ready for SideStore on the iPhone."
        case .failed(let reason): return reason
        }
    }

    private func cloudColor(_ ipa: PhoneAppIPA) -> Color {
        switch model.cloudCopy {
        case .failed: return Ink.bad
        case .inCloud(let date): return date < ipa.date.addingTimeInterval(-1) ? Ink.accent : Ink.good
        default: return Ink.secondary
        }
    }

    /// The signing engine (libnxzsign, OpenSSL) is a build product of tools/build_zsign.sh, never committed: until it is
    /// built, the iPhone app cannot be.
    private var signingEngineMissing: Bool {
        model.appBuildBlockers.contains { $0.contains("xcframework") }
    }

    private var buildDetail: String {
        if signingEngineMissing { return "The signing engine is not built yet. Copy the command, run it once in Terminal (a few minutes), then come back." }
        if model.appBuildBlockers.isEmpty { return "A few minutes. SideStore signs it when it installs it." }
        return "Missing: \(model.appBuildBlockers.map(Friendly.text).joined(separator: ", "))."
    }

    @ViewBuilder
    private var buildRow: some View {
        SettingRow(symbol: "hammer", title: "Build the latest iPhone app", detail: buildDetail,
                   detailColor: model.appBuildBlockers.isEmpty ? Ink.secondary : (signingEngineMissing ? Ink.accent : Ink.bad),
                   detailLines: 3) {
            if model.appBuild.isRunning {
                Button("Cancel") { model.cancelPhoneAppBuild() }.buttonStyle(QuietButtonStyle(large: true))
            } else if signingEngineMissing, let repository = model.repository {
                Button("Copy command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("cd '\(repository.path)' && tools/build_zsign.sh", forType: .string)
                }
                .buttonStyle(PrimaryButtonStyle(large: true))
            } else {
                Button("Build") { model.buildPhoneApp() }.buttonStyle(QuietButtonStyle(large: true))
                    .disabled(!model.appBuildBlockers.isEmpty)
            }
        }
        switch model.appBuild {
        case .idle:
            EmptyView()
        case .running(let fraction, let detail):
            VStack(alignment: .leading, spacing: 6) {
                Bar(fraction: fraction ?? 0)
                Text(Friendly.text(detail)).font(.system(size: 12)).foregroundStyle(Ink.secondary).lineLimit(1).truncationMode(.middle)
            }
            .padding(16).overlay(alignment: .top) { Divider().overlay(Ink.line) }
        case .finished(let message):
            note(message, Ink.good)
        case .failed(let message):
            note(message, Ink.bad)
        }
    }

    private func note(_ text: String, _ color: Color) -> some View {
        Text(Friendly.text(text)).font(.system(size: 12.5)).foregroundStyle(color).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Divider().overlay(Ink.line) }
    }

    // MARK: - Installing

    private var stepsGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsGroup(title: "After installing") {
                step(1, "Open NXPocketApple once. It makes its folders, and this Mac can then send it games.")
                step(2, "Get the .p12 of the certificate that signed the app: it is the one your store installed it with. In SideStore: Settings → ADVANCED SETTINGS → Certificate Management, touch and hold the active certificate, Export Certificate → Export Full (.p12), set a password, Export, and save the file to Files. With another store (FlareStore, …), use the .p12 and the password it gave you for that certificate.")
                step(3, "In NXPocketApple: Settings → Certificate → Import a .p12, then type the password. NXPocketApple signs each game on the iPhone with it, so the certificate must belong to the same team as the one that installed the app.")
                step(4, "A free Apple ID signs apps for 7 days: before they run out, refresh the app in your store (SideStore → My Apps → Refresh All). If NXPocketApple then says its certificate changed, import the new .p12.")
            }
            warning("Update NXPocketApple through the store that installed it, never by opening an IPA in the Files app: that installs a second copy that cannot run games. Keep the same app ID, and never delete NXPocketApple first: its games and saves go with it.")
        }
    }

    private func warning(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Ink.bad)
            Text(text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Ink.bad).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.bad.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)").font(.system(size: 13, weight: .heavy)).foregroundStyle(Ink.accent)
                .frame(width: 28, height: 28).background(Ink.raised, in: Circle())
            Text(text).font(.system(size: 13.5)).foregroundStyle(Ink.primary).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .overlay(alignment: .top) { Divider().overlay(Ink.line) }
    }

    // MARK: - Increased Memory Limit

    private var memoryGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsGroup(title: "More memory for games") {
                installationRow
                SettingRow(symbol: "memorychip", title: "Increased Memory Limit",
                           detail: memoryDetail, detailLines: 3) {
                    if case .running = model.memoryHelper { ProgressView().controlSize(.small) }
                    if teamTarget != nil {
                        Button("Turn on…") { confirmingMemory = true }
                            .buttonStyle(PrimaryButtonStyle(large: true))
                            .disabled(model.memoryHelper.isRunning)
                    }
                }
                memoryResult
            }
            HelpText(title: "How it works", text: """
                iOS gives more memory to an app whose App ID has "Increased Memory Limit". With SideStore or AltStore the App ID is \
                yours: a free Apple ID cannot turn the capability on in a web page, but Xcode does it when it signs an app with \
                that entitlement. This builds a one-off helper app with NXPocketApple's App ID, signed by Xcode with your team: \
                nothing is installed, and only the App ID changes at Apple. Any other store signs with its own App ID, which \
                this Mac cannot change: NXPocketApple → Settings → Memory on the iPhone says whether the limit is active.
                """)
        }
        .confirmationDialog("Turn on Increased Memory Limit for this App ID?", isPresented: $confirmingMemory, titleVisibility: .visible) {
            if let target = teamTarget {
                Button("Turn it on") { model.enableMemoryLimit(target) }
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            if let target = teamTarget {
                Text("Xcode signs a helper app as \(target.bundleID) with team \(target.team) and is allowed to update its provisioning at Apple (-allowProvisioningUpdates). That adds the capability to the App ID SideStore registered for NXPocketApple. If Xcode has no development certificate for this Apple ID on this Mac yet, it makes one. Nothing is installed on the iPhone.")
            }
        }
    }

    /// The team-signed App ID the helper can change, when the app was installed by SideStore or AltStore.
    private var teamTarget: MemoryLimitHelper.Target? {
        if case .success(.teamSigned(let target)) = model.installation { return target }
        return nil
    }

    private var memoryDetail: String {
        switch model.installation {
        case .success(.other):
            return "Set by your store, which signs with its own App ID. Check NXPocketApple → Settings → Memory on the iPhone."
        default:
            return "Games need more memory than an app gets by default."
        }
    }

    @ViewBuilder
    private var installationRow: some View {
        switch model.installation {
        case .none:
            SettingRow(symbol: "iphone", title: "Looking for the app…", detail: "On the iPhone.") { ProgressView().controlSize(.small) }
        case .failure(let error):
            SettingRow(symbol: "exclamationmark.triangle", tint: Ink.bad, title: "App not found on the iPhone", detail: error.detail,
                       detailColor: Ink.bad, detailLines: 3) {
                Button("Try again") { model.findInstallation() }.buttonStyle(QuietButtonStyle(large: true))
            }
        case .success(.other(let bundleID)):
            SettingRow(symbol: "checkmark.seal", title: "Installed by another store or tool",
                       detail: "\(bundleID) is installed as is, without a team after it, as FlareStore, Sideloadly or Xcode do. Games work all the same: import the .p12 of the certificate that signed the app.",
                       detailLines: 3) {
                Pill(text: "Ready", color: Ink.good)
            }
        case .success(.teamSigned(let target)):
            SettingRow(symbol: "person.badge.key", title: "App ID",
                       detail: model.xcodeHasTeam(target.team) ? "Found on the iPhone, and Xcode is signed in with its team."
                           : "Xcode is not signed in with this app's team: add the Apple ID SideStore uses in Xcode → Settings → Accounts first.",
                       detailColor: model.xcodeHasTeam(target.team) ? Ink.secondary : Ink.bad,
                       detailLines: 3) {
                if model.xcodeHasTeam(target.team) { Pill(text: "Xcode signed in", color: Ink.good) }
            }
        }
    }

    @ViewBuilder
    private var memoryResult: some View {
        switch model.memoryHelper {
        case .running(_, let detail):
            note(detail, Ink.secondary)
        case .finished(let message):
            VStack(spacing: 0) {
                note(message, Ink.good)
                step(1, "In SideStore → My Apps, tap Refresh All, or install the IPA again over NXPocketApple: the new signature carries the entitlement.")
                step(2, "In NXPocketApple → Settings → Memory, check that it says \"Increased memory limit is active\".")
            }
        case .failed(let message):
            note(message, Ink.bad)
        default:
            EmptyView()
        }
    }
}
