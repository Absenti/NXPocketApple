import Foundation
import NXPocketKit

/// One thing the launcher needs from the Mac, in the order the setup screen checks them: each step needs the ones
/// before it, except XcodeGen, which only the iPhone app screen needs.
public enum SetupStep: String, CaseIterable, Identifiable, Sendable {
    case xcode, xcodeReady, iosSDK, metalToolchain, python, engine, xcodegen

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .xcode: return "Xcode"
        case .xcodeReady: return "Xcode's first start"
        case .iosSDK: return "iOS SDK"
        case .metalToolchain: return "Metal compiler"
        case .python: return "Python and the engine's packages"
        case .engine: return "The engine (NX2Apple)"
        case .xcodegen: return "XcodeGen"
        }
    }

    /// What the step is for, in a line.
    public var purpose: String {
        switch self {
        case .xcode: return "The full Xcode, not the Command Line Tools alone: it brings the Metal compiler and the iOS SDK."
        case .xcodeReady: return "Its licence accepted and its components installed, which Xcode does at its first start."
        case .iosSDK: return "A game is linked against it."
        case .metalToolchain: return "Translates a game's shaders."
        case .python: return "The engine is a Python program, with a few packages of its own."
        case .engine: return "Unpacks a dump, rewrites the game's code and packs it."
        case .xcodegen: return "Only to build the iPhone app and the memory helper, on the iPhone app screen."
        }
    }
}

public enum SetupState: Equatable, Sendable {
    case checking
    case ready(String)
    /// What is missing and what to do about it.
    case missing(String)
    /// An earlier step has to be done first.
    case waiting(String)
    case working(fraction: Double?, detail: String)
    case failed(String)

    public var isReady: Bool { if case .ready = self { return true }; return false }
    public var isWorking: Bool { if case .working = self { return true }; return false }
}

/// Where the launcher keeps what it installs: its own folder in Application Support, nothing elsewhere.
public struct SetupPaths: Sendable, Equatable {
    public var root: URL

    public init(root: URL) { self.root = root }

    public static var standard: SetupPaths {
        SetupPaths(root: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NXPocket", isDirectory: true))
    }

    public var pythonBase: URL {
        root.appendingPathComponent("python-\(SetupPins.pythonVersion)+\(SetupPins.pythonRelease)", isDirectory: true)
    }
    public var pythonExecutable: URL { pythonBase.appendingPathComponent("bin/python3") }
    public var venv: URL { root.appendingPathComponent("venv", isDirectory: true) }
    public var venvPython: URL { venv.appendingPathComponent("bin/python3") }
    public var xcodegenFolder: URL { root.appendingPathComponent("xcodegen-\(SetupPins.xcodegenVersion)", isDirectory: true) }
    public var xcodegenBin: URL { xcodegenFolder.appendingPathComponent("xcodegen/bin", isDirectory: true) }
    public var xcodegen: URL { xcodegenBin.appendingPathComponent("xcodegen") }
    public var checkout: URL { root.appendingPathComponent("NX2Apple", isDirectory: true) }
    public var engine: URL { checkout.appendingPathComponent("engine", isDirectory: true) }
    var downloads: URL { root.appendingPathComponent(".downloads", isDirectory: true) }
}

/// What the Mac has, read in one go off the main thread (each fact is a short command or a file).
public struct SetupFacts: Sendable, Equatable {
    public var xcode: URL?
    public var xcodeVersion: String?
    /// `xcode-select -p` names the Command Line Tools and no Xcode is installed.
    public var commandLineToolsOnly = false
    public var licenceAccepted = false
    public var firstLaunchDone = false
    public var iosSDK: String?
    public var metal: String?
    public var python: String?
    public var pythonMissing: [String] = []
    public var engine: URL?
    public var xcodegen: URL?

    public init() {}
}

public enum FirstRunSetup {
    public typealias Progress = @Sendable (Double?, String) -> Void
    public typealias Log = @Sendable (String) -> Void

    public static let appStoreXcode = URL(string: "macappstore://apps.apple.com/app/xcode/id497799835")!

    // MARK: - Checking

