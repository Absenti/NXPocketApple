import CryptoKit
import Foundation
import ImageIO
import NXPocketKit
import UIKit

/// `nxpocket://play/<title ID>`: what a game's icon on the home screen opens (a web clip that a profile installs,
/// `ShortcutProfile`). Anything else under the scheme is ignored.
public enum GameLink {
    public static let scheme = "nxpocket"
    static let action = "play"

    /// The game a link asks to play: 16 hex digits naming an application, and nothing more in the link.
    public static func titleID(from url: URL) -> TitleID? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == action,
              url.query == nil, url.fragment == nil, url.user == nil, url.password == nil, url.port == nil else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 1, parts[0].utf8.count == 16, parts[0].utf8.allSatisfy(isHexDigit),
              let titleID = TitleID(String(parts[0])), titleID.kind == .application else { return nil }
        return titleID
    }

    public static func url(for titleID: TitleID) -> URL {
        URL(string: "\(scheme)://\(action)/\(titleID.description)")!
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }
}

/// `Documents/.next-launch`: the game to start at the next launch. The engine starts once per process, so opening
/// another game while one runs means quitting; this file carries the request over. It holds for two minutes: an older
/// one is no longer what the player asked for. It is read once and deleted whatever it says.
public enum NextLaunch {
    public static let fileName = ".next-launch"
    public static let validity: TimeInterval = 120

    public static func url(documents: URL) -> URL { documents.appendingPathComponent(fileName) }

    public static func write(_ titleID: TitleID, documents: URL, now: Date = Date()) throws {
        let object: [String: Any] = ["title_id": titleID.description, "written": ISO8601DateFormatter().string(from: now)]
        try JSONSerialization.data(withJSONObject: object).write(to: url(documents: documents), options: .atomic)
    }

    public static func take(documents: URL, now: Date = Date(), fileManager: FileManager = .default) -> TitleID? {
        let url = url(documents: documents)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        defer { try? fileManager.removeItem(at: url) }
        guard let data = BoundedRead.dataIfPresent(at: url, limit: 4096, fileManager: fileManager),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["title_id"] as? String, let titleID = TitleID(text), titleID.kind == .application,
              let stamp = object["written"] as? String, let written = ISO8601DateFormatter().date(from: stamp) else { return nil }
        let age = now.timeIntervalSince(written)
        // A few seconds in the future is a clock that moved, not a request from tomorrow.
        guard age >= -5, age <= validity else { return nil }
        return titleID
    }
}

/// A configuration profile with one web clip: the game's icon on the home screen, opening `nxpocket://play/<title ID>`.
/// iOS has no API that lets an app put an icon there; a profile the player installs in Settings does. Its identifiers
/// come from the title ID, so installing it again replaces the earlier one rather than adding a second icon.
public enum ShortcutProfile {
    public static let folderName = "Shortcuts"
    static let iconSide = 180

    public struct Texts {
        public var label: String
        public var displayName: String
        public var description: String

        public init(label: String, displayName: String, description: String) {
            self.label = label
            self.displayName = displayName
            self.description = description
        }
    }

    public static func data(titleID: TitleID, texts: Texts, icon: Data?) throws -> Data {
        let id = titleID.description
        var clip: [String: Any] = [
            "PayloadType": "com.apple.webClip.managed", "PayloadVersion": 1,
            "PayloadIdentifier": "dev.nxpocketapple.shortcut.\(id).webclip", "PayloadUUID": uuid("webclip.\(id)"),
            "PayloadDisplayName": texts.label, "Label": texts.label, "URL": GameLink.url(for: titleID).absoluteString,
            "IsRemovable": true, "FullScreen": false, "Precomposed": true,
        ]
        if let icon { clip["Icon"] = icon }
        let profile: [String: Any] = [
            "PayloadType": "Configuration", "PayloadVersion": 1,
            "PayloadIdentifier": "dev.nxpocketapple.shortcut.\(id)", "PayloadUUID": uuid("profile.\(id)"),
            "PayloadDisplayName": texts.displayName, "PayloadOrganization": "NXPocketApple",
            "PayloadDescription": texts.description, "PayloadRemovalDisallowed": false,
            "PayloadContent": [clip],
        ]
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }

    /// `Documents/Shortcuts/<name>.mobileconfig`, where Files shows it.
    public static func write(_ game: InstalledGame, texts: Texts, documents: URL,
                             fileManager: FileManager = .default) throws -> URL {
        let folder = documents.appendingPathComponent(folderName, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(GameSaves.safeFileName(texts.label)).mobileconfig")
        let icon = iconPNG(from: GameArtwork.iconURL(for: game)) ?? iconPNG(from: nil)
        try data(titleID: game.titleID, texts: texts, icon: icon).write(to: url, options: .atomic)
        return url
    }

    /// A name-based UUID (version 5 layout over SHA-256): the same seed always gives the same UUID.
    static func uuid(_ seed: String) -> String {
        var bytes = Array(SHA256.hash(data: Data("dev.nxpocket.\(seed)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
        return parts.map(String.init).joined(separator: "-")
    }

    /// The game's icon as a 180 × 180 PNG, filling the square; the app's logo when the game has none, and a controller
    /// drawn on the app's colours when even that is missing (a test bundle has no asset catalog).
    static func iconPNG(from url: URL?) -> Data? {
        let source = url.flatMap { GameArtwork.thumbnail(at: $0, maxPixels: iconSide * 2) } ?? UIImage(named: "Logo")?.cgImage
        let side = CGFloat(iconSide)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            UIColor(red: 0.145, green: 0.145, blue: 0.170, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            if let source {
                let width = CGFloat(source.width), height = CGFloat(source.height)
                let scale = max(side / width, side / height)
                let drawn = CGSize(width: width * scale, height: height * scale)
                UIImage(cgImage: source).draw(in: CGRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2,
                                                         width: drawn.width, height: drawn.height))
            } else if let symbol = UIImage(systemName: "gamecontroller.fill",
                                           withConfiguration: UIImage.SymbolConfiguration(pointSize: 72, weight: .semibold))?
                .withTintColor(UIColor(red: 0.937, green: 0.694, blue: 0.353, alpha: 1), renderingMode: .alwaysOriginal) {
                symbol.draw(at: CGPoint(x: (side - symbol.size.width) / 2, y: (side - symbol.size.height) / 2))
            }
        }
        return image.pngData()
    }
}
