import Foundation
import NXPocketKit

/// A game the Mac is still sending into `Documents/.incoming/<uuid>/`: which game, once its `package.json` has landed (the
/// Mac sends the package's entries by name with `romfs.img` last, so it comes early), and how many bytes are there.
public struct IncomingTransfer: Equatable, Sendable, Identifiable {
    public var folder: URL
    public var title: String?
    public var received: Int64
    public var expected: Int64?

    public var id: String { folder.lastPathComponent }

    /// Nil until `package.json` says how big the package is.
    public var fraction: Double? {
        guard let expected, expected > 0 else { return nil }
        return Swift.min(1, Double(received) / Double(expected))
    }
}

public enum IncomingTransfers {
    /// The transfers still on their way: no `.complete` yet and not given up by the Mac (`.abandoned`). Measured from the
    /// files themselves: devicectl writes a copied file in place, so a growing `romfs.img` is the progress.
    public static func receiving(documents: URL, fileManager: FileManager = .default) -> [IncomingTransfer] {
        let root = GameLayout.incomingDirectory(in: documents)
        let names = ((try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        return names.compactMap { name in
            let folder = root.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  !fileManager.fileExists(atPath: folder.appendingPathComponent(GameLayout.completeMarker).path),
                  !fileManager.fileExists(atPath: folder.appendingPathComponent(GameLayout.abandonedMarker).path) else { return nil }
            let package = BoundedRead.dataIfPresent(at: folder.appendingPathComponent(GamePackage.fileName), fileManager: fileManager)
                .flatMap { try? GamePackage.decode($0) }
            return IncomingTransfer(folder: folder, title: package?.name, received: bytes(in: folder, fileManager: fileManager),
                                    expected: package?.totalSize)
        }
    }

    static func bytes(in folder: URL, fileManager: FileManager) -> Int64 {
        guard let walker = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }
}
