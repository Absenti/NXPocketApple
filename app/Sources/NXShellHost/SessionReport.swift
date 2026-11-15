import Foundation
import NXPocketKit

/// What the last session of a game was like: every thirty seconds, the frame rate it drew, how hot the phone was and how much
/// battery was left. Kept beside the game's other choices (`Documents/settings/<title ID>.session.json`, outside the game's folder, so an
/// update keeps it), only the last session, and only these three numbers: nothing of what was on screen.
struct SessionBucket: Codable, Equatable {
    /// Seconds since the session began, at the bucket's end.
    var t: Int
    /// Frames per second over the seconds in which something was drawn; nil for thirty seconds of nothing.
    var fps: Double?
    /// `ProcessInfo.ThermalState.rawValue`: 0 nominal, 1 fair, 2 serious, 3 critical. The worst in the bucket.
    var thermal: Int
    /// 0 to 1, nil when the phone does not say (battery monitoring off, a simulator).
    var battery: Double?
}

struct SessionReport: Codable, Equatable {
    static let bucketSeconds = 30
    /// Two hours: a longer session keeps its last two hours.
    static let maxBuckets = 240

    var started: Date
    var buckets: [SessionBucket] = []

    var averageFPS: Double? {
        let rates = buckets.compactMap(\.fps)
        return rates.isEmpty ? nil : rates.reduce(0, +) / Double(rates.count)
    }

    var worstThermal: Int { buckets.map(\.thermal).max() ?? 0 }

    /// Battery used, in points of a hundred, from the first bucket that knows to the last; nil when it never rose and fell.
    var batteryUsed: Double? {
        let levels = buckets.compactMap(\.battery)
        guard let first = levels.first, let last = levels.last, levels.count >= 2 else { return nil }
        return max(first - last, 0) * 100
    }

    static func url(titleID: String, documents: URL) -> URL {
        SettingsFolder.url(documents: documents).appendingPathComponent("\(titleID).session.json")
    }

    static func load(titleID: String, documents: URL, fileManager: FileManager = .default) -> SessionReport? {
        guard TitleID.isGame(titleID),
              let data = BoundedRead.dataIfPresent(at: url(titleID: titleID, documents: documents), limit: 1 << 20, fileManager: fileManager),
              let report = try? JSONDecoder().decode(SessionReport.self, from: data),
              report.buckets.count <= maxBuckets * 2 else { return nil }
        return report
    }

    func save(titleID: String, documents: URL, fileManager: FileManager = .default) {
        guard TitleID.isGame(titleID), let data = try? JSONEncoder().encode(self) else { return }
        try? fileManager.createDirectory(at: SettingsFolder.url(documents: documents), withIntermediateDirectories: true)
        try? data.write(to: Self.url(titleID: titleID, documents: documents), options: .atomic)
    }
}

/// Turns a stream of one-second samples into buckets. The clock gives it what it counted; nothing here reads the phone.
struct SessionRecorder {
    private(set) var report: SessionReport
    private var frames: Int64 = 0
    private var drawingSeconds = 0
    private var seconds = 0
    private var thermal = 0
    private var battery: Double?
    private var elapsed = 0

    init(started: Date = Date()) { report = SessionReport(started: started) }

    /// One second of the game: the frames it drew (0 when nothing), the phone's thermal state and battery level.
    mutating func feed(frames drawn: Int64, thermal state: Int, battery level: Double?) {
        if drawn > 0 { frames += drawn; drawingSeconds += 1 }
        thermal = max(thermal, state)
        if let level, level >= 0 { battery = level }
        seconds += 1
        elapsed += 1
        guard seconds >= SessionReport.bucketSeconds else { return }
        report.buckets.append(SessionBucket(t: elapsed, fps: drawingSeconds > 0 ? Double(frames) / Double(drawingSeconds) : nil,
                                            thermal: thermal, battery: battery))
        if report.buckets.count > SessionReport.maxBuckets { report.buckets.removeFirst(report.buckets.count - SessionReport.maxBuckets) }
        frames = 0; drawingSeconds = 0; seconds = 0; thermal = 0
    }
}
