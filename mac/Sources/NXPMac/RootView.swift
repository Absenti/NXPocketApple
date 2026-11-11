import SwiftUI
import NXPMacModel

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            ZStack {
                Ink.background.ignoresSafeArea()
                switch model.screen {
                case .setup: SetupView()
                case .library: LibraryView()
                case .build: BuildView()
                case .devices: DevicesView()
                case .phoneApp: PhoneAppView()
                case .settings: SettingsView()
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear { model.startDeviceWatch() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("iPorterNX").font(.system(size: 17, weight: .semibold)).foregroundStyle(Ink.primary)
                Text("Switch games on your iPhone").font(.system(size: 11)).foregroundStyle(Ink.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 14)

            ForEach(AppModel.Screen.allCases) { screen in
                Button {
                    model.screen = screen
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: screen.symbol).frame(width: 18)
                        Text(screen.title)
                        Spacer()
                        if screen == .library, !model.games.isEmpty { Text("\(model.games.count)").foregroundStyle(Ink.secondary) }
                        if screen == .setup, model.setupIncomplete {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Ink.accent)
                        }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(model.screen == screen ? Ink.primary : Ink.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(model.screen == screen ? Ink.raised : .clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    // A plain button takes clicks only on what it draws: the icon and the word, not the empty
                    // part of the row. The whole row is the target.
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
            }

            Spacer()

            if model.queueHasWork {
                VStack(alignment: .leading, spacing: 6) {
                    let finished = model.queue.filter { $0.phase.isFinished }.count
                    Text("Queue · \(finished) of \(model.queue.count) done").font(.system(size: 11)).foregroundStyle(Ink.secondary)
                    Bar(fraction: model.queueFraction)
                    if let item = model.activeItem {
                        Text("\(item.name) · \(item.status)").font(.system(size: 11)).foregroundStyle(Ink.secondary).lineLimit(1)
                        Bar(fraction: item.fraction, tint: item.sends && item.fraction >= (item.builds ? 0.75 : 0) ? Ink.good : Ink.accent)
                    }
                }
                .padding(12)
                .onTapGesture { model.screen = .build }
            }

            Text(model.engineReport)
                .font(.system(size: 10))
                .foregroundStyle(Ink.secondary)
                .lineLimit(2)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        }
        .background(Ink.surface)
        .navigationSplitViewColumnWidth(min: 200, ideal: 216, max: 260)
    }
}
