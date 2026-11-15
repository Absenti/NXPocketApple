import NXShellUI
import SwiftUI
import UIKit

/// Settings › Updates: the installed version, the SideStore source, a check, and what an update must not do.
struct UpdatesCard: View {
    @EnvironmentObject private var model: ShellHostModel
    @ObservedObject var updates: UpdateChecker
    @State private var sideStoreMissing = false

    var body: some View {
        ShellCard {
            VStack(alignment: .leading, spacing: 10) {
                ShellSectionLabel(model.text(.updates))
                row(model.text(.installedVersion), updates.installed)
                row(model.text(.appIdentifierLabel), Bundle.main.bundleIdentifier ?? "unknown")
                status
                Button(model.text(.addToSideStore)) { addSource() }
                    .buttonStyle(ShellButtonStyle(prominent: true))
                if sideStoreMissing {
                    Text(model.text(.sideStoreDidNotOpen)).font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
                    Text(UpdateChannel.sourceURL.absoluteString).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(ShellInk.primary).textSelection(.enabled)
                    Button(model.text(.copyAddress)) { UIPasteboard.general.string = UpdateChannel.sourceURL.absoluteString }
                        .buttonStyle(ShellButtonStyle())
                }
                HStack(spacing: 8) {
                    Button(model.text(.checkUpdates)) { Task { await updates.check() } }
                        .buttonStyle(ShellButtonStyle())
                        .disabled(updates.state == .checking)
                    if case .done(.newer) = updates.state {
                        Button(model.text(.openSideStore)) { open(UpdateChannel.openSideStoreURL) }.buttonStyle(ShellButtonStyle())
                    }
                }
                Toggle(model.text(.checkDaily), isOn: $updates.automatic)
                    .font(.system(size: 13)).tint(ShellInk.accent)
                if let last = updates.lastCheck {
                    row(model.text(.lastCheck), last.formatted(date: .abbreviated, time: .shortened))
                }
                Text(model.text(.updateWarning)).font(.system(size: 12)).foregroundStyle(ShellInk.accent)
                Text(model.text(.updateSavesHint)).font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch updates.state {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                Text(model.text(.checking)).font(.system(size: 13)).foregroundStyle(ShellInk.secondary)
            }
        case .done(let outcome):
            Text(text(for: outcome)).font(.system(size: 13))
                .foregroundStyle(outcome.isNewer ? ShellInk.good : ShellInk.secondary)
        }
    }

    private func text(for outcome: UpdateChannel.Outcome) -> String {
        switch outcome {
        case .newer(let release): return ShellStrings.updateAvailable(release.version)
        case .upToDate(let release): return ShellStrings.upToDate(release.version)
        case .noPublicChannel: return model.text(.noPublicChannel)
        case .failed(let why): return model.labelled(.checkFailed, why)
        }
    }

    /// SideStore does not always act on the link it is opened with (it only comes to the front), so the address is copied first and
    /// shown: the one step left is a paste in its Sources screen.
    private func addSource() {
        UIPasteboard.general.string = UpdateChannel.sourceURL.absoluteString
        sideStoreMissing = true
        open(UpdateChannel.addSourceURL)
    }

    /// SideStore, or nothing when it is not installed or has another name (the address is on screen either way).
    private func open(_ url: URL) {
        Task { _ = await UIApplication.shared.open(url) }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 12)).foregroundStyle(ShellInk.primary)
                .multilineTextAlignment(.trailing).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// In the library, once a check found a newer version the player has not put off.
struct UpdateNotice: View {
    @EnvironmentObject private var model: ShellHostModel
    @ObservedObject var updates: UpdateChecker

    var body: some View {
        if let release = updates.newerRelease {
            NoticeCard(symbol: "arrow.down.app.fill", tint: ShellInk.good,
                       title: ShellStrings.updateAvailable(release.version),
                       detail: model.text(.updateThroughSideStore)) {
                Button(model.text(.openSideStore)) {
                    Task { await UIApplication.shared.open(UpdateChannel.openSideStoreURL) }
                }
                .buttonStyle(ShellButtonStyle(prominent: true))
                Button(model.text(.later)) { updates.dismiss(release) }.buttonStyle(ShellButtonStyle())
            }
        }
    }
}

extension UpdateChannel.Outcome {
    var isNewer: Bool {
        if case .newer = self { return true }
        return false
    }
}
