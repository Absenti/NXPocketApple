import NXPocketKit
import NXShellUI
import SwiftUI
import UIKit

/// The sources, in Settings: the Mac and the servers this iPhone downloads from, the switch that turns network sources on,
/// and the way to add one. Nobody visits a source: its games are in the library, as cloud tiles.
struct SourcesCard: View {
    @EnvironmentObject private var model: ShellHostModel
    @ObservedObject var sources: NetworkSources
    @State private var sheet: AddSourceSheet?
    @State private var adding = false
    @State private var forgetting: SourceRecord?

    enum AddSourceSheet: String, Identifiable {
        case discover, address, sftp, web
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ShellSectionLabel(model.text(.sourcesTab))
            if sources.enabled { list; backupStatus } else { off }
            if sources.enabled, sources.store.secretsInMemoryOnly {
                Text(model.text(.sourceSecretNotSaved)).font(.system(size: 12)).foregroundStyle(ShellInk.accent)
            }
        }
        .sheet(item: $sheet) { which in
            Group {
                switch which {
                case .discover: DiscoverySheet(sources: sources)
                case .address: PairSheet(sources: sources, address: "", contactOnAppear: false)
                case .sftp: SFTPSheet(sources: sources)
                case .web: WebSheet(sources: sources)
                }
            }
            .environmentObject(model)
            .presentationBackground(ShellInk.background)
            .preferredColorScheme(.dark)
        }
        .confirmationDialog(model.text(.addSource), isPresented: $adding, titleVisibility: .visible) {
            Button(model.text(.findMyMac)) { sheet = .discover }
            Button(model.text(.addMacByAddress)) { sheet = .address }
            Button(model.text(.addSFTPServer)) { sheet = .sftp }
            Button(model.text(.addWebLibrary)) { sheet = .web }
        }
        .confirmationDialog(model.text(.forgetSource), isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                            titleVisibility: .visible) {
            Button(model.text(.forgetSource), role: .destructive) { if let record = forgetting { sources.forget(record) }; forgetting = nil }
        }
    }

    private var off: some View {
        ShellCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.text(.sourcesOffTitle)).font(.system(size: 16, weight: .bold)).foregroundStyle(ShellInk.primary)
                Text(model.text(.sourcesOffBody)).font(.system(size: 12)).foregroundStyle(ShellInk.secondary).lineSpacing(1)
                Button(model.text(.sourcesTurnOn)) { sources.enabled = true }.buttonStyle(ShellButtonStyle(prominent: true))
            }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(sources.store.records) { record in
                row(record)
                Divider().overlay(ShellInk.line).padding(.horizontal, 16)
            }
            if sources.store.records.isEmpty {
                Text(model.text(.sourceSectionEmpty)).font(.system(size: 13)).foregroundStyle(ShellInk.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                Divider().overlay(ShellInk.line).padding(.horizontal, 16)
            }
            Button { adding = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus").font(.system(size: 16, weight: .semibold)).foregroundStyle(ShellInk.accent)
                    Text(model.text(.addSource)).font(.system(size: 14, weight: .medium)).foregroundStyle(ShellInk.accent)
                    Spacer()
                }
                .padding(.horizontal, 16).frame(height: 52).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider().overlay(ShellInk.line).padding(.horizontal, 16)
            Toggle(model.text(.sourcesOffTitle), isOn: $sources.enabled)
                .font(.system(size: 14)).tint(ShellInk.accent).padding(.horizontal, 16).frame(height: 52)
            Divider().overlay(ShellInk.line).padding(.horizontal, 16)
            option(.autoUpdateTitle, .autoUpdateBody, isOn: $sources.autoUpdate)
            Divider().overlay(ShellInk.line).padding(.horizontal, 16)
            option(.notifyTitle, .notifyBody, isOn: $sources.notifies)
            Divider().overlay(ShellInk.line).padding(.horizontal, 16)
            option(.autoBackupTitle, .autoBackupBody, isOn: $sources.autoBackupSaves)
            Divider().overlay(ShellInk.line).padding(.horizontal, 16)
            option(.syncTitle, .syncBody, isOn: $sources.syncSaves)
        }
        .background(ShellInk.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(ShellInk.line))
    }

    private func option(_ title: ShellStrings.Key, _ detail: ShellStrings.Key, isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(model.text(title), isOn: isOn).font(.system(size: 14)).tint(ShellInk.accent)
            Text(model.text(detail)).font(.system(size: 12)).foregroundStyle(ShellInk.secondary).lineSpacing(1)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    /// Where a backup of every game's saves stands: shown under the list until the player closes it.
    @ViewBuilder
    private var backupStatus: some View {
        if let message = model.backupMessage(sources.backup) {
            HStack(spacing: 10) {
                if case .running = sources.backup { ProgressView().tint(ShellInk.accent) }
                Text(message).font(.system(size: 12)).foregroundStyle(ShellInk.primary)
                Spacer(minLength: 0)
                if case .running = sources.backup {} else {
                    Button(model.text(.close)) { sources.dismissBackup() }.font(.system(size: 12, weight: .medium)).foregroundStyle(ShellInk.accent)
                }
            }
            .padding(12)
            .background(ShellInk.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func row(_ record: SourceRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: record.kind == .mac ? "laptopcomputer" : (record.kind == .web ? "globe" : "externaldrive.connected.to.line.below"))
                .font(.system(size: 17)).foregroundStyle(ShellInk.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name).font(.system(size: 14, weight: .medium)).foregroundStyle(ShellInk.primary).lineLimit(1)
                Text("\(model.text(record.kind == .mac ? .sourceKindMac : (record.kind == .web ? .sourceKindWeb : .sourceKindSFTP))) · \(record.host)")
                    .font(.system(size: 12)).foregroundStyle(ShellInk.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Menu {
                if sources.canKeepSaves(record) {
                    Button { model.backUpAllSaves(to: record) } label: { Label(model.text(.backUpAllSaves), systemImage: "icloud.and.arrow.up") }
                }
                Button(role: .destructive) { forgetting = record } label: { Label(model.text(.forgetSource), systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 16)).foregroundStyle(ShellInk.secondary)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel(model.text(.forgetSource))
        }
        .padding(.leading, 16).padding(.trailing, 4).frame(minHeight: 60)
    }
}

/// A download the app was closed in the middle of, or that the player paused: still in `.incoming`, and still resumable.
struct PausedDownloadCard: View {
    @EnvironmentObject private var model: ShellHostModel
    @ObservedObject var sources: NetworkSources
    let pending: PendingDownload

    var body: some View {
        let fraction = pending.bytesTotal > 0 ? min(1, Double(pending.bytesDone) / Double(pending.bytesTotal)) : 0
        NoticeCard(symbol: "pause.circle.fill", tint: ShellInk.accent,
                   title: "\(model.text(.pausedState)) · \(pending.name)",
                   detail: "\(model.sizeText(pending.bytesDone)) \(model.text(.sizeOf)) \(model.sizeText(pending.bytesTotal))",
                   progress: fraction) {
            HStack(spacing: 8) {
                if sources.canResume(pending) {
                    Button(model.text(.resumeAction)) { sources.resume(pending) }.buttonStyle(ShellButtonStyle(prominent: true))
                }
                Button(model.text(.cancel)) { sources.discard(pending) }.buttonStyle(ShellButtonStyle())
            }
        }
    }
}

struct TransferControls: View {
    @EnvironmentObject private var model: ShellHostModel
    @ObservedObject var sources: NetworkSources
    let transfer: NetworkSources.Transfer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch transfer.phase {
            case .queued:
                Text(sources.queuePosition(of: transfer.id).map { "\(model.text(.queuedPosition)) · \($0)" } ?? model.text(.waiting)).font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
            case .running, .paused:
                ShellBar(fraction: transfer.progress?.fraction ?? 0)
                Text(progressText).font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
            case .failed(let reason):
                Text(model.sourceMessage(reason)).font(.system(size: 12)).foregroundStyle(ShellInk.bad).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                switch transfer.phase {
                case .running, .queued:
                    Button(model.text(.pauseAction)) { sources.pause(transfer.id) }.buttonStyle(ShellButtonStyle())
                case .paused, .failed:
                    Button(model.text(.resumeAction)) { sources.resume(transfer.id) }.buttonStyle(ShellButtonStyle(prominent: true))
                }
                Button(model.text(.cancel)) { sources.cancel(transfer.id) }.buttonStyle(ShellButtonStyle())
            }
        }
    }

    private var progressText: String {
        guard let progress = transfer.progress else { return model.text(transfer.phase == .paused ? .pausedState : .downloadingNow) }
        var text = "\(model.sizeText(progress.bytesDone)) \(model.text(.sizeOf)) \(model.sizeText(progress.bytesTotal))"
        if transfer.phase == .running, transfer.bytesPerSecond > 0 {
            text += " · \(ByteCountFormatter.string(fromByteCount: Int64(transfer.bytesPerSecond), countStyle: .file))/s"
            if let left = transfer.secondsLeft { text += " · \(TransferSpeed.leftText(left))" }
        }
        return transfer.phase == .paused ? "\(model.text(.pausedState)) · \(text)" : text
    }
}

struct SourceGameIcon: View {
    @ObservedObject var sources: NetworkSources
    let record: SourceRecord
    let titleID: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "gamecontroller.fill").font(.system(size: 18)).foregroundStyle(ShellInk.secondary)
            }
        }
        .frame(width: 46, height: 46)
        .background(ShellInk.raised)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
        .task(id: titleID) { image = await sources.icon(for: titleID, in: record) }
    }
}
