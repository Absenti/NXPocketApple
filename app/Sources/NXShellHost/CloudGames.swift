import NXPocketKit
import NXShellUI
import SwiftUI
import UIKit

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, onPhone, cloud, updates
    var id: String { rawValue }
}

/// What the sources offer that the library shows as cloud tiles: one entry per game (from the first source that has it), only the
/// games this iPhone lacks or has in an older build.
@MainActor
enum CloudGames {
    struct Item: Identifiable {
        var entry: NetworkSources.CloudEntry
        var state: OfferState
        var id: String { entry.id }
    }

    static func items(sources: NetworkSources, games: [InstalledGame]) -> [Item] {
        guard sources.enabled else { return [] }
        var seen = Set<String>()
        return sources.offered.compactMap { entry in
            let installed = games.first { $0.titleID.description == entry.game.titleID }
            let state = LibraryStatus.state(of: entry.game, installed: installed)
            guard state.isDownloadable, state != .olderOnSource, seen.insert(entry.game.titleID).inserted else { return nil }
            return Item(entry: entry, state: state)
        }
    }
}

/// The games the player ticked to download together. Kept apart from the tiles, which are rebuilt whenever a source answers.
@MainActor
final class CloudSelection: ObservableObject {
    @Published var active = false
    @Published var ids: Set<String> = []

    func toggle(_ id: String) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    }

    func end() { active = false; ids = [] }
}

/// The bar of filters above the games: shown only when a source has something to offer.
struct LibraryFilterBar: View {
    @EnvironmentObject private var model: ShellHostModel
    @ObservedObject var sources: NetworkSources
    @ObservedObject var selection: CloudSelection
    @Binding var filter: LibraryFilter

    var body: some View {
        let items = CloudGames.items(sources: sources, games: model.games)
        if !items.isEmpty || !sources.buildable.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                filters(items)
                if selection.active { picking(items) }
            }
        }
    }

    private func filters(_ items: [CloudGames.Item]) -> some View {
        let updates = items.filter { $0.state == .updateAvailable }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibraryFilter.allCases) { option in
                    if option != .updates || items.contains(where: { $0.state == .updateAvailable }) {
                        Button { filter = option } label: {
                            Text(label(option)).font(ShellFont.body(13, filter == option ? .semibold : .regular)).lineLimit(1)
                                .padding(.horizontal, 14).frame(height: 32)
                                .background(filter == option ? ShellInk.primary : ShellInk.raised, in: Capsule())
                                .foregroundStyle(filter == option ? ShellInk.onDeep : ShellInk.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 8)
                if !updates.isEmpty, !selection.active {
                    chip(model.text(.updateAll) + " (\(updates.count))", prominent: true) { sources.updateAll() }
                }
                chip(selection.active ? model.text(.doneAction) : model.text(.selectAction), prominent: false) {
                    if selection.active { selection.end() } else { selection.active = true }
                }
            }
        }
    }

    /// What "Select" opens: every tile can be ticked, then one press queues them all, one after the other.
    private func picking(_ items: [CloudGames.Item]) -> some View {
        let wanted = items.filter { selection.ids.contains($0.id) }
        return HStack(spacing: 8) {
            chip(model.text(.downloadAll), prominent: false) {
                selection.ids = Set(items.filter { sources.transfer(forEntry: $0.entry) == nil }.map(\.id))
            }
            chip("\(model.text(.downloadSelected)) (\(wanted.count))", prominent: true) {
                for item in wanted { sources.download([item.entry.game], from: item.entry.record) }
                selection.end()
            }
            .disabled(wanted.isEmpty)
            .opacity(wanted.isEmpty ? 0.5 : 1)
            Spacer(minLength: 0)
        }
    }

    private func chip(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(ShellFont.body(13, prominent ? .semibold : .regular)).lineLimit(1)
                .padding(.horizontal, 14).frame(height: 32)
                .background(prominent ? ShellInk.accent : ShellInk.raised, in: Capsule())
                .foregroundStyle(prominent ? ShellInk.onDeep : ShellInk.secondary)
        }
        .buttonStyle(.plain)
    }

    private func label(_ option: LibraryFilter) -> String {
        switch option {
        case .all: return model.text(.filterAll)
        case .onPhone: return model.text(.filterOnPhone)
        case .cloud: return model.text(.filterCloud)
        case .updates: return model.text(.filterUpdates)
        }
    }
}

/// One line above the games while something is downloading: how many, how far, and a way to the Activity tab.
struct DownloadStrip: View {
    @EnvironmentObject private var model: ShellHostModel
    @ObservedObject var sources: NetworkSources
    let open: () -> Void

