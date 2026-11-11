import Foundation
import NXPMacKit
import NXPocketKit

/// The queue: games built one after another (the engine runs one build at a time: its tools, its work folders and
/// the Mac's cores are all taken by one), each sent to the iPhone right after its build when asked, and packages
/// sent on their own. One transfer at a time too: a second Send while the first was still copying used to put a
/// second 5 GB copy on the phone.
extension AppModel {
    public var queueIsRunning: Bool { queueTask != nil }
    public var queueHasWork: Bool { queue.contains { !$0.phase.isFinished } }

    /// The whole queue's share done: each item counts the same, finished ones (done, failed, cancelled) in full.
    public var queueFraction: Double {
        guard !queue.isEmpty else { return 0 }
        return queue.reduce(0) { $0 + $1.fraction } / Double(queue.count)
    }

    public var activeItem: QueueItem? { queue.first { $0.phase.isActive } }

    /// Why the ticked games cannot be queued yet, or nil.
    public var buildBlocker: String? {
        if let blocker = toolchainBlocker { return blocker }
        if checkedGames.isEmpty { return "Tick the games to build." }
        return nil
    }

    var toolchainBlocker: String? {
        if checkingToolchain { return "The engine, Python and Xcode are still being checked: try again in a moment." }
        if !toolchain.engine.isUsable { return "The engine is not synced. Run tools/bootstrap.sh, or set its folder in Settings." }
        return nil
    }

    /// Queues every ticked game of the folder, in the folder's order, then starts the queue.
    public func queueCheckedGames() {
        if let blocker = buildBlocker {
            append("queue: \(blocker)")
            return
        }
        let device = settings.value.sendAfterBuild ? selectedDevice : nil
        for game in folder.games where checkedGames.contains(game.titleID) {
            if queue.contains(where: { $0.titleID == game.titleID && !$0.phase.isFinished }) { continue }
            var item = QueueItem(titleID: game.titleID, name: displayName(titleID: game.titleID, own: game.name),
                                 job: .build(placeholderPlan(game), sendTo: nil),
                                 deviceName: device?.name)
            do {
                let plan = try game.plan(selection(for: game), workRoot: settings.value.workURL)
                if let blocker = pythonBlocker(compressed: plan.compressed) { throw NXPocketError(.engineMissing, blocker) }
                item.job = .build(plan, sendTo: device?.udid)
            } catch let error as NXPocketError {
                item.phase = .failed(error.detail)
            } catch {
                item.phase = .failed("\(error)")
            }
            queue.append(item)
        }
        checkedGames = []
        startQueue()
    }

    /// Queues a send of a package already built.
    public func queueSend(_ game: LocalGame, to device: Device) {
        guard game.isReady else {
            append("send: \(game.root.lastPathComponent) is not a complete package")
            return
        }
        if queue.contains(where: { !$0.phase.isFinished && $0.titleID == game.titleID && $0.sends }) { return }
        queue.append(QueueItem(titleID: game.titleID, name: game.title, job: .send(package: game.root, to: device.udid),
                               deviceName: device.name))
        startQueue()
    }

    /// Queues several packages, in the library's order: they go one after another.
    public func queueSend(_ games: [LocalGame], to device: Device) {
        for game in games { queueSend(game, to: device) }
    }

    /// Stops the item under way (the engine or devicectl is terminated) and every item still waiting.
    public func cancelQueue() {
        for index in queue.indices where queue[index].phase == .waiting { queue[index].phase = .cancelled }
        for item in queue where item.phase.isActive { cancelledItems.insert(item.id) }
        for id in Array(pendingAnswers.keys) { answer(id, sendAnyway: false) }
        if let runner {
            append("build: cancelling")
            runner.cancel()
        }
        transferControl?.cancel()
    }

    public func removeFromQueue(_ id: UUID) {
        queue.removeAll { $0.id == id && ($0.phase == .waiting || $0.phase.isFinished) }
    }

    public func clearFinishedQueueItems() {
        queue.removeAll { $0.phase.isFinished }
    }

    // MARK: - Running

    func startQueue() {
        guard queueTask == nil, queue.contains(where: { $0.phase == .waiting }) else { return }
        queueTask = Task { [model = self] in
            // The model lives as long as the app and this task publishes to it until the queue is empty: the capture
            // is deliberately strong.
            while let item = model.queue.first(where: { $0.phase == .waiting }) {
                await model.run(item)
                model.cancelledItems.remove(item.id)
            }
            model.queueTask = nil
            model.refreshLibrary()
            if model.queue.contains(where: { $0.sends && $0.phase.isFinished }) { model.refreshPhoneGames() }
        }
    }

