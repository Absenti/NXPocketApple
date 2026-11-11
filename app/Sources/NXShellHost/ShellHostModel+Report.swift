import Foundation
import NXPocketKit
import NXShellUI
import UIKit

/// The report "Copy the report" puts on the pasteboard under a state that went wrong: enough to diagnose it away from
/// the phone, and nothing secret (no .p12, no password, no key). It never leaves the phone by itself.
extension ShellHostModel {
    public static let reportLogLines = 200

    /// `error` as the screen showed it; the game's last log when `titleID` names one, the app's log when `appLog`.
    public func report(error: String, titleID: String? = nil, appLog: Bool = false, now: Date = Date()) -> String {
        var lines = ["NXPocket report, \(now.formatted(.iso8601))", "", "error: \(error)"]
        if let dlerror = FrameworkLoader.lastDlerror { lines.append("dlerror: \(dlerror)") }

        if let titleID {
            lines.append("")
            lines.append("game: \(title(ofTitleID: titleID)) (\(titleID))")
            if let game = games.first(where: { $0.id == titleID }) {
                lines.append("version: \(game.version.isEmpty ? "unknown" : game.version), chain \(game.chain ?? "unknown")")
                lines.append("size on disk: \(game.byteCount) bytes")
                if let problem = game.problem { lines.append("damaged: \(problem.code.rawValue): \(problem.detail)") }
                if let signing = game.signing {
                    lines.append("signed: certificate \(signing.certificateSHA256), \(signing.identifier), team \(signing.teamID), "
                                 + "expires \(signing.expires.formatted(.iso8601))")
                } else {
                    lines.append("signed: no")
                }
            } else {
                lines.append("not in the library")
            }
        }

        lines.append("")
        let info = Bundle.main.infoDictionary
        lines.append("app: NXPocket \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))")
        lines.append("iOS \(UIDevice.current.systemVersion), \(Self.deviceModel)")
        lines.append("memory: \(MemoryBudget.availableText) available of \(MemoryBudget.physicalText), "
                     + "increased limit \(MemoryBudget.hasIncreasedLimit ? "yes" : "no")")
        if let certificate {
            lines.append("certificate: SHA-256 \(certificate.sha256), team \(certificate.teamID), "
                         + "expires \(certificate.expires.formatted(.iso8601))")
        } else if let certificateProblem {
            lines.append("certificate: unreadable: \(certificateProblem)")
        } else {
            lines.append("certificate: none")
        }
        lines += SigningFacts.current.lines

        let log = titleID.flatMap { GameLogs.latest(titleID: $0, documents: documents) }
            ?? (appLog ? GameLogs.appLog(documents: documents) : nil)
        if let log {
            let tail = Self.lastLines(GameLogs.text(of: log, limit: 256 << 10).text, Self.reportLogLines)
            lines.append("")
            lines.append("log \(log.titleID.map { "\($0)/" } ?? "")\(log.url.lastPathComponent), last \(tail.count) lines:")
            lines += tail
        }
        return lines.joined(separator: "\n")
    }

    static func lastLines(_ text: String, _ count: Int) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last?.isEmpty == true { lines.removeLast() }
        return Array(lines.suffix(count))
    }

    /// The hardware model, "iPhone16,1": what tells two iPhones apart in a report.
    static let deviceModel: String = {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }()

    // MARK: - Play time

    /// "3 h 12 min" and the day the game was last played, in the player's language; nil before the first game.
    public func playTime(of game: InstalledGame) -> (total: String, last: String)? {
        let choices = GameChoices.load(titleID: game.id, documents: documents)
        guard let last = choices.lastPlayed else { return nil }
        let locale = Locale(identifier: language)
        let total: String
        if choices.playSeconds < 60 {
            total = text(.underAMinute)
        } else {
            let formatter = DateComponentsFormatter()
            var calendar = Calendar.current
            calendar.locale = locale
            formatter.calendar = calendar
            formatter.allowedUnits = choices.playSeconds >= 3600 ? [.hour, .minute] : [.minute]
            formatter.unitsStyle = .abbreviated
            total = formatter.string(from: TimeInterval(choices.playSeconds)) ?? "\(choices.playSeconds / 60) min"
        }
        return (total, last.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)))
    }
}
