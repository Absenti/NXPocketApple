import NXPocketKit
import NXShellUI
import SwiftUI
import UIKit

/// What the library says above the games, only while it matters: a launch that failed, a game on its way from the Mac,
/// an import, a missing certificate, games to sign again. Each card says what to do in one button.
struct LibraryNotices: View {
    @EnvironmentObject private var model: ShellHostModel
    let openSettings: () -> Void
    /// A log to open, or nil for the list.
    let openLog: (LogFile?) -> Void
    /// The covers screen has no room for the two big cards (import the certificate, sign the games again): its header has
    /// a pill for each instead, and this leaves them out.
    var compact = false

    var body: some View {
        VStack(spacing: 10) {
            launchCard
            failedLaunch
            UpdateNotice(updates: model.updates)
            ForEach(model.sources.buildsOff) { record in
                NoticeCard(symbol: "hammer.fill", tint: ShellInk.accent, title: model.text(.buildsOffTitle), detail: String(format: model.text(.buildsOffBody), record.name)) {
                    Button(model.text(.close)) { model.sources.hushBuildsOff(record) }.buttonStyle(ShellButtonStyle())
                }
            }
            ForEach(model.receiving) { ReceivingTransferCard(transfer: $0) }
            ImportStateCard(openLog: openLog)
            if model.certificate == nil, !compact {
                NoticeCard(symbol: "key.fill", tint: ShellInk.accent, title: model.text(.certificateNeededTitle),
                           detail: model.text(model.pendingTransfers > 0 ? .gameWaitsForCertificate : .certificateNeededBody)) {
                    Button(model.text(.settings), action: openSettings).buttonStyle(ShellButtonStyle(prominent: true))
                }
            } else if !model.importState.isRunning, toSign > 0, !compact {
                NoticeCard(symbol: "signature", tint: ShellInk.accent,
                           title: "\(ShellStrings.gameCount(toSign)) \(model.text(.toSignAgain))",
                           detail: model.text(.signAgainBody)) {
                    Button(model.text(.sign)) { model.resignAll() }.buttonStyle(ShellButtonStyle(prominent: true))
                }
            }
        }
    }

    private var toSign: Int { model.gamesNeedingSignature().count }

    @ViewBuilder
    private var failedLaunch: some View {
        if let marker = model.failedLaunch {
            let game = model.games.first { $0.titleID.description == marker.titleID.description }
            NoticeCard(game: game, symbol: "exclamationmark.triangle.fill", tint: ShellInk.bad,
                       title: model.text(.lastLaunchFailed),
                       detail: "\(model.title(ofTitleID: marker.titleID)) · \(marker.startedAt.formatted(date: .abbreviated, time: .shortened))") {
                if let log = model.failedLaunchLog {
                    Button(model.text(.log)) { openLog(log) }.buttonStyle(ShellButtonStyle(prominent: true))
                }
                CopyReportButton(error: model.text(.lastLaunchFailed), titleID: marker.titleID)
                Button(model.text(.close)) { model.clearFailedLaunch() }.buttonStyle(ShellButtonStyle())
            }
        }
    }

    /// A start asked from a game's menu: signing it first can take minutes, and a refusal must show where it was asked.
    @ViewBuilder
    private var launchCard: some View {
        switch model.launch {
        case .launching(let what):
            NoticeCard(symbol: "play.circle.fill", tint: ShellInk.accent, title: model.text(.starting), detail: what) { EmptyView() }
        case .failed(let message):
            NoticeCard(symbol: "exclamationmark.triangle.fill", tint: ShellInk.bad, title: model.text(.gameDidNotStart),
                       detail: message) {
                CopyReportButton(error: message, titleID: model.activeTitleID)
                Button(model.text(.close)) { model.launch = .idle }.buttonStyle(ShellButtonStyle())
            }
        case .idle, .running:
            EmptyView()
        }
    }
}

/// A game on its way from the Mac: its name, how much has landed, and a bar.
struct ReceivingTransferCard: View {
    @EnvironmentObject private var model: ShellHostModel
    let transfer: IncomingTransfer