    private func run(_ item: QueueItem) async {
        do {
            switch item.job {
            case .build(let plan, let device):
                let package = try await build(item.id, plan)
                if isCancelled(item.id) { throw NXPocketError(.cancelled, "cancelled after the build") }
                if let device {
                    try await send(item.id, package: package, to: device)
                    update(item.id) { $0.phase = .done("built and sent: open NXPocket on the iPhone to import it") }
                } else {
                    update(item.id) { $0.phase = .done("built \(plan.versionTag ?? "")") }
                }
            case .send(let package, let device):
                try await send(item.id, package: package, to: device)
                update(item.id) { $0.phase = .done("sent: open NXPocket on the iPhone to import it") }
            }
        } catch let error as NXPocketError where error.code == .cancelled {
            update(item.id) { $0.phase = .cancelled }
            if item.builds { append("\(item.name): \(error.detail)") }
        } catch let error as NXPocketError {
            append("\(item.name): \(error)")
            update(item.id) { $0.phase = .failed(error.detail) }
        } catch {
            append("\(item.name): \(error)")
            update(item.id) { $0.phase = .failed("\(error)") }
        }
    }

    func update(_ id: UUID, _ change: (inout QueueItem) -> Void) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        change(&queue[index])
    }

    private func isCancelled(_ id: UUID) -> Bool {
        cancelledItems.contains(id) || queue.first { $0.id == id }?.phase == .cancelled
    }

    /// One engine run, then the package: returns the `.nxgame` folder written.
    private func build(_ id: UUID, _ plan: BuildPlan) async throws -> URL {
        if let blocker = toolchainBlocker { throw NXPocketError(.engineMissing, blocker) }
        if let blocker = pythonBlocker(compressed: plan.compressed) { throw NXPocketError(.engineMissing, blocker) }
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("nxpocket-staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try await Task.detached(priority: .userInitiated) { try BuildInputs.prepare(plan) }.value

        // The title ID always goes: a merged cartridge dump can hold two games, and naming the one keeps the engine
        // from refusing the folder.
        let request = EngineBuildRequest(gameFolder: plan.inputFolder,
                                         keysFile: settings.value.keysURL,
                                         titleID: plan.titleID,
                                         packageVersion: plan.packageVersion,
                                         language: settings.value.language,
                                         keepExtracted: settings.value.keepExtracted,
                                         allowOtherMetal: settings.value.allowOtherMetal,
                                         stagingFolder: staging,
                                         workFolder: plan.workFolder,
                                         includesDLC: !plan.dlcTitleIDs.isEmpty)
        append("build: \(plan.name) [\(plan.titleID)] \(plan.versionTag ?? "")\(plan.dlcTitleIDs.isEmpty ? "" : " + \(plan.dlcTitleIDs.count) DLC")")
        for input in plan.inputs { append("  \(input.linkName)") }
        append("python: \(toolchain.python.path)")
        buildProgress = BuildProgress(detail: plan.name)
        lastEngineError = nil
        reportedRomfs = nil
        update(id) { $0.phase = .building(stage: "starting", stageFraction: nil, overall: 0, detail: plan.name) }

        // One stream, read by one task on the main actor: the engine's lines are handled in the order it wrote them,
        // and all of them before its reason or its `game files:` line is looked at. A task per line, as before,
        // left both to chance.
        let (events, sink) = AsyncStream.makeStream(of: EngineEvent.self)
        let reader = Task { @MainActor [model = self] in
            for await event in events { model.handle(event, for: id) }
        }
        let builder = EngineBuilder(toolchain: toolchain)
        let runner: ProcessRunner
        do {
            runner = try builder.start(request, onEvent: { sink.yield($0) }, onFinish: { _ in sink.finish() })
        } catch {
            sink.finish()
            throw error
        }
        self.runner = runner
        let result = await Task.detached { runner.waitUntilExit() }.value
        await reader.value
        self.runner = nil
        guard result.status == 0, !result.isCancelled else {
            throw result.isCancelled
                ? NXPocketError(.cancelled, "build cancelled")
                : NXPocketError(.engineFailed, lastEngineError ?? "the engine exited with \(result.status)")
        }

        let output = try builder.outputs(for: request, reportedRomfs: reportedRomfs)
        guard let titleID = TitleID(output.manifest.titleID) else {
            throw NXPocketError(.packageDamaged, "the engine's manifest has no title ID")
        }
        let outputFolder = settings.value.outputURL
        let destination = LocalLibrary.destination(for: titleID, in: outputFolder)
        update(id) { $0.phase = .packing(fraction: 0, detail: destination.lastPathComponent) }
        // Hashing the framework (up to a gigabyte with its shaders) and copying the RomFS image are off the main
        // thread: done on it, they held the window for as long.
        let packaged = try await Task.detached(priority: .userInitiated) { [model = self] in
            try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
            return try PackageWriter.write(framework: output.framework, romfsImage: output.romfsImage,
                                           aocFolder: output.aocFolder, into: destination) { progress in
                Task { @MainActor in
                    model.update(id) { $0.phase = .packing(fraction: progress.fraction, detail: progress.detail) }
                }
            }
        }.value
        // A game the user renamed keeps its name in every package built for it.
        if let custom = settings.value.gameNames[packaged.package.titleID], custom != packaged.package.name {
            _ = try await Task.detached(priority: .userInitiated) { try PackageRenamer.rename(packaged.root, to: custom) }.value
            append("named \(packaged.package.titleID) \(custom), as it was renamed")
        }
        refreshLibrary()
        append("packed \(packaged.package.titleID) \(packaged.manifest.name) \(packaged.package.packageVersion) — "
               + ByteCountFormatter.string(fromByteCount: packaged.package.totalSize, countStyle: .file))
        return packaged.root
    }

    /// One transfer, to the device named by its UDID, looked for again first.
    private func send(_ id: UUID, package: URL, to udid: String) async throws {
        if isCancelled(id) { throw NXPocketError(.cancelled, "send cancelled") }
        update(id) { $0.phase = .sending(fraction: 0, detail: "looking for the iPhone") }
        let found = await searchDevices(quiet: true)
        if isCancelled(id) { throw NXPocketError(.cancelled, "send cancelled") }
        guard let device = found.first(where: { $0.udid == udid && $0.canReceive }) else {
            throw NXPocketError(.deviceUnavailable, "the iPhone is not connected: plug it in or bring it on the same Wi-Fi, then send it from the library")
        }
        // The saves of a game the phone already has are copied to the Mac first: a send replaces the game, and the
        // phone keeps its saves across that, but a copy on the Mac is what survives a wiped phone.
        if let titleID = queue.first(where: { $0.id == id })?.titleID,
           let failure = await backUpBeforeSend(titleID, device: device, item: id) {
            let sendAnyway = await ask(id, "The saves could not be backed up (\(failure)). Send anyway?")
            if !sendAnyway { throw NXPocketError(.cancelled, "send cancelled: the saves were not backed up") }
            append("\(titleID): sent without a backup of its saves, as asked")
        }
        if isCancelled(id) { throw NXPocketError(.cancelled, "send cancelled") }
        let bundleID = settings.value.bundleID.isEmpty ? LauncherSettings.defaultBundleID : settings.value.bundleID
        let control = DeviceTransfer.Control()
        transferControl = control
        defer { transferControl = nil }
        update(id) {
            $0.deviceName = device.name
            $0.phase = .sending(fraction: 0, detail: "starting")
        }
        append("send: \(package.lastPathComponent) to \(device.name)")
        let sender = DeviceTransfer(toolchain: toolchain)
        let outcome = try await Task.detached(priority: .userInitiated) { [model = self] in
            try sender.transfer(package: package, to: device, bundleID: bundleID, control: control) { progress in
                Task { @MainActor in
                    model.update(id) { item in
                        guard case .sending = item.phase else { return }
                        item.phase = .sending(fraction: progress.fraction, detail: progress.detail)
                    }
                }
            }
        }.value
        append("sent \(outcome.entries.joined(separator: ", ")) — \(ByteCountFormatter.string(fromByteCount: outcome.bytes, countStyle: .file))")
    }

    func handle(_ event: EngineEvent, for id: UUID) {
        switch event {
        case .stage, .step, .progress, .stageEnd:
            if case .stageEnd(_, let name, let ok, let summary, let warn) = event {
                append("\(ok ? "ok " : "fail ")\(name)\(summary.isEmpty ? "" : ": \(summary)")\(warn ? " (warning)" : "")")
            }
            guard buildProgress.apply(event) else { return }
            let progress = buildProgress
            update(id) { item in
                guard case .building = item.phase else { return }
                item.phase = .building(stage: progress.stage, stageFraction: progress.stageHasCount ? progress.fraction : nil,
                                       overall: progress.overall, detail: progress.detail)
            }
        case .message(let message):
            if let reason = Self.engineError(in: message) { lastEngineError = reason }
            if let image = EngineBuilder.romfsImage(inMessage: message) { reportedRomfs = image }
            append(message)
        case .raw(let line):
            append(line)
        }
    }

    /// The text of an engine line marked as an error (`[RED] …`), without its colour tag.
    nonisolated static func engineError(in message: String) -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[RED]") else { return nil }
        let text = trimmed.dropFirst("[RED]".count).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// The plan an item shows while its real one could not be made (it is marked failed at once).
    private func placeholderPlan(_ game: FolderGame) -> BuildPlan {
        BuildPlan(titleID: game.titleID, name: game.name, inputs: [], version: nil, packageVersion: nil,
                  dlcTitleIDs: [], workFolder: URL(fileURLWithPath: NSTemporaryDirectory()), compressed: false)
    }
}
