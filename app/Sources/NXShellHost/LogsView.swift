import NXPocketKit
import NXShellUI
import SwiftUI
import UIKit

/// The Logs screen: the app's log and every game start's log, newest first, or one game's. Each opens with copy,
/// share and delete. `open` goes straight to one log, as the failed-launch notice does.
public struct LogsView: View {
    @EnvironmentObject private var model: ShellHostModel
    @Environment(\.dismiss) private var dismiss
    let titleID: String?

    @State private var path: [LogFile]
    @State private var files: [LogFile] = []

    public init(titleID: String? = nil, open: LogFile? = nil) {
        self.titleID = titleID
        _path = State(initialValue: open.map { [$0] } ?? [])
    }

    public var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                ShellInk.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let titleID {
                            Text(model.title(ofTitleID: titleID))
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(ShellInk.primary)
                        } else {
                            Text(model.text(.logsBody)).font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
                        }
                        if files.isEmpty {
                            Text(model.text(.noLogs)).font(.system(size: 13)).foregroundStyle(ShellInk.secondary)
                                .padding(.top, 20)
                        }
                        ForEach(files) { file in
                            NavigationLink(value: file) { LogRow(file: file, showsGame: titleID == nil) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle(model.text(.logs))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(model.text(.close)) { dismiss() } }
            }
            .navigationDestination(for: LogFile.self) { file in
                LogDetailView(file: file, deleted: reload)
            }
            .onAppear(perform: reload)
        }
        .preferredColorScheme(.dark)
    }

    private func reload() { files = model.logs(for: titleID) }
}

private struct LogRow: View {
    @EnvironmentObject private var model: ShellHostModel
    let file: LogFile
    let showsGame: Bool

    var body: some View {
        ShellCard(padding: 12) {
            HStack(spacing: 12) {
                icon.frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(showsGame || file.kind == .app ? model.title(of: file) : date)
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(ShellInk.primary).lineLimit(1)
                    Text(showsGame || file.kind == .app ? "\(date) · \(size)" : size)
                        .font(.system(size: 12)).foregroundStyle(ShellInk.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(ShellInk.secondary)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let titleID = file.titleID, let game = model.games.first(where: { $0.id == titleID }) {
            GameIcon(game: game, cornerRadius: 8)
        } else if file.kind == .app {
            AppMark(size: 36)
        } else {
            Image(systemName: "doc.text").foregroundStyle(ShellInk.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ShellInk.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var date: String {
        file.date == .distantPast ? "—" : file.date.formatted(date: .abbreviated, time: .shortened)
    }

    private var size: String { model.sizeText(file.bytes) }
}

/// One log: its end in a text view that scrolls to the last line, and copy, share and delete under it.
struct LogDetailView: View {
    @EnvironmentObject private var model: ShellHostModel
    @Environment(\.dismiss) private var dismiss
    let file: LogFile
    let deleted: () -> Void

    @State private var shown: (text: String, isTail: Bool)?
    @State private var confirmingErase = false

    var body: some View {
        ZStack {
            ShellInk.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 8) {
                Text(file.date == .distantPast ? model.sizeText(file.bytes)
                     : "\(file.date.formatted(date: .abbreviated, time: .standard)) · \(model.sizeText(file.bytes))")
                    .font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
                if shown?.isTail == true {
                    Text(model.text(.logShownTail)).font(.system(size: 11)).foregroundStyle(ShellInk.accent)
                }
                if let shown, shown.text.isEmpty {
                    Text(model.text(.emptyLog)).font(.system(size: 13)).foregroundStyle(ShellInk.secondary)
                    Spacer()
                } else if let shown {
                    LogTextView(text: shown.text)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .navigationTitle(model.title(of: file))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button { copy() } label: { Label(model.text(.copy), systemImage: "doc.on.doc") }
                Spacer()
                ShareLink(item: file.url) { Label(model.text(.share), systemImage: "square.and.arrow.up") }
                Spacer()
                Button(role: .destructive) { confirmingErase = true } label: { Label(model.text(.erase), systemImage: "trash") }
            }
        }
        .confirmationDialog(model.text(.erase), isPresented: $confirmingErase, titleVisibility: .visible) {
            Button(model.text(.erase), role: .destructive) {
                model.deleteLog(file)
                deleted()
                dismiss()
            }
            Button(model.text(.cancel), role: .cancel) {}
        } message: {
            Text("\(model.title(of: file))\n\(model.text(.eraseLogBody))")
        }
        .task {
            let file = file
            shown = await Task.detached(priority: .userInitiated) { GameLogs.text(of: file) }.value
        }
    }

    /// The file, not only the end the screen shows: up to its last 16 MB, which no pasteboard needs more of.
    private func copy() {
        UIPasteboard.general.string = GameLogs.text(of: file, limit: 16 << 20).text
    }
}

/// A read-only text view: SwiftUI's Text lays out half a megabyte of log slowly, UITextView does not.
private struct LogTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.textColor = UIColor(white: 1, alpha: 0.75)
        view.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        view.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 12, right: 0)
        view.alwaysBounceVertical = true
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        guard view.text != text else { return }
        view.text = text
        // The end is where a game stopped: the log opens there.
        DispatchQueue.main.async {
            let end = (view.text as NSString).length
            if end > 0 { view.scrollRangeToVisible(NSRange(location: end - 1, length: 1)) }
        }
    }
}
