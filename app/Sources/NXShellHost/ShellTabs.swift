import NXPocketKit
import NXShellUI
import SwiftUI

enum ShellTab: String, CaseIterable, Identifiable {
    case library, activity, settings
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .library: return "square.grid.2x2"
        case .activity: return "arrow.down.to.line"
        case .settings: return "slider.horizontal.3"
        }
    }
}

/// The shell: three tabs (the library, the activity, the settings) under a floating bar.
public struct ShellRootView: View {
    @EnvironmentObject private var model: ShellHostModel
    @State private var tab: ShellTab = .library

    public init() {}

    public var body: some View {
        ZStack(alignment: .bottom) {
            ShellInk.background.ignoresSafeArea()
            StageGlow().ignoresSafeArea()
            switch tab {
            case .library: LibraryScreen(openSettings: { tab = .settings }, openActivity: { tab = .activity })
            case .activity: ActivityScreen(sources: model.sources)
            case .settings: ShellSettingsView()
            }
            ShellTabBar(selection: $tab, activity: model.receiving.count + model.pendingTransfers + model.sources.transfers.count
                        + model.sources.waiting.count)
        }
        .preferredColorScheme(.dark)
        // What arrives from outside is shown whatever tab is open: the Mac's QR code (opened with the Camera) and an archive sent here.
        .modifier(ArchiveRequestAlert())
        .sheet(item: $model.pairLink) { link in
            PairLinkSheet(sources: model.sources, link: link)
                .environmentObject(model)
                .presentationBackground(ShellInk.background)
                .preferredColorScheme(.dark)
        }
    }
}

/// The wash of the game in front's colour, behind every tab: the stage the screens sit on.
struct StageGlow: View {
    @EnvironmentObject private var model: ShellHostModel
    @AppStorage("libraryFocusID") private var focusID = ""

    var body: some View {
        let game = model.games.first { $0.id == focusID } ?? model.games.first
        let theme = game.map { ArtTheme.theme(for: $0) } ?? .standard
        RadialGradient(colors: [theme.glow.opacity(0.40), theme.glow.opacity(0.13), .clear],
                       center: UnitPoint(x: 0.5, y: 0.32), startRadius: 0, endRadius: 620)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.6), value: game?.id)
    }
}

