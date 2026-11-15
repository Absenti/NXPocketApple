import AppKit
import Foundation
import NXPMacKit
import NXPocketKit

/// The first-run setup: what the Mac lacks for a build, checked in order (`FirstRunSetup.states`), and the steps the
/// launcher does itself, each in the background with its progress, and again with Retry after a failure.
extension AppModel {
    /// A required step (all but XcodeGen) is not ready.
    public var setupIncomplete: Bool {
        SetupStep.allCases.contains { $0 != .xcodegen && !(setupStates[$0]?.isReady ?? false) }
    }

    /// Reads what the Mac has, off the main thread. Called after every look at the toolchain. A step at work keeps its
    /// progress, and a failed one its reason, until it is ready.
    func checkSetup() {
        let toolchain = toolchain
        for step in SetupStep.allCases where setupStates[step] == nil { setupStates[step] = .checking }
        Task {
            let facts = await Task.detached(priority: .utility) { FirstRunSetup.gather(toolchain: toolchain) }.value
            for (step, state) in FirstRunSetup.states(facts) {
                switch setupStates[step] {
                case .working?: continue
                case .failed? where !state.isReady: continue
                default: setupStates[step] = state
                }
            }
            if !setupChecked {
                setupChecked = true
                if setupIncomplete { screen = .setup }
            }
        }
    }

    /// What the step's button does: open the App Store or Xcode for what only the user can do, or the step itself.
    /// The engines on this Mac a build can use, the stable one first.
    public func availableEngines() -> [EngineChoice] {
        let named = settings.value.engineRoot.isEmpty ? nil : URL(fileURLWithPath: (settings.value.engineRoot as NSString).expandingTildeInPath)
        return EngineChoices.available(selected: named)
    }

    /// The engine builds are made with now, wherever it was chosen: Settings, or the first one found.
    public var engineInUse: URL { toolchain.engine.root }

    /// Builds with this engine from now on; nil goes back to the automatic choice (the first one found).
    public func useEngine(_ choice: EngineChoice?) {
        settings.value.engineRoot = choice?.url.path ?? ""
        append("engine: \(choice.map { "\($0.title) at \($0.url.path)" } ?? "automatic choice")")
        refreshToolchain()
    }

    /// Fetches the stable release into the launcher's own folder (the Setup screen shows how it goes). A copy already there is left as it is.
    public func installStableEngine() {
        screen = .setup
        runSetupStep(.engine)
    }

    public func runSetupStep(_ step: SetupStep) {
        switch step {
        case .xcode, .iosSDK:
            NSWorkspace.shared.open(FirstRunSetup.appStoreXcode)
        case .xcodeReady:
            if let xcode = toolchain.xcode {
                NSWorkspace.shared.openApplication(at: xcode, configuration: NSWorkspace.OpenConfiguration())
            }
        case .metalToolchain:
            guard let xcode = toolchain.xcode else { return }
            perform(step) { progress, log in try FirstRunSetup.downloadMetalToolchain(xcode: xcode, progress: progress, log: log) }
        case .python:
            perform(step) { progress, log in try FirstRunSetup.installPython(progress: progress, log: log) }
        case .engine:
            let python = enginePython
            let xcode = toolchain.xcode
            let repository = repository
            perform(step) { progress, log in
                try FirstRunSetup.installEngine(python: python, xcode: xcode, repository: repository, progress: progress, log: log)
            } then: { [weak self] in
                // An engine folder set in Settings that holds no engine would hide the one just fetched.
                guard let self, !self.settings.value.engineRoot.isEmpty, !self.toolchain.engine.isUsable else { return }
                self.append("setup: Settings named an engine folder with no engine in it (\(self.settings.value.engineRoot)); cleared, the launcher's own is used")
                self.settings.value.engineRoot = ""
            }
        case .xcodegen:
            perform(step) { progress, log in try FirstRunSetup.installXcodeGen(progress: progress, log: log) }
        }
    }

    /// What the step's button says.
    public func setupAction(_ step: SetupStep) -> String? {
        guard let state = setupStates[step] else { return nil }
        switch state {
        case .ready, .checking, .waiting, .working: return nil
        case .failed: return "Retry"
        case .missing:
            switch step {
            case .xcode, .iosSDK: return "Open the App Store"
            case .xcodeReady: return "Open Xcode"
            case .metalToolchain: return "Download"
            case .python, .engine, .xcodegen: return "Install"
            }
        }
    }

    /// engine.py needs a Python 3.9 or later and nothing else: the engine's own, else the system's (Xcode's).
    var enginePython: URL {
        let parts = toolchain.pythonVersion.split(separator: ".").compactMap { Int($0) }
        if parts.count == 2, parts[0] > 3 || (parts[0] == 3 && parts[1] >= 9),
           FileManager.default.isExecutableFile(atPath: toolchain.python.path) {
            return toolchain.python
        }
        return URL(fileURLWithPath: "/usr/bin/python3")
    }

    private enum SetupEvent {
        case progress(Double?, String)
        case log(String)
    }

    /// Runs a step off the main thread; its progress and log lines come back in order, through one stream.
    private func perform(_ step: SetupStep,
                         _ work: @escaping @Sendable (@escaping FirstRunSetup.Progress, @escaping FirstRunSetup.Log) throws -> Void,
                         then: @escaping @MainActor () -> Void = {}) {
        guard !(setupStates[step]?.isWorking ?? false) else { return }
        setupStates[step] = .working(fraction: 0, detail: "starting")
        append("setup: \(step.title)")
        let (events, sink) = AsyncStream.makeStream(of: SetupEvent.self)
        Task {
            let reader = Task { @MainActor in
                for await event in events {
                    switch event {
                    case .progress(let fraction, let detail):
                        var kept = fraction
                        if kept == nil, case .working(let previous, _)? = self.setupStates[step] { kept = previous }
                        self.setupStates[step] = .working(fraction: kept, detail: detail)
                    case .log(let line):
                        self.append(line)
                    }
                }
            }
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
                Result {
                    try work({ fraction, detail in sink.yield(.progress(fraction, detail)) }, { line in sink.yield(.log(line)) })
                }
            }.value
            sink.finish()
            await reader.value
            switch outcome {
            case .success:
                setupStates[step] = .checking
                then()
                refreshToolchain()
                refreshPhoneApp()
            case .failure(let error):
                let reason = (error as? NXPocketError)?.detail ?? error.localizedDescription
                setupStates[step] = .failed(reason)
                append("setup: \(step.title) failed: \(reason)")
            }
        }
    }
}
