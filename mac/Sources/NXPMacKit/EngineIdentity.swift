import Foundation

/// Which engine is on the disk, to notice that it was replaced while a build was running.
///
/// A build is several processes one after the other, and the engine's own tree is read again at each: a Python process
/// that began with one engine goes on compiling shaders for an hour while another tool (the NX2Apple app updating its
/// engine, `engine.py sync` in a terminal) swaps the files under it. The next stage then looks for shaders under the new
/// engine's name, the "chain" its source expects, and fails with "no iOS shader libraries": after the hour, and with no
/// word of why. Each engine version has its own chain, so what the first one compiled is of no use to the second.
public enum EngineIdentity: Equatable, Sendable {
    /// The stamp `engine.py sync` leaves in `engine/.git` (the pin and the digest of every patch).
    case stamp(String)
    /// An engine tree made some other way: when its build script last changed.
    case modified(Date)
    case unknown

    public static func read(_ engine: URL, fileManager: FileManager = .default) -> EngineIdentity {
        let stamp = engine.appendingPathComponent(".git/nx2apple-stamp")
        if let data = BoundedRead(at: stamp), let text = String(data: data, encoding: .utf8), !text.isEmpty { return .stamp(text) }
        let script = engine.appendingPathComponent("scripts/build_ipa_from_nsp.py")
        if let date = (try? fileManager.attributesOfItem(atPath: script.path))?[.modificationDate] as? Date { return .modified(date) }
        return .unknown
    }

    /// The pin the stamp names (`pin <sha>`), shortened.
    public var pin: String? {
        guard case .stamp(let text) = self else { return nil }
        return text.split(separator: "\n").first { $0.hasPrefix("pin ") }.map { String($0.dropFirst(4).prefix(8)) }
    }

    /// What to tell the user when the engine at the end of a failed build is not the one at its start; nil when it is
    /// the same, or when either could not be read (nothing is claimed then).
    public static func changeNote(from before: EngineIdentity, to after: EngineIdentity) -> String? {
        guard before != after, before != .unknown, after != .unknown else { return nil }
        let names: String
        if let old = before.pin, let new = after.pin, old != new {
            names = "from nxnative \(old) to \(new)"
        } else {
            names = "while it ran"
        }
        return "the engine on this Mac was replaced \(names) during the build. Each engine version compiles its shaders under "
            + "its own name, so the stage that failed could not find what the earlier ones had made: start the build again "
            + "with the engine as it is now (the shaders are compiled again), or put the engine back as it was."
    }
}

private func BoundedRead(at url: URL) -> Data? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    return try? handle.read(upToCount: 4096)
}
