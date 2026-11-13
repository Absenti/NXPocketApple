import SwiftUI
import NXPMacKit
import NXPMacModel

/// The queue: each item's state and bar, the whole queue's bar, a pause for the build under way, and a cancel.
struct QueueView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsGroup(title: "Queue") {
            if model.queue.contains(where: { $0.phase.isFinished }) {
                Button("Clear finished") { model.clearFinishedQueueItems() }.buttonStyle(QuietButtonStyle())
            }
            if model.queueHasWork {
                Button("Cancel") { model.cancelQueue() }.buttonStyle(QuietButtonStyle())
            }
        } content: {
            if model.queue.isEmpty {
                SettingRow(symbol: "clock", title: "Nothing queued",
                           detail: "Tick games and build them: they are built one after another, then sent.", detailLines: 2) { EmptyView() }
            } else {
                overall
                ForEach(model.queue) { item in row(item) }
            }
        }
    }

    private var overall: some View {
        let finished = model.queue.filter { $0.phase.isFinished }.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.queueHasWork ? "\(finished) of \(model.queue.count) done" : "Finished")
                    .font(.system(size: 14.5, weight: .bold)).foregroundStyle(Ink.primary)
                Spacer()
                Text("\(Int(model.queueFraction * 100))%").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.accent)
            }
            Bar(fraction: model.queueFraction)
        }
        .padding(16)
    }

    private func row(_ item: QueueItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 14) {
                SymbolTile(symbol: item.isPaused ? "pause.circle" : symbol(item.phase),
                           color: item.isPaused ? Ink.accent : color(item.phase))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.system(size: 14.5, weight: .bold)).foregroundStyle(Ink.primary).lineLimit(1)
                    Text(Friendly.text(item.status)).font(.system(size: 12.5)).foregroundStyle(item.isPaused ? Ink.accent : color(item.phase))
                        .lineLimit(3).textSelection(.enabled)
                }
                Spacer(minLength: 8)
                if item.phase.isActive {
                    Text("\(Int(item.fraction * 100))%").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.secondary)
                }
                if item.canPause {
                    if item.isPaused {
                        Button("Resume") { model.resumeBuild(item.id) }
                            .buttonStyle(PrimaryButtonStyle(large: true)).help("Go on from where it stopped")
                    } else {
                        Button("Pause") { model.pauseBuild(item.id) }
                            .buttonStyle(QuietButtonStyle(large: true))
                            .help("Stop the build where it is, and everything it started: nothing is lost, the Mac is free meanwhile")
                    }
                }
                if item.phase.isActive || item.phase == .waiting {
                    Button("Cancel") { model.cancelItem(item.id) }
                        .buttonStyle(QuietButtonStyle(large: true))
                        .help(item.phase == .waiting ? "Take it out of the queue" : "Stop this one now")
                } else if item.phase.isFinished {
                    Button {
                        model.removeFromQueue(item.id)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(Ink.secondary).help("Remove from the list")
                }
            }
            if case .needsAnswer = item.phase {
                HStack(spacing: 8) {
                    Button("Send anyway") { model.answer(item.id, sendAnyway: true) }.buttonStyle(PrimaryButtonStyle())
                    Button("Don't send") { model.answer(item.id, sendAnyway: false) }.buttonStyle(QuietButtonStyle())
                }
                .padding(.leading, 52)
            }
            if let detail = item.detail {
                VStack(alignment: .leading, spacing: 4) {
                    if let fraction = detail.fraction {
                        Bar(fraction: fraction, tint: isSending(item.phase) ? Ink.good : Ink.deep)
                    } else {
                        // A stage without a count: the item's own share shows instead, which moves stage by stage.
                        Bar(fraction: item.fraction, tint: Ink.deep.opacity(0.5))
                    }
                    Text(Friendly.text(detail.text)).font(.system(size: 11)).foregroundStyle(Ink.secondary).lineLimit(1).truncationMode(.middle)
                }
                .padding(.leading, 52)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .overlay(alignment: .top) { Divider().overlay(Ink.line) }
    }

    private func isSending(_ phase: QueueItem.Phase) -> Bool {
        if case .sending = phase { return true }
        return false
    }

    private func symbol(_ phase: QueueItem.Phase) -> String {
        switch phase {
        case .waiting: return "clock"
        case .building, .packing: return "hammer"
        case .sending: return "arrow.up.circle"
        case .needsAnswer: return "questionmark.circle"
        case .done: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .cancelled: return "xmark.circle"
        }
    }

    private func color(_ phase: QueueItem.Phase) -> Color {
        switch phase {
        case .done: return Ink.good
        case .failed: return Ink.bad
        case .needsAnswer: return Ink.accent
        default: return Ink.secondary
        }
    }
}
