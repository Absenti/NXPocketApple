import Darwin
import Foundation
import UIKit

/// What starts a game. The engine is not part of this app: each game's `DmGame<title ID>.framework` links its own
/// host, its `front_ios.m` and its shaders (the engine's "Route C"), and exports four entry points for a shell to find
/// with dlsym (engine `dm/ios/Shell/ShellGlue.h`). Starting a game is therefore the shell's job only:
/// `FrameworkEngineHost` is what the engine's own shell does in `dm/ios/Shell/ShellMain.m`.
@MainActor
public protocol EngineHost {
    var isAvailable: Bool { get }
    /// Starts the engine's early loading for `plan`. Nil when it started, else the reason, as the player reads it.
    func start(_ plan: EngineLaunchPlan) throws -> String?
    /// After a successful start: shows the game's own view, which starts the game. Nil when it is on screen.
    func present() -> String?
    /// The window the game's view is in, once it is on screen: a question asked while a game runs goes on top of it,
    /// since the library's window is under the game's.
    var gameWindow: UIWindow? { get }
}

@MainActor
public func makeDefaultEngineHost() -> EngineHost { FrameworkEngineHost.shared }

/// A host that starts nothing, for the tests and for a build that is not meant to run games.
public struct UnlinkedEngineHost: EngineHost {
    public static let reason = "This build of NXPocket cannot start games: it can import, verify and sign them."

    public init() {}
    public var isAvailable: Bool { false }
    public func start(_ plan: EngineLaunchPlan) throws -> String? { Self.reason }
    public func present() -> String? { Self.reason }
    public var gameWindow: UIWindow? { nil }
}

/// The engine's shell side, in Swift: the order of `dm_shell_start_game` and `dm_shell_present_game` in
/// `ShellMain.m`, so a report from this app reads like one from the engine's shell.
///
/// One game per process: the framework's host reads its profile and starts loading once, and a loaded framework is
/// never unloaded, so going back to the library is a new launch of the app.
@MainActor
public final class FrameworkEngineHost: EngineHost {
    public static let shared = FrameworkEngineHost()

    /// `DM_GLUE_VERSION` in `ShellGlue.h`: a framework built for another version is refused, not guessed at.
    public static let glueVersion: Int32 = 1

    typealias StartFunction = @convention(c) (UnsafePointer<UnsafePointer<CChar>?>?, Int32, UnsafeRawPointer?) -> UnsafePointer<CChar>?
    typealias PresentFunction = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias FocusFunction = @convention(c) (Int32) -> Void

    /// The framework's entry points, found by dlsym on its handle.
    struct Glue {
        var imageBase: UnsafeRawPointer
        var start: StartFunction
        var present: PresentFunction
        var focus: FocusFunction
    }

    private var started = false
    private var glue: Glue?
    private var window: UIWindow?
    private var observers: [NSObjectProtocol] = []

    public nonisolated init() {}

    public var isAvailable: Bool { true }

    public var gameWindow: UIWindow? { glue == nil ? nil : window }

    /// Refuses a second start: the framework's host starts once per process. `started` is set only when the game's
    /// own start is called, so a start refused before that (a missing symbol, a framework of another glue version)
    /// can be followed by another one.
    public func start(_ plan: EngineLaunchPlan) throws -> String? {
        guard !started else { return "A game was already started in this session. Close the app and open it again." }
        guard plan.arguments.count >= 2 else { return "The game's start arguments are incomplete." }
        Self.logTo(plan.logURL)
        fputs("\(Self.appLine)\n", stderr)
        fputs("shell: starting \(plan.arguments[1]) (\(plan.frameworkExecutable.path))\n", stderr)
        for (key, value) in plan.environment.sorted(by: { $0.key < $1.key }) {
            setenv(key, value, 1)
            fputs("boot: \(key)=\(value)\n", stderr)   // every one: a report shows which settings reached the engine
        }
        chdir(plan.workingDirectory.path)
        let glue: Glue
        switch Self.resolve(executable: plan.frameworkExecutable.path, marker: plan.imageMarker) {
        case .failure(let error):
            fputs("[RED] boot: \(plan.frameworkExecutable.path): \(error.message)\n", stderr)
            return error.message
        case .success(let found):
            glue = found
        }
        fputs("boot: game framework \(plan.frameworkExecutable.path) (image base \(glue.imageBase), glue v\(Self.glueVersion))\n", stderr)
        started = true
        let failure = Self.withCStrings(plan.arguments) { glue.start($0, Int32(plan.arguments.count), glue.imageBase) }
        if let failure {
            let message = String(cString: failure)
            fputs("[RED] boot: \(plan.frameworkExecutable.path): \(message)\n", stderr)
            return message
        }
        self.glue = glue
        forwardFocusEvents(to: glue.focus)
        return nil
    }

