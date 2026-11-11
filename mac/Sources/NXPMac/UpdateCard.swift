import SwiftUI
import NXPMacKit
import NXPMacModel

/// The launcher's own version, the look for a new release, its notes, and the update once the user says so.
struct UpdateCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionHeading(text: "Updates")
                    Text(model.runningVersion.map { "iPorterNX \($0.description)" } ?? "development build")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.secondary)
                    Spacer()
                    Button("Check for updates") { model.checkForUpdates() }
                        .buttonStyle(.bordered)
                        .disabled(model.update == .checking || isDownloading)
                }
                Toggle("Look for a new release at launch, at most once a day", isOn: Binding(
                    get: { model.settings.value.checkUpdates },
                    set: { model.settings.value.checkUpdates = $0 }))
                    .toggleStyle(.switch)
                state
            }
        }
    }

    private var isDownloading: Bool {
        if case .downloading = model.update { return true }
        return false
    }

    @ViewBuilder
    private var state: some View {
        switch model.update {
        case .idle:
            Text("Releases come from github.com/\(LauncherUpdate.repository). The check sends nothing about you.")
                .font(.system(size: 11)).foregroundStyle(Ink.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Looking at GitHub…").font(.system(size: 11)).foregroundStyle(Ink.secondary)
            }
        case .upToDate(let text):
            Text(text).font(.system(size: 11)).foregroundStyle(Ink.good)
        case .noChannel:
            Text("No public release channel yet: the project's releases are not published. The launcher looks again tomorrow, or with the button.")
                .font(.system(size: 11)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
        case .available(let release):
            available(release)
        case .downloading(let release, let fraction):
            VStack(alignment: .leading, spacing: 4) {
                if let fraction { Bar(fraction: fraction) } else { ProgressView().progressViewStyle(.linear) }
                Text("Downloading and checking iPorterNX \(release.version.description)…").font(.system(size: 11)).foregroundStyle(Ink.secondary)
            }
        case .restarting:
            Text("Installed: the launcher quits and the new one opens.").font(.system(size: 11)).foregroundStyle(Ink.good)
        case .failed(let reason):
            Text(reason).font(.system(size: 11)).foregroundStyle(Ink.bad).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func available(_ release: LauncherRelease) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(release.title) · version \(release.version.description)")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.primary)
            if !release.notes.isEmpty {
                ScrollView {
                    Text(release.notes).font(.system(size: 11)).foregroundStyle(Ink.primary)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(maxHeight: 180)
                .padding(8)
                .background(Ink.raised, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            if let refusal = model.updateRefusal {
                Text(refusal).font(.system(size: 11)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open the release page") { model.openReleasePage(release) }.buttonStyle(.bordered)
            } else {
                Text("The download is checked against the release's SHA256SUMS, then this app goes to the Trash and the new one takes its place once the launcher has quit.")
                    .font(.system(size: 11)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Update and restart") { model.installUpdate(release) }
                        .buttonStyle(.borderedProminent).tint(Ink.accent).foregroundStyle(.black)
                        .disabled(model.queueHasWork)
                    Button("Release page") { model.openReleasePage(release) }.buttonStyle(.plain).foregroundStyle(Ink.accent)
                }
            }
        }
    }
}
