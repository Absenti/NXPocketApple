import SwiftUI
import NXPMacKit
import NXPMacModel

/// What the Mac needs before a first build, in order, each with what it is for, where it stands and the one thing to
/// do about it. The launcher installs Python, the engine and XcodeGen itself, into its own folder; Xcode comes from
/// the App Store, and its first start is Xcode's own.
struct SetupView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Text("Setup").font(.system(size: 22, weight: .semibold)).foregroundStyle(Ink.primary)
                    if model.checkingToolchain { ProgressView().controlSize(.small) }
                    Spacer()
                    Button {
                        model.refreshToolchain()
                    } label: {
                        Label("Check again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.checkingToolchain)
                }
                Text(summary)
                    .font(.system(size: 12)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(SetupStep.allCases.enumerated()), id: \.element) { index, step in
                    SetupRow(number: index + 1, step: step)
                }
                Text("Everything the launcher installs goes into \(SetupPaths.standard.root.path), each download checked against the SHA-256 it is pinned to before it is unpacked. Nothing runs with sudo, and Homebrew is not needed.")
                    .font(.system(size: 11)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var summary: String {
        model.setupIncomplete
            ? "A build needs each step below, in this order. Do the first one not ready, then the next."
            : "This Mac has everything a build needs."
    }
}

private struct SetupRow: View {
    @EnvironmentObject private var model: AppModel
    let number: Int
    let step: SetupStep

    private var state: SetupState { model.setupStates[step] ?? .checking }

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                badge.frame(width: 22)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text("\(number). \(step.title)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.primary)
                        if step == .xcodegen { Pill(text: "optional") }
                    }
                    Text(step.purpose).font(.system(size: 11)).foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    detail
                }
                Spacer(minLength: 8)
                if let action = model.setupAction(step) {
                    Button(action) { model.runSetupStep(step) }
                        .buttonStyle(.borderedProminent).tint(Ink.accent).foregroundStyle(.black)
                }
            }
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch state {
        case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(Ink.good)
        case .missing: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Ink.accent)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Ink.bad)
        case .waiting: Image(systemName: "circle.dashed").foregroundStyle(Ink.secondary)
        case .checking, .working: ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch state {
        case .checking:
            Text("checking…").font(.system(size: 11)).foregroundStyle(Ink.secondary)
        case .ready(let text):
            Text(text).font(.system(size: 11)).foregroundStyle(Ink.good).textSelection(.enabled).lineLimit(2)
        case .missing(let text), .waiting(let text):
            Text(text).font(.system(size: 11)).foregroundStyle(Ink.primary).fixedSize(horizontal: false, vertical: true)
        case .working(let fraction, let text):
            VStack(alignment: .leading, spacing: 4) {
                if let fraction { Bar(fraction: fraction) } else { ProgressView().progressViewStyle(.linear) }
                Text(text).font(.system(size: 11)).foregroundStyle(Ink.secondary).lineLimit(1).truncationMode(.middle)
            }
        case .failed(let text):
            Text(text).font(.system(size: 11)).foregroundStyle(Ink.bad).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