    /// A window of the app's own scene for the game's view: the framework makes its root view controller the
    /// game's and asks for landscape (`dm_glue_present_game`). It is a new window above the library's, so SwiftUI's
    /// own window is never taken from it.
    public func present() -> String? {
        guard let glue else { return "The game was not started." }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            fputs("[RED] shell: no window for the game view\n", stderr)
            return "There is no window to show the game in."
        }
        let window = UIWindow(windowScene: scene)
        window.backgroundColor = .black
        self.window = window
        window.makeKeyAndVisible()
        glue.present(Unmanaged.passUnretained(window).toOpaque())
        return nil
    }

    /// The scene's changes, as `ShellMain.m`'s scene delegate forwards them to the game (`front_ios_focus_event`):
    /// 0 resigns active, 1 enters the background, 2 comes back to the foreground, 3 becomes active.
    private func forwardFocusEvents(to focus: @escaping FocusFunction) {
        let events: [(Notification.Name, Int32)] = [
            (UIScene.willDeactivateNotification, 0), (UIScene.didEnterBackgroundNotification, 1),
            (UIScene.willEnterForegroundNotification, 2), (UIScene.didActivateNotification, 3),
        ]
        observers = events.map { name, event in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in focus(event) }
        }
    }

    // MARK: - The parts that do not touch the process

    /// Loads the framework and finds what the shell needs in it: the marker that proves it is the game's code (its
    /// image base comes from there, as dladdr on the handle itself finds nothing), and the four glue entry points.
    static func resolve(executable: String, marker: String) -> Result<Glue, GlueError> {
        guard let handle = dlopen(executable, RTLD_LAZY | RTLD_LOCAL) else {
            let reason = dlerror().map { String(cString: $0) } ?? "no reason given"
            FrameworkLoader.lastDlerror = reason
            return .failure(GlueError("The game's code could not be loaded: \(reason)"))
        }
        dlerror()
        var info = Dl_info()
        guard let symbol = dlsym(handle, marker), dladdr(symbol, &info) != 0, let base = info.dli_fbase else {
            return .failure(GlueError("The game's code is damaged (no \(marker) symbol). Install the game again."))
        }
        // Every game exports the same marker, so finding it proves only that some game's code answered: the image
        // it lies in has to be the file this start names.
        guard let file = info.dli_fname,
              URL(fileURLWithPath: String(cString: file)).resolvingSymlinksInPath() == URL(fileURLWithPath: executable).resolvingSymlinksInPath() else {
            return .failure(GlueError("dyld answered with another game's code, not \(executable)."))
        }
        let version = dlsym(handle, "dm_glue_version")?.assumingMemoryBound(to: Int32.self).pointee
        guard version == glueVersion,
              let start = dlsym(handle, "dm_glue_start_game"),
              let present = dlsym(handle, "dm_glue_present_game"),
              let focus = dlsym(handle, "dm_glue_focus_event") else {
            return .failure(GlueError("This game's framework was built without its host (glue version \(version ?? 0), "
                                      + "expected \(glueVersion)). Rebuild the game on the Mac."))
        }
        return .success(Glue(imageBase: UnsafeRawPointer(base),
                             start: unsafeBitCast(start, to: StartFunction.self),
                             present: unsafeBitCast(present, to: PresentFunction.self),
                             focus: unsafeBitCast(focus, to: FocusFunction.self)))
    }

    struct GlueError: Error, Equatable {
        var message: String
        init(_ message: String) { self.message = message }
    }

    /// The host writes only to stderr: it goes to this start's own log, `Documents/logs/<title ID>/<date>.txt`
    /// (`GameLogs`), beside the game's earlier ones.
    static func logTo(_ log: URL) {
        GameLogs.prepare(for: log)
        fflush(stderr)
        if freopen(log.path, "w", stderr) != nil { setvbuf(stderr, nil, _IOLBF, 0) }
    }

    /// The log's first line: which app wrote it and on what, so a log shared on its own still says.
    static var appLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "shell: NXPocket \(version) (\(build)), iOS \(UIDevice.current.systemVersion), \(Date().formatted(.iso8601))"
    }

    /// Metal reads `MTL_HUD_ENABLED` when the process makes its first device, long before a game starts, so the HUD
    /// is readied for every launch and each game's own Performance HUD setting decides at Play (`front_ios.m`, with
    /// `DM_HUD_PER_LAYER`). The engine's shell does this before `UIApplicationMain`; a value given at launch wins.
    public nonisolated static func prepareProcess() {
        _ = LaunchEnvironment.values   // before DM_HUD_PER_LAYER below, which the launch did not set
        guard getenv("MTL_HUD_ENABLED") == nil else { return }
        setenv("MTL_HUD_ENABLED", "1", 1)
        setenv("DM_HUD_PER_LAYER", "1", 1)
    }

    /// `strdup`ed copies for the C call, freed after it: the framework copies what it keeps.
    static func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
        let copies: [UnsafePointer<CChar>?] = strings.map { UnsafePointer(strdup($0)) } + [nil]
        defer { copies.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        return copies.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