    var body: some View {
        if let overall = sources.overall {
            Button(action: open) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.to.line").font(.system(size: 14, weight: .semibold))
                    Text(summary(overall)).font(.system(size: 13, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(ShellInk.accent)
                .padding(.horizontal, 12).frame(height: 40)
                .background(ShellInk.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}

extension DownloadStrip {
    /// "2 · Downloading · 41 % · 12 MB/s · 8 min left".
    fileprivate func summary(_ overall: NetworkSources.Overall) -> String {
        var parts = ["\(overall.count)", model.text(.downloadingNow), "\(Int(overall.fraction * 100)) %"]
        if overall.bytesPerSecond > 0 { parts.append("\(ByteCountFormatter.string(fromByteCount: Int64(overall.bytesPerSecond), countStyle: .file))/s") }
        if let left = overall.secondsLeft { parts.append(TransferSpeed.leftText(left)) }
        return parts.joined(separator: " · ")
    }
}

/// The games the sources have and this iPhone does not, as tiles: the same shape as an installed game's, faded, with a cloud on
/// it. A touch downloads it, the cloud becomes a ring that shows how far, and a touch on the ring pauses.
struct CloudGamesSection: View {
    @EnvironmentObject private var model: ShellHostModel
    @ObservedObject var sources: NetworkSources
    @ObservedObject var selection: CloudSelection
    let filter: LibraryFilter
    @State private var asking: NetworkSources.BuildEntry?

    var body: some View {
        let items = CloudGames.items(sources: sources, games: model.games).filter { filter != .updates || $0.state == .updateAvailable }
        // An offloaded game no source has now keeps its tile, so the player sees what is waiting to come back.
        let offered = Set(items.map { $0.entry.game.titleID })
        let orphans = filter == .updates ? [] : model.offloaded.filter { !offered.contains($0.titleID) }
        let installed = Set(model.games.map(\.id))
        let builds = filter == .updates ? [] : sources.buildable.filter { !installed.contains($0.build.titleID) && !offered.contains($0.build.titleID) }
        if filter != .onPhone, !items.isEmpty || !orphans.isEmpty || !builds.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 16, alignment: .top)], spacing: 22) {
                ForEach(items) { CloudTile(sources: sources, selection: selection, item: $0) }
                ForEach(orphans) { OffloadedTile(sources: sources, entry: $0) }
                ForEach(builds) { entry in BuildTile(sources: sources, entry: entry) { asking = entry } }
            }
            .alert(model.text(.buildAsk), isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }), presenting: asking) { entry in
                Button(model.text(.buildAction)) { sources.requestBuild(entry) }
                Button(model.text(.cancel), role: .cancel) {}
            } message: { entry in
                Text("\(entry.build.name)\n\(model.text(.buildAskBody))")
            }
            .alert(model.text(.toBuild), isPresented: Binding(get: { sources.buildNotice != nil }, set: { if !$0 { sources.buildNotice = nil } })) {
                Button(model.text(.close), role: .cancel) {}
            } message: {
                Text(sources.buildNotice.map { model.sourceMessage($0) } ?? "")
            }
        }
    }
}

private struct CloudTile: View {
    @EnvironmentObject private var model: ShellHostModel
    @ObservedObject var sources: NetworkSources
    @ObservedObject var selection: CloudSelection
    let item: CloudGames.Item
    @State private var image: UIImage?

    private var transfer: NetworkSources.Transfer? {
        sources.transfers.first { $0.id == NetworkSources.CloudEntry.key(item.entry.record.id, item.entry.game.titleID) }
    }

    var body: some View {
        Button(action: touch) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous).fill(ShellInk.raised)
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill().opacity(0.6)
                    } else {
                        Text(item.entry.game.name).font(ShellFont.display(17)).foregroundStyle(ShellInk.secondary)
                            .multilineTextAlignment(.leading).padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(ShellInk.line))
                .overlay(alignment: .topTrailing) { (selection.active ? AnyView(tick) : AnyView(badge)).padding(8) }
                .overlay(alignment: .topLeading) {
                    if item.state == .updateAvailable { ShellPill(model.text(.filterUpdates), color: ShellInk.accent).padding(8) }
                    else if model.offloaded.contains(where: { $0.titleID == item.entry.game.titleID }) {
                        ShellPill(model.text(.offloadedPill), color: ShellInk.secondary).padding(8)
                    }
                }
                Text(item.entry.game.name).font(.system(size: 14, weight: .bold)).foregroundStyle(ShellInk.primary).lineLimit(1)
                Text(detail).font(.system(size: 11)).foregroundStyle(detailColor).lineLimit(2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let transfer { Button(model.text(.cancel), role: .destructive) { sources.cancel(transfer.id) } }
        }
        .task(id: item.entry.game.titleID) { image = await sources.icon(for: item.entry.game.titleID, in: item.entry.record) }
    }

    private func touch() {
        if selection.active { selection.toggle(item.id); return }
        guard let transfer else { sources.download([item.entry.game], from: item.entry.record); return }
        switch transfer.phase {
        case .running, .queued: sources.pause(transfer.id)
        case .paused, .failed: sources.resume(transfer.id)
        }
    }

    private var tick: some View {
        let on = selection.ids.contains(item.id)
        return Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 22))
            .foregroundStyle(on ? ShellInk.accent : ShellInk.secondary)
            .frame(width: 32, height: 32).background(Color.black.opacity(0.65), in: Circle())
    }

    @ViewBuilder
    private var badge: some View {
        if let transfer {
            let fraction = transfer.progress?.fraction ?? 0
            ZStack {
                Circle().fill(Color.black.opacity(0.65))
                Circle().stroke(Color.white.opacity(0.18), lineWidth: 3)
                Circle().trim(from: 0, to: max(0.02, fraction)).stroke(ShellInk.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: transfer.phase == .running || transfer.phase == .queued ? "pause.fill" : "play.fill")
                    .font(.system(size: 10)).foregroundStyle(ShellInk.accent)
            }
            .frame(width: 32, height: 32)
        } else {
            Image(systemName: "icloud.and.arrow.down").font(.system(size: 14, weight: .semibold)).foregroundStyle(ShellInk.accent)
                .frame(width: 32, height: 32).background(Color.black.opacity(0.65), in: Circle())
        }
    }

    private var detail: String {
        guard let transfer else { return "\(item.entry.record.name) · \(model.sizeText(item.entry.game.totalBytes))" }
        switch transfer.phase {
        case .queued:
            return sources.queuePosition(of: transfer.id).map { "\(model.text(.queuedPosition)) · \($0)" } ?? model.text(.waiting)
        case .running:
            let percent = Int((transfer.progress?.fraction ?? 0) * 100)
            guard transfer.bytesPerSecond > 0 else { return "\(percent) %" }
            let speed = "\(percent) % · \(ByteCountFormatter.string(fromByteCount: Int64(transfer.bytesPerSecond), countStyle: .file))/s"
            return transfer.secondsLeft.map { "\(speed)\n\(TransferSpeed.leftText($0))" } ?? speed
        case .paused: return model.text(.pausedState)
        case .failed(let reason): return model.sourceMessage(reason)
        }
    }

    private var detailColor: Color {
        if let transfer {
            if case .failed = transfer.phase { return ShellInk.bad }
            return ShellInk.accent
        }
        return ShellInk.secondary
    }
}

