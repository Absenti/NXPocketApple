import Foundation
import NXPocketKit

/// The built games as a folder any web server can serve (`WebSource`): `index.json`, a folder per game with its files and a `files.json`,
/// and the icons. Put it behind an https address only the player knows, or behind a token, and an iPhone can add it as a *Web link*
/// source: no FTP, no program on the server, only GET and `Range`.
///
/// What is exported is what the sharing server would serve (`SharedLibrary`'s allow-list): the files the package lists, the image, the
/// list of its blocks and the add-on content, never a key, a log, a save or a file the package does not name. On the volume of the built
/// games a copy is a clone and costs no space. A game's folder is replaced only once its new copy is whole.
public enum WebExport {
    public struct Report: Equatable, Sendable {
        public var games: Int
        public var bytes: Int64
    }

    public static func export(from builtFolder: URL, to destination: URL, fileManager: FileManager = .default,
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) throws -> Report {
        let library = SharedLibrary(folder: builtFolder, cacheLife: 0)
        let games = library.games()
        guard !games.isEmpty else { throw NXPocketError(.packageMissing, "there is no built game to export") }
        try fileManager.createDirectory(at: destination.appendingPathComponent("icons"), withIntermediateDirectories: true)
        let total = max(games.reduce(Int64(0)) { $0 + $1.files.values.reduce(0, +) }, 1)
        var done: Int64 = 0
        var bytes: Int64 = 0
        for game in games {
            let staging = destination.appendingPathComponent(".export-\(UUID().uuidString)", isDirectory: true)
            defer { try? fileManager.removeItem(at: staging) }
            let folder = staging.appendingPathComponent("\(game.titleID).nxgame", isDirectory: true)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            // `package.json` goes last, so a folder that is cut short never reads as a game.
            let order = game.files.keys.sorted { ($0 == GamePackage.fileName ? 1 : 0, $0) < ($1 == GamePackage.fileName ? 1 : 0, $1) }
            for path in order {
                guard SafePath.isSafeRelative(path) else { continue }
                let target = folder.appendingPathComponent(path)
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: game.root.appendingPathComponent(path), to: target)
                let size = game.files[path] ?? 0
                done += size
                bytes += size
                progress(min(Double(done) / Double(total), 0.99))
                if Task.isCancelled { throw NXPocketError(.cancelled, "stopped") }
            }
            let listing = RemotePackageListing(revision: game.revision, files: game.files.map { RemotePackageFile(path: $0.key, size: $0.value) }.sorted { $0.path < $1.path })
            try JSONEncoder().encode(listing).write(to: folder.appendingPathComponent("files.json"))
            let final = destination.appendingPathComponent("\(game.titleID).nxgame", isDirectory: true)
            try? fileManager.removeItem(at: final)
            try fileManager.moveItem(at: folder, to: final)
            if let icon = game.iconPath, let data = BoundedRead.dataIfPresent(at: game.root.appendingPathComponent(icon), limit: Int64(SharingLimits.iconBytes)),
               PNGHeader.isAcceptableIcon(data) {
                try data.write(to: destination.appendingPathComponent("icons/\(game.titleID).png"), options: .atomic)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(RemoteListing(games: games.map { $0.remote(busy: false) })).write(to: destination.appendingPathComponent("index.json"), options: .atomic)
        progress(1)
        return Report(games: games.count, bytes: bytes)
    }
}
