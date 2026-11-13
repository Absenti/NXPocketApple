import SwiftUI
import NXPMacKit
import NXPMacModel

/// What the Mac needs before a first build, in order, each with what it is for, where it stands and the one thing to
/// do about it. The launcher installs Python, the engine and XcodeGen itself, into its own folder; Xcode comes from
/// the App Store, and its first start is Xcode's own. Built from rows, like Settings.
struct SetupView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        RowsPage(maxColumns: 1) {
            HStack(alignment: .bottom, spacing: 10) {
                PageTitle(title: "Setup", subtitle: summary)
                Spacer()
                if model.checkingToolchain { ProgressView().controlSize(.small) }
                Button {
                    model.refreshToolchain()
                } label: {
                    Label("Check again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(QuietButtonStyle(large: true))
                .disabled(model.checkingToolchain)
            }
            progress
        } content: {
            SettingsGroup(title: "Steps") {
                ForEach(Array(SetupStep.allCases.enumerated()), id: \.element) { index, step in
                    SetupRow(number: index + 1, step: step)
                }
            }
            Note("Everything the launcher installs goes into \(Friendly.path(SetupPaths.standard.root.path)), each download checked against the SHA-256 it is pinned to before it is unpacked. Nothing runs with sudo, and Homebrew is not needed.")
        }
    }

    private var readyCount: Int {
        SetupStep.allCases.filter { step in
            if case .ready = model.setupStates[step] ?? .checking { return true }
            return false
        }.count
    }

    /// How far along, in one large number and a bar.
    private var progress: some View {
        HStack(spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(readyCount)").font(.system(size: 52, weight: .heavy)).tracking(-2).foregroundStyle(Ink.accent)
                Text("of \(SetupStep.allCases.count) ready").font(.system(size: 15)).foregroundStyle(Ink.secondary)
            }
            Bar(fraction: Double(readyCount) / Double(max(1, SetupStep.allCases.count)))
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

    private var wash: Color {
        switch state {
        case .ready: return .clear
        case .missing, .working: return Ink.tint
        case .failed: return Ink.bad.opacity(0.08)
        default: return .clear
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            badge
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("\(number). \(step.title)").font(.system(size: 14.5, weight: .bold)).foregroundStyle(Ink.primary)
                    if step == .xcodegen { Pill(text: "optional") }
                }
                Text(step.purpose).font(.system(size: 12.5)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                detail.padding(.top, 2)
            }
            Spacer(minLength: 12)
            if let action = model.setupAction(step) {
                Button(action) { model.runSetupStep(step) }.buttonStyle(PrimaryButtonStyle(large: true))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(minHeight: 64)
        .background(wash)
        .overlay(alignment: .top) { Divider().overlay(Ink.line) }
    }

    @ViewBuilder
    private var badge: some View {
        Group {
            switch state {
            case .ready: Image(systemName: "checkmark").foregroundStyle(Ink.good)
            case .missing: Image(systemName: "exclamationmark").foregroundStyle(Ink.accent)
            case .failed: Image(systemName: "xmark").foregroundStyle(Ink.bad)
            case .waiting: Image(systemName: "circle.dashed").foregroundStyle(Ink.secondary)
            case .checking, .working: ProgressView().controlSize(.small)
            }
        }
        .font(.system(size: 14, weight: .bold))
        .frame(width: 38, height: 38)
        .background(Ink.raised, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    /// What a ready step says: its version, never the folder it was found in (that stays as a tooltip).
    private func readyText(_ text: String) -> String {
        if text.hasPrefix("/") || text.hasPrefix("~") { return "Ready" }
        if let range = text.range(of: " · /") { return String(text[..<range.lowerBound]) }
        return Friendly.text(text)
    }

    @ViewBuilder
    private var detail: some View {
        switch state {
        case .checking:
            Text("checking…").font(.system(size: 12)).foregroundStyle(Ink.secondary)
        case .ready(let text):
            Text(readyText(text)).font(.system(size: 12)).foregroundStyle(Ink.good).lineLimit(2).help(text)
        case .missing(let text), .waiting(let text):
            Text(Friendly.text(text)).font(.system(size: 12)).foregroundStyle(Ink.primary).fixedSize(horizontal: false, vertical: true)
        case .working(let fraction, let text):
            VStack(alignment: .leading, spacing: 6) {
                if let fraction { Bar(fraction: fraction) } else { ProgressView().progressViewStyle(.linear) }
                Text(Friendly.text(text)).font(.system(size: 12)).foregroundStyle(Ink.secondary).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: 360)
        case .failed(let text):
            Text(Friendly.text(text)).font(.system(size: 12)).foregroundStyle(Ink.bad).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