/// A game that was offloaded and that no source offers right now: its tile, with what was kept.
private struct OffloadedTile: View {
    @EnvironmentObject private var model: ShellHostModel
    @ObservedObject var sources: NetworkSources
    let entry: OffloadedGame

    var body: some View {
        Button { sources.refreshOffered(force: true) } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous).fill(ShellInk.raised)
                    if let url = model.offloadStore.iconURL(for: entry.titleID), let thumbnail = GameArtwork.thumbnail(at: url, maxPixels: GameArtwork.maxPixels) {
                        Image(uiImage: UIImage(cgImage: thumbnail)).resizable().scaledToFill().opacity(0.4)
                    } else {
                        Text(entry.name).font(ShellFont.display(17)).foregroundStyle(ShellInk.secondary)
                            .multilineTextAlignment(.leading).padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(ShellInk.line))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "icloud.slash").font(.system(size: 14, weight: .semibold)).foregroundStyle(ShellInk.secondary)
                        .frame(width: 32, height: 32).background(Color.black.opacity(0.65), in: Circle()).padding(8)
                }
                Text(entry.name).font(.system(size: 14, weight: .bold)).foregroundStyle(ShellInk.primary).lineLimit(1)
                Text(model.text(.offloadedNoSource)).font(.system(size: 11)).foregroundStyle(ShellInk.secondary).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) { model.forgetOffloaded(entry.titleID) } label: { Label(model.text(.forgetOffloaded), systemImage: "xmark") }
        }
    }
}

/// A game the Mac has the dump of and has not built: a text tile with the state of its build. A touch asks the Mac to build it.
private struct BuildTile: View {
    @EnvironmentObject private var model: ShellHostModel
    @ObservedObject var sources: NetworkSources
    let entry: NetworkSources.BuildEntry
    let ask: () -> Void

    var body: some View {
        Button(action: touch) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous).fill(ShellInk.raised)
                    Text(entry.build.name).font(ShellFont.display(17)).foregroundStyle(ShellInk.secondary)
                        .multilineTextAlignment(.leading).padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    if entry.build.state == .building {
                        Circle().trim(from: 0, to: max(0.02, entry.build.progress)).stroke(ShellInk.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90)).frame(width: 56, height: 56)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(ShellInk.line))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "hammer").font(.system(size: 14, weight: .semibold)).foregroundStyle(ShellInk.accent)
                        .frame(width: 32, height: 32).background(Color.black.opacity(0.65), in: Circle()).padding(8)
                }
                Text(entry.build.name).font(.system(size: 14, weight: .bold)).foregroundStyle(ShellInk.primary).lineLimit(1)
                Text(detail).font(.system(size: 11)).foregroundStyle(failed ? ShellInk.bad : ShellInk.accent).lineLimit(2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var failed: Bool { entry.build.state == .failed }

    private var detail: String {
        switch entry.build.state {
        case .idle: return "\(entry.record.name) · \(model.text(.toBuild))"
        case .queued: return model.text(.buildQueued)
        case .building: return "\(model.text(.buildBuilding)) · \(Int(entry.build.progress * 100)) %"
        case .failed: return entry.build.detail.isEmpty ? model.text(.toBuild) : entry.build.detail
        }
    }

    private func touch() {
        switch entry.build.state {
        case .idle, .failed: ask()
        case .queued, .building: break
        }
    }
}
