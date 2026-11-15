import Foundation
import NXPocketKit
import UIKit

/// The time spent in the game on screen, kept beside its settings in `Documents/settings/<title ID>.json`, outside the
/// game's folder, so an update of the game keeps it. It counts from the moment the game's view is shown until the app
/// goes to the background or quits, and starts again when it comes back. A checkpoint every minute adds the time since
/// the last one to the file: a kill, or the `exit(0)` of a switch to another game, loses at most a minute.
@MainActor
final class PlayClock {
    static let checkpointInterval: TimeInterval = 60

    let titleID: String
    let documents: URL
    private(set) var countingSince: Date?
    private var timer: Timer?
    private var sampler: Timer?
    private var counted = false
    private var frames: Int64 = 0
    private var drawingSeconds = 0
    private var recorder = SessionRecorder()
    private var observers: [NSObjectProtocol] = []

    init(titleID: String, documents: URL) {
        self.titleID = titleID
        self.documents = documents
    }

    func resume(now: Date = Date()) {
        guard countingSince == nil else { return }
        countingSince = now
        if !counted {
            counted = true
            var choices = GameChoices.load(titleID: titleID, documents: documents)
            choices.sessions += 1
            try? choices.save(titleID: titleID, documents: documents)
        }
        _ = FrameCounter.take()   // what was drawn before this moment is not this stretch's
        UIDevice.current.isBatteryMonitoringEnabled = true
        sampler = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkpointInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkpoint() }
        }
    }

    func pause(now: Date = Date()) {
        checkpoint(now: now)
        countingSince = nil
        timer?.invalidate()
        timer = nil
        sampler?.invalidate()
        sampler = nil
    }

    /// One second of the game: the frames it drew, counted only when there were some.
    func sample() {
        let drawn = FrameCounter.take()
        let level = UIDevice.current.batteryLevel
        recorder.feed(frames: drawn, thermal: ProcessInfo.processInfo.thermalState.rawValue, battery: level >= 0 ? Double(level) : nil)
        guard drawn > 0 else { return }
        frames += drawn
        drawingSeconds += 1
    }

    /// Adds the time since the last checkpoint to the file, and the game's last-played date.
    func checkpoint(now: Date = Date()) {
        guard let since = countingSince else { return }
        countingSince = now
        let seconds = max(0, now.timeIntervalSince(since))
        var choices = GameChoices.load(titleID: titleID, documents: documents)
        choices.playSeconds += Int(seconds.rounded())
        choices.lastPlayed = now
        choices.fpsFrames += frames
        choices.fpsSeconds += drawingSeconds
        recorder.report.save(titleID: titleID, documents: documents)
        frames = 0
        drawingSeconds = 0
        try? choices.save(titleID: titleID, documents: documents)
    }

    /// The game is not played while the app is in the background.
    func followScene() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pause() }
            },
            center.addObserver(forName: UIScene.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            },
        ]
    }
}
