import SwiftUI
import NXPMacKit
import NXPMacModel

/// The queue: each item's state and bar, the whole queue's bar, and a cancel.
struct QueueView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionHeading(text: "Queue")
                    Spacer()
                    if model.queueHasWork {
                        Button("Cancel") { model.cancelQueue() }.buttonStyle(.bordered)
                    }
                    if model.queue.contains(where: { $0.phase.isFinished }) {
                        Button("Clear finished") { model.clearFinishedQueueItems() }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Ink.secondary)
                    }
                }
                if model.queue.isEmpty {
                    Text("Tick games and build them: they are built one after another, then sent to the iPhone.")
                        .font(.system(size: 11)).foregroundStyle(Ink.secondary)
                } else {
                    overall
                    ForEach(model.queue) { item in
                        row(item)
                    }
                }
            }
        }
    }

    private var overall: some View {
        let finished = model.queue.filter { $0.phase.isFinished }.count
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(model.queueHasWork ? "\(finished) of \(model.queue.count) done" : "Finished")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.primary)
                Spacer()
                Text("\(Int(model.queueFraction * 100))%").font(.system(size: 12)).foregroundStyle(Ink.secondary)
            }
            Bar(fraction: model.queueFraction)
        }
    }

    private func row(_ item: QueueItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol(item.phase)).foregroundStyle(color(item.phase)).font(.system(size: 12))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.primary).lineLimit(1)
                    Text(item.status).font(.system(size: 11)).foregroundStyle(color(item.phase))
                        .lineLimit(3).textSelection(.enabled)
                }
                Spacer(minLength: 0)
                if item.phase.isActive {
                    Text("\(Int(item.fraction * 100))%").font(.system(size: 11)).foregroundStyle(Ink.secondary)
                } else if item.phase == .waiting || item.phase.isFinished {
                    Button {
                        model.removeFromQueue(item.id)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 10))
                    }
                    .buttonStyle(.plain).foregroundStyle(Ink.secondary).help("Remove from the queue")
                }
            }
            if case .needsAnswer = item.phase {
                HStack(spacing: 8) {
                    Button("Send anyway") { model.answer(item.id, sendAnyway: true) }.buttonStyle(.bordered)
                    Button("Don't send") { model.answer(item.id, sendAnyway: false) }.buttonStyle(.bordered)
                }
                .padding(.leading, 20)
            }
            if let detail = item.detail {
                if let fraction = detail.fraction {
                    Bar(fraction: fraction, tint: isSending(item.phase) ? Ink.good : Ink.accent)
                } else {
                    // A stage without a count: the item's own share shows instead, which moves stage by stage.
                    Bar(fraction: item.fraction, tint: Ink.accent.opacity(0.5))
                }
                Text(detail.text).font(.system(size: 10)).foregroundStyle(Ink.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
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
