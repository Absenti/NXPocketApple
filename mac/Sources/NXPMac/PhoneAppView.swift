import SwiftUI
import NXPMacKit
import NXPMacModel

/// The iPhone app: its IPA, how to install and update it with SideStore, and turning on the larger memory limit.
///
/// SideStore's labels below were read in its source at the commit installed on the test iPhone (0.7.0 nightly,
/// 6032424a, 2026-09-11): the "My Apps" and "Settings" tabs, the "+" button of My Apps (a document picker), "Refresh
/// All", "ADVANCED SETTINGS" → "Certificate Management", the certificate's menu "Export Certificate" → "Export Full
/// (.p12)", then "Export". NXPocket's own are from app/Sources/NXShellUI/ShellStrings.swift.
struct PhoneAppView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmingMemory = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("iPhone app").font(.system(size: 22, weight: .semibold)).foregroundStyle(Ink.primary)
                ipaCard
                stepsCard
                memoryCard
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            model.refreshPhoneApp()
            model.watchCloudCopy()
            if model.memoryTarget == nil { model.findMemoryTarget() }
        }
    }

    // MARK: - The IPA

    private var ipaCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(text: "NXPocket.ipa")
                if let ipa = model.phoneIPA {
                    HStack(spacing: 8) {
                        Pill(text: ipa.versionText)
                        Pill(text: ByteCountFormatter.string(fromByteCount: ipa.bytes, countStyle: .file))
                        Text("built \(ipa.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                    }
                    if model.ipaIsStale, let source = model.newestAppSource {
                        Text("The app's sources changed after this IPA was built (\(source.formatted(date: .abbreviated, time: .shortened))): build it again to get the latest.")
                            .font(.system(size: 11)).foregroundStyle(Ink.accent)
                    } else if model.newestAppSource != nil {
                        Text("Up to date with the app's sources.").font(.system(size: 11)).foregroundStyle(Ink.good)
                    }
                    HStack(spacing: 10) {
                        Button { model.copyIPAToiCloud() } label: { Label("Copy to iCloud Drive", systemImage: "icloud.and.arrow.up") }
                            .buttonStyle(.borderedProminent).tint(Ink.accent).foregroundStyle(.black)
                            .disabled(model.cloudCopy == .copying || model.iCloudDrive == nil)
                        Button("Save a copy…") { model.saveIPACopy() }.buttonStyle(.bordered)
                        Button("Show in Finder") { model.revealInFinder(ipa.url) }.buttonStyle(.bordered)
                    }
                    cloudLine(ipa)
                } else {
                    Text("No IPA yet in \(model.settings.value.outputURL.path).").font(.system(size: 12)).foregroundStyle(Ink.secondary)
                }
                Divider().overlay(Ink.line)
                buildRow
            }
        }
    }

    /// Where the copy in iCloud Drive → Downloads stands: the iPhone sees it once it is in iCloud.
    @ViewBuilder
    private func cloudLine(_ ipa: PhoneAppIPA) -> some View {
        switch model.cloudCopy {
        case .none:
            Text(model.iCloudDrive == nil ? "iCloud Drive is off on this Mac: turn it on, or save a copy where the iPhone's Files app sees it."
                 : "Copy to iCloud Drive puts it in iCloud Drive → Downloads, where SideStore's + finds it.")
                .font(.system(size: 11)).foregroundStyle(Ink.secondary)
        case .copying:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Copying to iCloud Drive…").font(.system(size: 11)).foregroundStyle(Ink.secondary) }
        case .uploading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Uploading to iCloud: the iPhone sees it once this is done.").font(.system(size: 11)).foregroundStyle(Ink.secondary)
            }
        case .inCloud(let date):
            if date < ipa.date.addingTimeInterval(-1) {
                Text("iCloud Drive → Downloads has an older NXPocket.ipa: copy this one again.").font(.system(size: 11)).foregroundStyle(Ink.accent)
            } else {
                Text("In iCloud Drive → Downloads: ready for SideStore on the iPhone.").font(.system(size: 11)).foregroundStyle(Ink.good)
            }
        case .failed(let reason):
            Text(reason).font(.system(size: 11)).foregroundStyle(Ink.bad).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var buildRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if model.appBuild.isRunning {
                    Button("Cancel") { model.cancelPhoneAppBuild() }.buttonStyle(.bordered)
                } else {
                    Button { model.buildPhoneApp() } label: { Label("Build the latest iPhone app", systemImage: "hammer") }
                        .buttonStyle(.bordered)
                        .disabled(!model.appBuildBlockers.isEmpty)
                }
                Text("tools/build_app.sh --device-unsigned, a few minutes. SideStore signs it when it installs it.")
                    .font(.system(size: 11)).foregroundStyle(Ink.secondary)
            }
            if !model.appBuildBlockers.isEmpty {
                Text("Missing: \(model.appBuildBlockers.joined(separator: ", ")).").font(.system(size: 11)).foregroundStyle(Ink.bad)
            }
            switch model.appBuild {
            case .idle:
                EmptyView()
            case .running(let fraction, let detail):
                Bar(fraction: fraction ?? 0)
                Text(detail).font(.system(size: 11)).foregroundStyle(Ink.secondary)
            case .finished(let message):
                Text(message).font(.system(size: 11)).foregroundStyle(Ink.good)
            case .failed(let message):
                Text(message).font(.system(size: 11)).foregroundStyle(Ink.bad).textSelection(.enabled)
            }
        }
    }

    // MARK: - Installing

    private var stepsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(text: "Install it with SideStore")
                step(1, "Copy to iCloud Drive, and wait until it says the IPA is in iCloud.")
                step(2, "In SideStore, open My Apps, tap + at the top, and in the file picker open iCloud Drive → Downloads → NXPocket.ipa.")
                warning("Never tap NXPocket.ipa in the Files app itself: that installs a second NXPocket beside the real one, which cannot run games. Always go through SideStore's +.")
                step(3, "An update goes the same way, over the installed app: its games and saves stay (checked on the iPhone on 11/11). Never delete NXPocket first: deleting an app deletes its data with it, every game sent to it (gigabytes to send again) and every save.")
                step(4, "Open NXPocket once. It makes its folders, and this Mac can then send it games.")
                step(5, "Export the certificate: SideStore → Settings → ADVANCED SETTINGS → Certificate Management, touch and hold the active certificate, Export Certificate → Export Full (.p12), set a password, Export, and save the file to Files.")
                step(6, "In NXPocket: Settings → Certificate → Import a .p12 (Réglages → Certificat → Importer un .p12), then type the password. NXPocket signs each game with it.")
                step(7, "A free Apple ID signs apps for 7 days. Before they run out, open SideStore → My Apps → Refresh All. If NXPocket then says SideStore signs it with another certificate, export and import the .p12 again.")
            }
        }
    }

    private func warning(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Ink.bad).frame(width: 16, alignment: .trailing)
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.bad).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.accent).frame(width: 16, alignment: .trailing)
            Text(text).font(.system(size: 12)).foregroundStyle(Ink.primary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Increased Memory Limit

    private var memoryCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(text: "Unlock the RAM")
                Text("""
                Games need more memory than an app gets by default. iOS gives more to an app whose App ID has \
                "Increased Memory Limit". A free Apple ID cannot turn it on in a web page, but Xcode does it when it \
                signs an app with that entitlement. This builds a one-off helper app with NXPocket's App ID, signed by \
                Xcode with your team: nothing is installed, and only the App ID changes at Apple.
                """)
                .font(.system(size: 12)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                targetRow
                memoryAction
                memoryResult
            }
        }
        .confirmationDialog("Turn on Increased Memory Limit for this App ID?", isPresented: $confirmingMemory, titleVisibility: .visible) {
            if case .success(let target) = model.memoryTarget {
                Button("Turn it on") { model.enableMemoryLimit(target) }
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            if case .success(let target) = model.memoryTarget {
                Text("Xcode signs a helper app as \(target.bundleID) with team \(target.team) and is allowed to update its provisioning at Apple (-allowProvisioningUpdates). That adds the capability to the App ID SideStore registered for NXPocket. If Xcode has no development certificate for this Apple ID on this Mac yet, it makes one. Nothing is installed on the iPhone.")
            }
        }
    }

    @ViewBuilder
    private var targetRow: some View {
        switch model.memoryTarget {
        case .none:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading NXPocket's App ID from the iPhone…").font(.system(size: 11)).foregroundStyle(Ink.secondary) }
        case .failure(let error):
            HStack(spacing: 8) {
                Text(error.detail).font(.system(size: 11)).foregroundStyle(Ink.bad)
                Button("Try again") { model.findMemoryTarget() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Ink.accent)
            }
        case .success(let target):
            VStack(alignment: .leading, spacing: 4) {
                Text("App ID \(target.bundleID) · team \(target.team)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.primary)
                if model.xcodeHasTeam(target.team) {
                    Text("Xcode is signed in with this team.").font(.system(size: 11)).foregroundStyle(Ink.good)
                } else {
                    Text("Xcode is not signed in with this team: add the Apple ID SideStore uses in Xcode → Settings → Accounts first.")
                        .font(.system(size: 11)).foregroundStyle(Ink.bad)
                }
            }
        }
    }

    private var memoryAction: some View {
        HStack(spacing: 10) {
            Button("Turn on Increased Memory Limit…") { confirmingMemory = true }
                .buttonStyle(.bordered)
                .disabled(model.memoryHelper.isRunning || !isTargetReady)
            if case .running(_, let detail) = model.memoryHelper {
                ProgressView().controlSize(.small)
                Text(detail).font(.system(size: 11)).foregroundStyle(Ink.secondary)
            }
        }
    }

    private var isTargetReady: Bool {
        if case .success = model.memoryTarget { return true }
        return false
    }

    @ViewBuilder
    private var memoryResult: some View {
        switch model.memoryHelper {
        case .finished(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message).font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.good)
                step(1, "In SideStore → My Apps, tap Refresh All, or install the IPA again over NXPocket: the new signature carries the entitlement.")
                step(2, "In NXPocket → Settings → Memory (Réglages → Mémoire), check that it says \"Increased memory limit is active\" (\"La limite de mémoire augmentée est active\").")
            }
        case .failed(let message):
            Text(message).font(.system(size: 11)).foregroundStyle(Ink.bad).textSelection(.enabled)
        default:
            EmptyView()
        }
    }
}
