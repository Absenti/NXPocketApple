import Foundation
import NXPMacKit

/// One piece of work in the queue: a game to build (and send), or a built package to send.
public struct QueueItem: Identifiable, Equatable {
    public enum Job: Equatable {
        /// `sendTo` is the iPhone's UDID when the package goes to it right after the build.
        case build(BuildPlan, sendTo: String?)
        case send(package: URL, to: String)
    }

    public enum Phase: Equatable {
        case waiting
        /// `stageFraction` is nil while the stage has no count; `overall` is the whole build's (`BuildProgress`).
        case building(stage: String, stageFraction: Double?, overall: Double, detail: String)
        case packing(fraction: Double, detail: String)
        case sending(fraction: Double, detail: String)
        /// Stopped until the user answers: the saves could not be backed up before the send (`AppModel.answer`).
        case needsAnswer(String)
        case done(String)
        case failed(String)
        case cancelled

        public var isFinished: Bool {
            switch self {
            case .done, .failed, .cancelled: return true
            default: return false
            }
        }

        public var isActive: Bool { !isFinished && self != .waiting }
    }

    public let id: UUID
    public var titleID: String
    public var name: String
    public var job: Job
    public var phase: Phase = .waiting
    public var deviceName: String?

    public init(id: UUID = UUID(), titleID: String, name: String, job: Job, deviceName: String? = nil) {
        self.id = id
        self.titleID = titleID
        self.name = name
        self.job = job
        self.deviceName = deviceName
    }

    public var builds: Bool { if case .build = job { return true }; return false }
    public var sends: Bool {
        switch job {
        case .build(_, let device): return device != nil
        case .send: return true
        }
    }

    /// The share of the item's whole work that is done. A build is most of it; a send of several gigabytes still
    /// takes minutes, so it keeps a share of its own.
    public var fraction: Double {
        let buildShare = builds ? (sends ? 0.75 : 1.0) : 0
        let packShare = 0.1 * buildShare
        let compileShare = buildShare - packShare
        switch phase {
        case .waiting: return 0
        case .building(_, _, let overall, _): return compileShare * min(max(overall, 0), 1)
        case .packing(let fraction, _): return compileShare + packShare * min(max(fraction, 0), 1)
        case .sending(let fraction, _): return buildShare + (1 - buildShare) * min(max(fraction, 0), 1)
        case .needsAnswer: return buildShare
        case .done, .failed, .cancelled: return 1
        }
    }

    /// One line for the queue's row.
    public var status: String {
        switch phase {
        case .waiting: return builds ? (sends ? "waiting: build, then send" : "waiting: build") : "waiting: send"
        case .building(let stage, _, _, _): return "building · \(stage)"
        case .packing: return "packing"
        case .sending: return "sending to \(deviceName ?? "the iPhone")"
        case .needsAnswer(let question): return question
        case .done(let summary): return summary
        case .failed(let reason): return reason
        case .cancelled: return "cancelled"
        }
    }

    /// The bar under the status: the stage's for a build (when it has a count), the transfer's for a send.
    public var detail: (fraction: Double?, text: String)? {
        switch phase {
        case .building(_, let stage, _, let detail): return (stage, detail)
        case .packing(let fraction, let detail), .sending(let fraction, let detail): return (fraction, detail)
        default: return nil
        }
    }
}
