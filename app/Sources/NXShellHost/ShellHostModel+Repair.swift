import Foundation
import NXPocketKit

public enum RepairState: Equatable {
    case idle
    case scanning(Double)
    case clean
    case found(bad: Int, total: Int)
    case repairing(Double)
    case done(Int)
    /// The game has no list of blocks (installed before they existed), or its list is damaged.
    case unavailable
    case failed(String)
}

/// Checking an installed game's image against its list of blocks, and repairing the blocks that are wrong from a source.
extension ShellHostModel {
    public func verify(_ game: InstalledGame) {
        guard let package = game.package, !repairBusy else { return }
        repairState = .scanning(0)
        let directory = game.directory
        Task {
            do {
                let scan = try await Task.detached(priority: .userInitiated) {
                    try GameRepair.scan(directory: directory, package: package) { fraction in
                        Task { @MainActor in if case .scanning = self.repairState { self.repairState = .scanning(fraction) } }
                    }
                }.value
                self.repairScan = scan
                self.repairState = scan.isClean ? .clean : .found(bad: scan.badBlocks.count, total: scan.blockCount)
                self.log.append("checked the data of \(game.titleID): \(scan.badBlocks.count) of \(scan.blockCount) blocks are wrong")
            } catch is GameRepair.Unavailable {
                self.repairState = .unavailable
            } catch {
                self.repairState = .failed(self.message(for: error))
            }
        }
    }

    /// The sources that offer this game, for a repair: the image they hold is checked against the game's own list before a block
    /// is taken from them.
    public func repairSources(for game: InstalledGame) -> [NetworkSources.CloudEntry] {
        sources.enabled ? sources.offered.filter { $0.game.titleID == game.id } : []
    }

    public func repair(_ game: InstalledGame, from entry: NetworkSources.CloudEntry) {
        guard let package = game.package, let scan = repairScan, let source = sources.source(for: entry.record), !repairBusy else { return }
        repairState = .repairing(0)
        let directory = game.directory
        Task {
            do {
                let fixed = try await GameRepair.repair(directory: directory, package: package, scan: scan, from: source) { fraction in
                    Task { @MainActor in if case .repairing = self.repairState { self.repairState = .repairing(fraction) } }
                }
                self.repairScan = nil
                self.repairState = .done(fixed)
                self.log.append("repaired \(fixed) blocks of \(game.titleID) from \(entry.record.name)")
            } catch {
                self.repairState = .failed(self.message(for: error))
                self.log.append("repair of \(game.titleID) from \(entry.record.name) failed: \(error)")
            }
        }
    }

    public var repairBusy: Bool {
        switch repairState {
        case .scanning, .repairing: return true
        default: return false
        }
    }

    public func dismissRepair() {
        guard !repairBusy else { return }
        repairState = .idle
        repairScan = nil
    }
}