    var body: some View {
        let received = ByteCountFormatter.string(fromByteCount: transfer.received, countStyle: .file)
        let detail = transfer.expected.map {
            "\(received) \(model.text(.sizeOf)) \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))"
        } ?? "\(received) \(model.text(.received))"
        NoticeCard(symbol: transfer.stalled ? "pause.circle.fill" : "arrow.down.circle.fill", tint: transfer.stalled ? ShellInk.secondary : ShellInk.accent,
                   title: "\(model.text(transfer.stalled ? .receivingStopped : .receiving)) · \(transfer.title ?? model.text(.aGame))",
                   detail: transfer.stalled ? "\(detail)\n\(model.text(.receivingStoppedBody))" : detail,
                   progress: transfer.fraction ?? 0) {
            // Offered only once nothing has come for a while: deleting what the Mac is still sending would only be sent again.
            if transfer.stalled {
                Button(model.text(.deleteTransfer)) { model.discardTransfer(transfer.id) }.buttonStyle(ShellButtonStyle(prominent: true))
            }
        }
    }
}

/// An import under way, or the one that failed and what to do about it.
struct ImportStateCard: View {
    @EnvironmentObject private var model: ShellHostModel
    /// A log to open, or nil for the list.
    let openLog: (LogFile?) -> Void

    var body: some View {
        switch model.importState {
        case .running(let stage, let fraction, let detail):
            NoticeCard(symbol: "square.and.arrow.down.fill", tint: ShellInk.accent, title: model.text(.importing),
                       detail: detail.isEmpty ? stage : "\(stage) · \(detail)", progress: fraction) { EmptyView() }
        case .failed(let message):
            NoticeCard(symbol: "exclamationmark.triangle.fill", tint: ShellInk.bad, title: model.text(.importFailed),
                       detail: message) {
                if model.pendingTransfers > 0, model.certificate != nil {
                    Button(model.text(.tryAgainImport)) { model.importPendingTransfers() }.buttonStyle(ShellButtonStyle(prominent: true))
                }
                Button(model.text(.log)) { openLog(GameLogs.appLog(documents: model.documents)) }.buttonStyle(ShellButtonStyle())
                CopyReportButton(error: message, appLog: true)
                Button(model.text(.close)) { model.importState = .idle }.buttonStyle(ShellButtonStyle())
            }
        case .idle, .finished:
            EmptyView()
        }
    }
}

/// One card of the library's notices: an icon (or the game's), a line, a detail, an optional bar and its buttons.
struct NoticeCard<Actions: View>: View {
    var game: InstalledGame?
    let symbol: String
    let tint: Color
    let title: String
    let detail: String?
    var progress: Double?
    @ViewBuilder var actions: Actions

    var body: some View {
        ShellCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    if let game {
                        GameIcon(game: game, cornerRadius: 8).frame(width: 38, height: 38)
                    } else {
                        // Decoration: the title says what the card is, and VoiceOver would read the symbol's own name.
                        Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(tint)
                            .frame(width: 38, height: 38)
                            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(ShellInk.primary)
                            .lineLimit(2)
                        if let detail {
                            Text(detail).font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
                                .lineLimit(3).truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if let progress { ShellBar(fraction: progress) }
                if Actions.self != EmptyView.self {
                    // On one line when they fit, else one under the other.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { actions }
                        VStack(alignment: .leading, spacing: 8) { actions }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// "Copy the report" under a state that went wrong: the report (`ShellHostModel.report`) goes to the pasteboard, and the
/// button says so for two seconds.
struct CopyReportButton: View {
    @EnvironmentObject private var model: ShellHostModel
    let error: String
    var titleID: String?
    var appLog = false
    @State private var copied = false

    var body: some View {
        Button(copied ? model.text(.reportCopied) : model.text(.copyReport)) {
            UIPasteboard.general.string = model.report(error: error, titleID: titleID, appLog: appLog)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        }
        .buttonStyle(ShellButtonStyle())
    }
}