/// The floating bar: a pill with one button per tab, an icon over its name, the current one lit. Every name is always shown, so none
/// has to fit in a shrinking label.
struct ShellTabBar: View {
    @EnvironmentObject private var model: ShellHostModel
    @Binding var selection: ShellTab
    let activity: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ShellTab.allCases) { tab in
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { selection = tab }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol).font(.system(size: 20, weight: .semibold))
                        Text(label(tab)).font(ShellFont.body(12, .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .foregroundStyle(selection == tab ? ShellInk.accent : ShellInk.primary.opacity(0.82))
                    .overlay(alignment: .top) {
                        if tab == .activity, activity > 0 {
                            Text("\(activity)").font(.system(size: 11, weight: .heavy)).foregroundStyle(ShellInk.onDeep)
                                .frame(minWidth: 16, minHeight: 16).padding(.horizontal, 2)
                                .background(ShellInk.accent, in: Capsule()).offset(x: 14, y: 2)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label(tab))
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        // Nearly opaque: a covers' glow or a cloud tile scrolling under a see-through bar made its labels unreadable.
        .background(Color(red: 0.09, green: 0.09, blue: 0.115).opacity(0.97), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

    private func label(_ tab: ShellTab) -> String {
        switch tab {
        case .library: return model.text(.library)
        case .activity: return model.text(.activity)
        case .settings: return model.text(.settings)
        }
    }
}

/// Everything that moves, in one place: downloads from the Mac and the servers, what the Mac is sending, the import under way, and
/// what waits for the player (a paused download, a transfer to import, one the app stopped in).
struct ActivityScreen: View {
    @EnvironmentObject private var model: ShellHostModel
    @ObservedObject var sources: NetworkSources
    @State private var openedLog: LogFile?
    @State private var showingLog = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.text(.activity)).font(ShellFont.display(28)).foregroundStyle(ShellInk.primary).padding(.top, 8)
                if !macBuilds.isEmpty {
                    ShellSectionLabel(model.text(.buildsOnMac))
                    ForEach(macBuilds) { entry in
                        let state = entry.build.state
                        NoticeCard(symbol: state == .failed ? "exclamationmark.triangle.fill" : "hammer.fill",
                                   tint: state == .failed ? ShellInk.bad : ShellInk.accent,
                                   title: entry.build.name,
                                   detail: buildDetail(entry),
                                   progress: state == .building ? entry.build.progress : nil) { EmptyView() }
                    }
                }
                if hasProgress {
                    ShellSectionLabel(model.text(.activityInProgress))
                    ForEach(sources.transfers) { NetworkTransferCard(sources: sources, transfer: $0) }
                    ForEach(model.receiving) { ReceivingTransferCard(transfer: $0) }
                    ImportStateCard(openLog: { openedLog = $0; showingLog = true })
                }
                if hasToHandle {
                    ShellSectionLabel(model.text(.activityToHandle)).padding(.top, 8)
                    ForEach(model.pendingList) { pending in
                        NoticeCard(symbol: pending.interrupted ? "exclamationmark.triangle.fill" : "tray.and.arrow.down.fill",
                                   tint: pending.interrupted ? ShellInk.bad : ShellInk.accent,
                                   title: pending.title ?? model.text(.aGame),
                                   detail: pending.interrupted ? model.text(.importInterrupted)
                                       : (model.certificate == nil ? model.text(.gameWaitsForCertificate) : model.sizeText(pending.bytes))) {
                            HStack(spacing: 10) {
                                Button(model.text(.importGame)) { model.importPendingTransfers() }
                                    .buttonStyle(ShellButtonStyle(prominent: true))
                                    .disabled(model.certificate == nil || model.importState.isRunning)
                                Button(model.text(.deleteTransfer)) { model.discardTransfer(pending.name) }
                                    .buttonStyle(ShellButtonStyle())
                                    .disabled(model.importState.isRunning)
                            }
                        }
                    }
                    ForEach(sources.waiting) { PausedDownloadCard(sources: sources, pending: $0) }
                }
                if !hasProgress, !hasToHandle, macBuilds.isEmpty { emptyState }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 110)
        }
        .onAppear { sources.refreshWaiting() }
        .sheet(isPresented: $showingLog) {
            LogsView(open: openedLog).environmentObject(model).presentationBackground(ShellInk.background)
        }
    }

    /// The builds the player asked this Mac for that are waiting, running or failed: nothing is shown for a game that only could be built.
    private var macBuilds: [NetworkSources.BuildEntry] {
        sources.buildable.filter { $0.build.state != .idle || sources.isBuildRequested($0) }
    }

    private func buildDetail(_ entry: NetworkSources.BuildEntry) -> String {
        switch entry.build.state {
        case .idle, .queued: return "\(model.text(.buildQueued)) · \(entry.record.name)"
        case .building: return "\(model.text(.buildBuilding)) · \(Int(entry.build.progress * 100)) % · \(entry.record.name)"
        case .failed: return entry.build.detail.isEmpty ? "\(model.text(.buildFailedOnMac)) · \(entry.record.name)" : entry.build.detail
        }
    }

    private var hasProgress: Bool { !sources.transfers.isEmpty || !model.receiving.isEmpty || model.importState.isRunning || importFailed }
    private var hasToHandle: Bool { !model.pendingList.isEmpty || !sources.waiting.isEmpty }
    private var importFailed: Bool { if case .failed = model.importState { return true }; return false }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.to.line").font(.system(size: 30, weight: .light)).foregroundStyle(ShellInk.secondary)
                .accessibilityHidden(true)
            Text(model.text(.transfersEmpty))
                .font(.system(size: 13)).foregroundStyle(ShellInk.secondary).multilineTextAlignment(.center).frame(maxWidth: 300)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .shellStitched(radius: 22)
        .padding(.top, 30)
    }
}

/// A download from a source, with its game's name, where from, and its controls.
struct NetworkTransferCard: View {
    @EnvironmentObject private var model: ShellHostModel
    @ObservedObject var sources: NetworkSources
    let transfer: NetworkSources.Transfer

    var body: some View {
        let record = sources.store.records.first { $0.id == transfer.recordID }
        ShellCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    if let record { SourceGameIcon(sources: sources, record: record, titleID: transfer.game.titleID) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(transfer.game.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(ShellInk.primary).lineLimit(1)
                        Text(record.map { "\(model.text(.downloadingNow)) · \($0.name)" } ?? model.text(.downloadingNow))
                            .font(.system(size: 12)).foregroundStyle(ShellInk.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                TransferControls(sources: sources, transfer: transfer)
            }
        }
    }
}
