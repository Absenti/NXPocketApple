import Foundation

/// How fast a download goes and how long it has left, from the bytes it reported lately. A speed averaged since the start would
/// lag behind a Wi-Fi that changed, and after a resume (which starts above zero) it would be wrong from the first second, so only
/// the last few seconds count.
public struct TransferSpeed: Equatable, Sendable {
    struct Sample: Equatable, Sendable {
        var time: Date
        var bytes: Int64
    }

    /// How far back the average looks.
    public static let window: TimeInterval = 8
    private var samples: [Sample] = []

    public init() {}

    public mutating func add(bytes: Int64, at time: Date = Date()) {
        // A count that went down is a new start (a retried file): the old samples say nothing about it.
        if let last = samples.last, bytes < last.bytes { samples = [] }
        samples.append(Sample(time: time, bytes: bytes))
        while samples.count > 2, time.timeIntervalSince(samples[0].time) > Self.window { samples.removeFirst() }
    }

    public mutating func reset() { samples = [] }

    /// Zero until there is a second of data to average.
    public var bytesPerSecond: Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        let seconds = last.time.timeIntervalSince(first.time)
        guard seconds >= 1, last.bytes > first.bytes else { return 0 }
        return Double(last.bytes - first.bytes) / seconds
    }

    /// Nil while the speed is not known.
    public func secondsLeft(bytesLeft: Int64) -> TimeInterval? {
        let speed = bytesPerSecond
        guard speed > 0, bytesLeft >= 0 else { return nil }
        return Double(bytesLeft) / speed
    }

    /// "45 s left", "6 min left", "1 h 12 min left".
    public static func leftText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        if total < 60 { return "\(max(total, 1)) s left" }
        if total < 3600 { return "\((total + 30) / 60) min left" }
        let minutes = ((total + 30) / 60) % 60
        let hours = (total + 30) / 3600
        return minutes == 0 ? "\(hours) h left" : "\(hours) h \(minutes) min left"
    }
}
