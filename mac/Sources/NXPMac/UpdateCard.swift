import SwiftUI
import NXPMacKit
import NXPMacModel

/// The offer of a new release. It opens by itself when the look at launch finds one (never from a button), and says
/// what is new; the download, its checks and the swap start only on "Update and restart".
struct UpdateSheet: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.update {
            case .available(let release):
                available(release)
            case .downloading(let release, let fraction):
                progress(release, fraction)
            case .restarting:
                message("Installed", "The launcher quits and the new one opens.")
            case .failed(let reason):
                message("The update did not install", reason, bad: true)
            default:
                message("Up to date", "There is nothing to install.")
            }
        }
        .frame(width: 500)
        .background(Ink.surface)
    }

    private func header(_ title: String, _ detail: String) -> some View {
        HStack(spacing: 16) {
            PocketMark(size: 64).shadow(color: Ink.accent.opacity(0.16), radius: 14)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 21, weight: .heavy)).tracking(-0.6).foregroundStyle(Ink.primary)
                Text(detail).font(.system(size: 13)).foregroundStyle(Ink.secondary)
            }
        }
    }

    private func available(_ release: LauncherRelease) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                header("A new version is ready",
                       "NXPocketApple \(release.version.description) · you have \(model.runningVersion?.description ?? "a development build")")
                if !release.notes.isEmpty {
                    ScrollView {
                        Text(release.notes).font(.system(size: 12.5)).foregroundStyle(Ink.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                    .frame(maxHeight: 150)
                    .padding(12)
                    .background(Ink.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.line))
                }
                Text(model.updateRefusal
                     ?? "The download is checked before it is installed, and the app reopens by itself. Your settings and library stay.")
                    .font(.system(size: 12)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 22)

            HStack(spacing: 10) {
                Text("Looked for at launch, once a day").font(.system(size: 12)).foregroundStyle(Ink.secondary)
                Spacer()
                Button("Later") { model.showUpdateSheet = false }
                    .buttonStyle(QuietButtonStyle(large: true)).keyboardShortcut(.cancelAction)
                if model.updateRefusal != nil {
                    Button("Open the release page") { model.openReleasePage(release) }
                        .buttonStyle(PrimaryButtonStyle(large: true)).keyboardShortcut(.defaultAction)
                } else {
                    Button("Update and restart") { model.installUpdate(release) }
                        .buttonStyle(PrimaryButtonStyle(large: true)).keyboardShortcut(.defaultAction)
                        .disabled(model.queueHasWork)
                        .help(model.queueHasWork ? "The queue is working: update once it is done." : "")
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 14)
            .background(Ink.background.opacity(0.5))
            .overlay(alignment: .top) { Divider().overlay(Ink.line) }
        }
    }

    private func progress(_ release: LauncherRelease, _ fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Downloading", "NXPocketApple \(release.version.description)")
            if let fraction { Bar(fraction: fraction) } else { ProgressView().progressViewStyle(.linear) }
            Text("The download is checked, then the launcher quits and the new one opens.")
                .font(.system(size: 12)).foregroundStyle(Ink.secondary)
        }
        .padding(28)
    }

    private func message(_ title: String, _ detail: String, bad: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header(title, bad ? "" : detail)
            if bad { Text(Friendly.text(detail)).font(.system(size: 12)).foregroundStyle(Ink.bad).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Close") { model.showUpdateSheet = false }.buttonStyle(QuietButtonStyle(large: true)).keyboardShortcut(.cancelAction)
            }
        }
        .padding(28)
    }
}
