import Foundation
import ObjectiveC
import QuartzCore
import os

/// How many frames the game draws. The engine draws in a view of its own, and the app is not told about a frame, so they are
/// counted where every frame of a Metal game passes: each one asks its `CAMetalLayer` for a drawable. The count is what the
/// game's frame rate is when it draws as often as it is allowed to, and it is a count, nothing else: no frame, pixel or name of
/// anything is read. Reading and resetting it is what `PlayClock` does once a second.
enum FrameCounter {
    private static let frames = OSAllocatedUnfairLock<Int64>(initialState: 0)
    private static let installed = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Wraps `CAMetalLayer.nextDrawable` once, before the game's first frame. Idempotent.
    static func install() {
        let first = installed.withLock { done -> Bool in
            defer { done = true }
            return !done
        }
        guard first else { return }
        let selector = NSSelectorFromString("nextDrawable")
        guard let method = class_getInstanceMethod(CAMetalLayer.self, selector) else { return }
        typealias Original = @convention(c) (AnyObject, Selector) -> AnyObject?
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (AnyObject) -> AnyObject? = { layer in
            let drawable = original(layer, selector)
            // A drawable that did not come (the layer is waiting for the display) is no frame.
            if drawable != nil { frames.withLock { $0 += 1 } }
            return drawable
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    /// The frames since the last call.
    static func take() -> Int64 { frames.withLock { value in defer { value = 0 }; return value } }

    /// Counts a frame by hand, for tests.
    static func record(_ count: Int64 = 1) { frames.withLock { $0 += count } }
}

/// What a game's sessions add up to, for the detail screen: the average rate over the seconds it was drawing.
struct PlayStats: Equatable {
    var sessions: Int
    var frames: Int64
    /// Seconds in which at least one frame was drawn: a loading screen that draws nothing does not pull the average down.
    var drawingSeconds: Int

    var averageFPS: Double? { drawingSeconds >= 10 ? Double(frames) / Double(drawingSeconds) : nil }
}
