import NXPocketKit
import NXShellUI
import SwiftUI

/// The check of a game's data and, when something is damaged, the choice of the source to repair it from.
struct RepairSheet: View {
    @EnvironmentObject private var model: ShellHostModel
    @Environment(\.dismiss) private var dismiss
    let game: InstalledGame

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(model.name(of: game)).font(ShellFont.display(20)).foregroundStyle(ShellInk.primary)
                Text(model.text(.repairBody)).font(.system(size: 13)).foregroundStyle(ShellInk.secondary).lineSpacing(2)
                content
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(ShellInk.background)
            .navigationTitle(model.text(.repairTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(model.text(.close)) { model.dismissRepair(); dismiss() }.disabled(model.repairBusy) } }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(model.repairBusy)
    }

    @ViewBuilder
    private var content: some View {
        switch model.repairState {
        case .idle:
            EmptyView()
        case .scanning(let fraction):
            progress(model.text(.repairScanning), fraction)
        case .repairing(let fraction):
            progress(model.text(.repairRepairing), fraction)
        case .clean:
            line(model.text(.repairClean), symbol: "checkmark.circle.fill", color: ShellInk.good)
        case .done(let count):
            line(String(format: model.text(.repairDone), count), symbol: "checkmark.circle.fill", color: ShellInk.good)
        case .unavailable:
            line(model.text(.repairNoList), symbol: "info.circle", color: ShellInk.secondary)
        case .failed(let reason):
            line(reason, symbol: "exclamationmark.triangle.fill", color: ShellInk.bad)
        case .found(let bad, let total):
            line(String(format: model.text(.repairFound), bad, total), symbol: "exclamationmark.triangle.fill", color: ShellInk.accent)
            let sources = model.repairSources(for: game)
            if sources.isEmpty {
                Text(model.text(.repairNoSource)).font(.system(size: 13)).foregroundStyle(ShellInk.secondary)
            }
            ForEach(sources) { entry in
                Button(String(format: model.text(.repairFrom), entry.record.name)) { model.repair(game, from: entry) }
                    .buttonStyle(ShellButtonStyle(prominent: true))
            }
        }
    }

    private func progress(_ title: String, _ fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(ShellInk.primary)
            ShellBar(fraction: fraction)
        }
    }

    private func line(_ text: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.system(size: 14)).foregroundStyle(ShellInk.primary)
        }
    }
}
