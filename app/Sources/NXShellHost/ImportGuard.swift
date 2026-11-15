import Foundation
import os
import NXPocketKit

/// A transfer waiting to be imported, as the Transfers screen lists it.
public struct PendingImport: Identifiable, Equatable, Sendable {
    public var name: String
    public var title: String?
    public var bytes: Int64
    /// The app stopped while importing it, the last time it was tried.
    public var interrupted: Bool
    public var id: String { name }
}

/// Which transfer the app was importing when it last stopped. An import writes the folder's name here before it starts and
/// removes it when it ends, however it ends; a name still there at the next launch is an import the app did not survive. That
/// transfer is not imported by itself again (the app would stop at every launch, with no way to reach the screen that could
/// delete it): it waits for the player, who can try it again or delete it.
public enum ImportGuard {
    static func url(in documents: URL) -> URL { documents.appendingPathComponent(".import-attempt") }

    public static func begin(_ folder: String, in documents: URL) {
        try? Data(folder.utf8).write(to: url(in: documents), options: .atomic)
    }

    public static func end(in documents: URL) {
        try? FileManager.default.removeItem(at: url(in: documents))
    }

    /// The transfer the app did not survive, if there is one.
    public static func interrupted(in documents: URL) -> String? {
        BoundedRead.dataIfPresent(at: url(in: documents), limit: 1024).flatMap { String(data: $0, encoding: .utf8) }
            .flatMap { SafePath.isSafeComponent($0) ? $0 : nil }
    }
}

/// Turns the importer's progress into a line of the import log every few seconds, with the memory the app has left.
final class ImportProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private var lastStage = ""

    func line(_ progress: ImportService.Progress) -> String? {
        let now = Date()
        let stage = progress.stage.rawValue
        let due = lock.withLock { () -> Bool in
            guard now.timeIntervalSince(last) >= 3 || stage != lastStage else { return false }
            last = now
            lastStage = stage
            return true
        }
        guard due else { return nil }
        let free = Int(os_proc_available_memory() / (1 << 20))
        return "import: \(stage) \(Int(progress.fraction * 100))% \(progress.detail.prefix(80)) (\(free) MB of memory left)"
    }
}
