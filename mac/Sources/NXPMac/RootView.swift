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
                case .server: ServerView()
                case .devices: DevicesView()
                case .phoneApp: PhoneAppView()
                case .settings: SettingsView()
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear { model.startDeviceWatch() }
        // A new release is offered once, when the launcher starts and finds one: never a button to go and look.
        .sheet(isPresented: $model.showUpdateSheet) { UpdateSheet() }
    }

    /// The screens in three groups: the games, the iPhone, this Mac.
    private var groups: [(title: String, screens: [AppModel.Screen])] {
        [("Games", [.library, .build, .server]), ("iPhone", [.devices, .phoneApp]), ("This Mac", [.setup, .settings])]
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                PocketMark(size: 36).shadow(color: Ink.accent.opacity(0.18), radius: 10)
                Text("NXPocketApple").font(.system(size: 16, weight: .heavy)).tracking(-0.3).foregroundStyle(Ink.primary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 6)

            ForEach(groups, id: \.title) { group in
                SectionHeading(text: group.title)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 6)
                ForEach(group.screens) { screen in
                    navRow(screen)
                }
            }

            Spacer()

            if !model.sharingTransfers.isEmpty {
                downloadsCard.padding(.horizontal, 12).padding(.top, 12)
            }
            if model.queueHasWork {
                queueCard.padding(12)
            }

            Color.clear.frame(height: 14)
        }
        .background(Ink.surface)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
    }

    private func navRow(_ screen: AppModel.Screen) -> some View {
        let selected = model.screen == screen
        return Button {
            model.screen = screen
        } label: {
            HStack(spacing: 11) {
                Image(systemName: screen.symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(Ink.accent).frame(width: 20)
                Text(screen.title)
                Spacer()
                if screen == .library, !model.games.isEmpty {
                    Text("\(model.games.count)").font(.system(size: 12)).foregroundStyle(Ink.secondary)
                }
                if screen == .setup, model.setupIncomplete {
                    Circle().fill(Ink.deep).frame(width: 9, height: 9)
                }
                if screen == .devices, model.selectedDevice != nil {
                    Circle().fill(Ink.good).frame(width: 8, height: 8)
                }
            }
            .font(.system(size: 14, weight: selected ? .bold : .semibold))
            .foregroundStyle(Ink.primary)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(selected ? Ink.tint : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Ink.accent.opacity(0.28) : .clear))
            // A plain button takes clicks only on what it draws: the whole row is the target.
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
    }

    /// The iPhones downloading from this Mac: one line and one bar each, on every screen.
    private var downloadsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("iPhone downloads").font(.system(size: 12, weight: .bold))
            ForEach(model.sharingTransfers) { transfer in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(transfer.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        Spacer()
                        Text("\(Int(transfer.fraction * 100))%").font(.system(size: 11)).foregroundStyle(Ink.secondary)
                    }
                    Bar(fraction: transfer.fraction, tint: Ink.good)
                    Text("to \(transfer.device) · \(ByteCountFormatter.string(fromByteCount: transfer.sent, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: transfer.total, countStyle: .file))")
                        .font(.system(size: 10.5)).foregroundStyle(Ink.secondary).lineLimit(1)
                }
            }
        }
        .padding(12)
        .background(Ink.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ink.line))
    }

    /// The running queue: a stitched card that opens the Build screen, where the queue lives.
    private var queueCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            let finished = model.queue.filter { $0.phase.isFinished }.count
            HStack {
                Text("Queue").font(.system(size: 12, weight: .bold))
                Spacer()
                Text("\(finished) of \(model.queue.count) done").font(.system(size: 11)).foregroundStyle(Ink.secondary)
                if let item = model.activeItem, item.canPause {
                    Button { model.togglePause(item.id) } label: {
                        Image(systemName: item.isPaused ? "play.circle.fill" : "pause.circle.fill")
                            .font(.system(size: 14)).foregroundStyle(item.isPaused ? Ink.accent : Ink.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(item.isPaused ? "Resume the build" : "Pause the build: nothing is lost")
                    .accessibilityLabel(item.isPaused ? "Resume the build" : "Pause the build")
                }
                Button { model.cancelQueue() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(Ink.secondary)
                }
                .buttonStyle(.plain).help("Cancel the queue: the send under way is stopped")
                .accessibilityLabel("Cancel the queue")
            }
            Bar(fraction: model.queueFraction)
            if let item = model.activeItem {
                Text("\(item.name) · \(item.status)").font(.system(size: 11)).foregroundStyle(Ink.secondary).lineLimit(1)
                Bar(fraction: item.fraction, tint: item.sends && item.fraction >= (item.builds ? 0.75 : 0) ? Ink.good : Ink.deep)
            }
        }
        .padding(12)
        .background(Ink.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .stitched(radius: 14)
        .onTapGesture { model.screen = .build }
    }
}
