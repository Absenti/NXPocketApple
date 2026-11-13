import NXPocketKit
import NXShellUI
import SwiftUI

enum ShellTab: String, CaseIterable, Identifiable {
    case library, transfers, settings
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .library: return "square.grid.2x2"
        case .transfers: return "arrow.down.to.line"
        case .settings: return "slider.horizontal.3"
        }
    }
}

/// The shell: three tabs (the library, what is arriving from the Mac, the settings) under a floating bar.
public struct ShellRootView: View {
    @EnvironmentObject private var model: ShellHostModel
    @State private var tab: ShellTab = .library

    public init() {}

    public var body: some View {
        ZStack(alignment: .bottom) {
            ShellInk.background.ignoresSafeArea()
            StageGlow().ignoresSafeArea()
            switch tab {
            case .library: LibraryScreen(openSettings: { tab = .settings })
            case .transfers: TransfersScreen()
            case .settings: ShellSettingsView()
            }
            ShellTabBar(selection: $tab, transfers: model.receiving.count + model.pendingTransfers)
        }
        .preferredColorScheme(.dark)
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

/// The floating bar: a pill with one button per tab, the current one lit and named.
struct ShellTabBar: View {
    @EnvironmentObject private var model: ShellHostModel
    @Binding var selection: ShellTab
    let transfers: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ShellTab.allCases) { tab in
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { selection = tab }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: tab.symbol).font(.system(size: 17, weight: .semibold))
                        if selection == tab {
                            Text(label(tab)).font(ShellFont.body(13, .semibold)).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .foregroundStyle(selection == tab ? ShellInk.onDeep : ShellInk.primary.opacity(0.7))
                    .background(selection == tab ? ShellInk.primary : .clear, in: Capsule())
                    .overlay(alignment: .topTrailing) {
                        if tab == .transfers, transfers > 0, selection != tab {
                            Text("\(transfers)").font(.system(size: 10, weight: .heavy)).foregroundStyle(ShellInk.onDeep)
                                .frame(minWidth: 16, minHeight: 16).padding(.horizontal, 2)
                                .background(ShellInk.deep, in: Capsule()).offset(x: -10, y: 6)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label(tab))
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Color(red: 0.11, green: 0.11, blue: 0.14).opacity(0.7), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10)))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

    private func label(_ tab: ShellTab) -> String {
        switch tab {
        case .library: return model.text(.library)
        case .transfers: return model.text(.transfers)
        case .settings: return model.text(.settings)
        }
    }
}

/// What is arriving from the Mac and what waits to be imported: a game sent while the app is in front is imported as it
/// lands, so this is where its progress shows.
struct TransfersScreen: View {
    @EnvironmentObject private var model: ShellHostModel
    @State private var openedLog: LogFile?
    @State private var showingLog = false

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.text(.transfers)).font(ShellFont.display(32)).foregroundStyle(ShellInk.primary)
                        if let summary { Text(summary).font(.system(size: 12)).foregroundStyle(ShellInk.secondary) }
                    }
                    .padding(.top, 8)
                    ForEach(model.receiving) { ReceivingTransferCard(transfer: $0) }
                    ImportStateCard(openLog: { openedLog = $0; showingLog = true })
                    if model.pendingTransfers > 0 {
                        NoticeCard(symbol: "tray.and.arrow.down.fill", tint: ShellInk.accent,
                                   title: "\(model.pendingTransfers) · \(model.text(.waiting))",
                                   detail: model.certificate == nil ? model.text(.gameWaitsForCertificate) : nil) {
                            Button(model.text(.importGame)) { model.importPendingTransfers() }
                                .buttonStyle(ShellButtonStyle(prominent: true))
                                .disabled(model.certificate == nil || model.importState.isRunning)
                        }
                    }
                    if model.receiving.isEmpty, model.pendingTransfers == 0, !model.importState.isRunning {
                        emptyState
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 110)
            }
        }
        .sheet(isPresented: $showingLog) {
            LogsView(open: openedLog).environmentObject(model).presentationBackground(ShellInk.background)
        }
    }

    /// How many are on their way; nothing while there are none (the empty state says what this screen is for).
    private var summary: String? {
        let count = model.receiving.count + model.pendingTransfers
        return count == 0 ? nil : "\(count) · \(model.text(.receiving).lowercased())"
    }

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