    public static func gather(toolchain: Toolchain) -> SetupFacts {
        var facts = SetupFacts()
        facts.xcode = toolchain.xcode
        if let xcode = toolchain.xcode {
            facts.xcodeVersion = ToolchainLocator.xcodeVersion(xcode)?.map(String.init).joined(separator: ".")
            let environment = SetupCommand.environment(xcode: xcode)
            let xcodebuild = URL(fileURLWithPath: "/usr/bin/xcodebuild"), xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
            facts.licenceAccepted = quick(xcodebuild, ["-license", "check"], environment)?.status == 0
            facts.firstLaunchDone = quick(xcodebuild, ["-checkFirstLaunchStatus"], environment)?.status == 0
            if facts.licenceAccepted {
                facts.iosSDK = firstLine(quick(xcrun, ["--sdk", "iphoneos", "--show-sdk-version"], environment))
                if quick(xcrun, ["--find", "metal"], environment)?.status == 0 {
                    facts.metal = firstLine(quick(xcrun, ["metal", "--version"], environment))
                }
            }
        } else {
            let selected = firstLine(quick(URL(fileURLWithPath: "/usr/bin/xcode-select"), ["-p"], ProcessInfo.processInfo.environment))
            facts.commandLineToolsOnly = selected?.hasPrefix("/Library/Developer/CommandLineTools") == true
        }
        facts.python = toolchain.python.path
        facts.pythonMissing = toolchain.pythonMissing
        facts.engine = toolchain.engine.isUsable ? toolchain.engine.root : nil
        facts.xcodegen = PhoneAppBuild.xcodegen()
        return facts
    }

    /// Each step's state from the facts: what is there, what is missing and what waits on an earlier step.
    public static func states(_ facts: SetupFacts) -> [SetupStep: SetupState] {
        var states: [SetupStep: SetupState] = [:]
        if let xcode = facts.xcode {
            states[.xcode] = .ready("Xcode \(facts.xcodeVersion ?? "?") · \(xcode.path)")
        } else if facts.commandLineToolsOnly {
            states[.xcode] = .missing("Only the Command Line Tools are installed. The engine needs the full Xcode: the Metal compiler and the iOS SDK are not in them. Xcode is free on the App Store; install it, then check again.")
        } else {
            states[.xcode] = .missing("Xcode is not installed. It is free on the App Store; install it, then check again.")
        }

        let xcodeReady: Bool
        if facts.xcode == nil {
            states[.xcodeReady] = .waiting("Install Xcode first.")
            xcodeReady = false
        } else if !facts.licenceAccepted {
            states[.xcodeReady] = .missing("Xcode's licence is not accepted yet. Open Xcode once and agree to it.")
            xcodeReady = false
        } else if !facts.firstLaunchDone {
            states[.xcodeReady] = .missing("Xcode has not finished its first start. Open it once and let it install its components; it asks for your password itself, the launcher never does.")
            xcodeReady = false
        } else {
            states[.xcodeReady] = .ready("licence accepted, components installed")
            xcodeReady = true
        }

        if !xcodeReady {
            states[.iosSDK] = .waiting("Needs Xcode's first start.")
            states[.metalToolchain] = .waiting("Needs Xcode's first start.")
        } else {
            states[.iosSDK] = facts.iosSDK.map { .ready("iOS SDK \($0)") }
                ?? .missing("This Xcode has no iOS SDK. Install Xcode again from the App Store.")
            states[.metalToolchain] = facts.metal.map { .ready($0) }
                ?? .missing("Xcode 26 and later download the Metal compiler apart. Download fetches it with Apple's own xcodebuild -downloadComponent metaltoolchain (several hundred MB), or use Xcode → Settings → Components.")
        }

        if facts.pythonMissing.isEmpty, let python = facts.python {
            states[.python] = .ready(python)
        } else {
            states[.python] = .missing("No Python on this Mac has what the engine imports (missing: \(facts.pythonMissing.joined(separator: ", "))). Install puts Python \(SetupPins.pythonVersion) and the pinned packages in the launcher's own folder: about 40 MB to download, no password.")
        }

        if let engine = facts.engine {
            states[.engine] = .ready(engine.path)
        } else if !xcodeReady {
            states[.engine] = .waiting("Needs Xcode's first start: it is fetched with Xcode's git.")
        } else {
            states[.engine] = .missing("The engine is not on this Mac. Install clones NX2Apple at \(SetupPins.nx2appleRevision.prefix(8)) into the launcher's folder and builds the engine tree from it (nxnative and its patches): about 150 MB to download.")
        }

        states[.xcodegen] = facts.xcodegen.map { .ready($0.path) }
            ?? .missing("Install puts XcodeGen \(SetupPins.xcodegenVersion) in the launcher's folder (4 MB). Homebrew's works too.")
        return states
    }

    /// A short command with its environment, nil when it could not start or ran past 30 seconds.
    static func quick(_ executable: URL, _ arguments: [String], _ environment: [String: String]) -> ProcessRunner.Result? {
        let runner = ProcessRunner(executable: executable, arguments: arguments, environment: environment)
        guard (try? runner.start()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(30)
        while runner.isRunning, Date() < deadline { usleep(20_000) }
        if runner.isRunning {
            runner.cancel()
            return nil
        }
        return runner.waitUntilExit()
    }

    static func firstLine(_ result: ProcessRunner.Result?) -> String? {
        guard let result, result.status == 0 else { return nil }
        return result.lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Apple silicon, whatever the launcher itself runs as.
    public static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.0f MB", Double(bytes) / 1_000_000)
    }
}
