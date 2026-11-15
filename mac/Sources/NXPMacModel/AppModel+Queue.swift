import Foundation
import NXPMacKit
import NXPocketKit

/// The queue: games built one after another (the engine runs one build at a time: its tools, its work folders and
/// the Mac's cores are all taken by one), each sent to the iPhone right after its build when asked, and packages
/// sent on their own. One transfer at a time too: two copies at once would put two multi-GB copies on the phone.
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
        for game in folder.games where checkedGames.contains(game.titleID) { enqueueBuild(game, device: device) }
        checkedGames = []
        startQueue()
    }

    /// The games of the games folder that can be built and are not in the library yet. A package that exists but is damaged is in the
    /// library (it shows as needing a rebuild), so it is not listed here too.
    public var buildableGames: [FolderGame] {
        let built = Set(games.map(\.titleID))
        return folder.games.filter { $0.hasBase && !built.contains($0.titleID) }
    }

    /// The build of this game that is waiting or running, if any.
    public func buildItem(_ titleID: String) -> QueueItem? {
        queue.first { item in
            guard item.titleID == titleID, !item.phase.isFinished else { return false }
            if case .build = item.job { return true }
            return false
        }
    }

    /// Builds one game of the library's "to build" list with the updates and DLC the folder's defaults pick (the Build screen is where
    /// they are chosen one by one). Sent to the iPhone afterwards when Settings says so.
    public func buildFromLibrary(_ game: FolderGame) {
        if let blocker = toolchainBlocker {
            append("build: \(blocker)")
            libraryProblem = blocker
            return
        }
        enqueueBuild(game, device: settings.value.sendAfterBuild ? selectedDevice : nil)
        startQueue()
    }

    /// Queues one game's build, sent to `device` afterwards when given. A game already waiting or building is left alone.
    func enqueueBuild(_ game: FolderGame, device: Device?) {
        if queue.contains(where: { $0.titleID == game.titleID && !$0.phase.isFinished }) { return }
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

    /// An iPhone asked, over the sharing server, for a game of the dump folder to be built. Nothing is sent to the phone from here:
    /// it downloads the game once it is among the Mac's built ones.
    func queueBuild(titleID: String) {
        guard let game = folder.games.first(where: { $0.titleID == titleID && $0.hasBase }) else { return }
        if let blocker = toolchainBlocker {
            var item = QueueItem(titleID: game.titleID, name: displayName(titleID: game.titleID, own: game.name),
                                 job: .build(placeholderPlan(game), sendTo: nil))
            item.phase = .failed(blocker)
            queue.append(item)
            append("an iPhone asked for \(game.name): \(blocker)")
            return
        }
        append("an iPhone asked for \(game.name) to be built")
        enqueueBuild(game, device: nil)
        startQueue()
    }

    /// The engine refuses to build when the game's cached provisional profile describes another version than the one in the
    /// folder ("…describes v0, but inputs select v65536. Preserving the existing profile at <folder>…"): it never overwrites
    /// a profile. Returns that folder when a failure is this one.
    nonisolated public static func staleProfileFolder(in reason: String) -> URL? {
        guard reason.contains("cached provisional profile"), let start = reason.range(of: "Preserving the existing profile at ") else { return nil }
        let rest = reason[start.upperBound...]
        guard let end = rest.range(of: ". Use --profile-out") else { return nil }
        let path = String(rest[..<end.lowerBound])
        return path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true) : nil
    }

    /// Puts the stale profile aside (renamed, never deleted: it is the engine's survey of the older version) and queues the
    /// build again, so the engine surveys the version now in the folder into a fresh profile.
    public func surveyUpdate(_ id: UUID) {
        guard let item = queue.first(where: { $0.id == id }), case .failed(let reason) = item.phase,
              let folder = Self.staleProfileFolder(in: reason) else { return }
        let fileManager = FileManager.default
        var aside = folder.deletingLastPathComponent().appendingPathComponent("\(folder.lastPathComponent)-older")
        var number = 2
        while fileManager.fileExists(atPath: aside.path) {
            aside = folder.deletingLastPathComponent().appendingPathComponent("\(folder.lastPathComponent)-older-\(number)")
            number += 1
        }
        do { try fileManager.moveItem(at: folder, to: aside) }
        catch {
            append("build: the old profile could not be put aside: \(error.localizedDescription)")
            return
        }
        append("build: \(item.name): the old profile is kept as \(aside.lastPathComponent); the engine surveys the new version")
        update(id) { $0.phase = .waiting }
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

    /// Stops the engine of the build under way, and everything it started, where they are: nothing is lost and nothing
    /// is computed meanwhile, so the Mac is free for something else. `resumeBuild` goes on from the same point.
    public func pauseBuild(_ id: UUID) {
        guard let item = queue.first(where: { $0.id == id }), item.canPause, !item.isPaused,
              let runner, runner.pause() else { return }
        update(id) { $0.isPaused = true }
        append("build: paused \(item.name)")
    }

    public func resumeBuild(_ id: UUID) {
        guard let item = queue.first(where: { $0.id == id }), item.isPaused else { return }
        runner?.resume()
        update(id) { $0.isPaused = false }
        append("build: resumed \(item.name)")
    }

    public func togglePause(_ id: UUID) {
        if queue.first(where: { $0.id == id })?.isPaused == true { resumeBuild(id) } else { pauseBuild(id) }
    }

    /// Stops one item: a waiting one is cancelled at once; the one under way has its engine or transfer terminated.
    public func cancelItem(_ id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        if queue[index].phase == .waiting {
            queue[index].phase = .cancelled
            return
        }
        guard !queue[index].phase.isFinished else { return }
        cancelledItems.insert(id)
        // A send answers the click at once. What it is doing (reading the iPhone, copying the saves back, or devicectl itself) stops as
        // soon as it can, and the part already sent is marked for deletion on the phone in the background: the player is not made to
        // watch a "Sending" that no longer means anything.
        if case .sending = queue[index].phase { queue[index].phase = .cancelled }
        if pendingAnswers[id] != nil { answer(id, sendAnyway: false) }
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
                    update(item.id) { $0.phase = .done("built and sent: open NXPocketApple on the iPhone to import it") }
                } else {
                    update(item.id) { $0.phase = .done("built \(plan.versionTag ?? "")") }
                }
            case .send(let package, let device):
                try await send(item.id, package: package, to: device)
                update(item.id) { $0.phase = .done("sent: open NXPocketApple on the iPhone to import it") }
            }
        } catch let error as NXPocketError where error.code == .cancelled {
            update(item.id) { $0.phase = .cancelled }
            // Always logged, a send included: the part already sent is marked for deletion on the phone, and the log explains it.
            append("\(item.name): \(error.detail)")
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
        // An item that is over, or past its build, is not paused whatever its flag said.
        if queue[index].isPaused, !queue[index].canPause { queue[index].isPaused = false }
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
        // The work folder as it is before this build writes anything in it (`BuildInputs.prepare` included): a cancel
        // removes what has appeared since, and never what was there.
        let footprint = await Task.detached(priority: .userInitiated) { BuildFootprint.capture(plan.workFolder) }.value
        // Which engine this build began with: if it is another at the end of a failure, that is the first thing to say.
        let engineRoot = toolchain.engine.root
        let engineAtStart = await Task.detached(priority: .userInitiated) { EngineIdentity.read(engineRoot) }.value
        try await Task.detached(priority: .userInitiated) { try BuildInputs.prepare(plan) }.value

        // The title ID always goes: a merged cartridge dump can hold two games, and naming the one keeps the engine
        // from refusing the folder.
        let request = EngineBuildRequest(gameFolder: plan.inputFolder,
                                         keysFile: settings.value.keysURL,
                                         titleID: plan.titleID,
                                         packageVersion: plan.packageVersion,
                                         language: settings.value.language,
                                         // The engine keeps the extraction of a framework-only build whatever this says
                                         // (`--shell-framework` implies `--keep-extracted`): said plainly, not argued with.
                                         keepExtracted: true,
                                         allowOtherMetal: settings.value.allowOtherMetal,
                                         stagingFolder: staging,
                                         workFolder: plan.workFolder,
                                         includesDLC: !plan.dlcTitleIDs.isEmpty,
                                         expectedVersion: plan.version)
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
            if result.isCancelled { await discardWork(of: footprint, for: plan, runner: runner, id: id) }
            if result.isCancelled { throw NXPocketError(.cancelled, "build cancelled") }
            var reason = lastEngineError ?? "the engine exited with \(result.status)"
            let engineNow = await Task.detached(priority: .userInitiated) { EngineIdentity.read(engineRoot) }.value
            if let note = EngineIdentity.changeNote(from: engineAtStart, to: engineNow) {
                append("build: \(plan.name): \(note)")
                reason += " — \(note)"
            }
            throw NXPocketError(.engineFailed, reason)
        }

        if isCancelled(id) {
            await discardWork(of: footprint, for: plan, runner: nil, id: id)
            throw NXPocketError(.cancelled, "cancelled after the build")
        }
        let output = try builder.outputs(for: request, reportedRomfs: reportedRomfs)
        guard let titleID = TitleID(output.manifest.titleID) else {
            throw NXPocketError(.packageDamaged, "the engine's manifest has no title ID")
        }
        let outputFolder = settings.value.outputURL
        let destination = LocalLibrary.destination(for: titleID, in: outputFolder)
        let destinationExisted = FileManager.default.fileExists(atPath: destination.path)
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
        if isCancelled(id) {
            // Packing is not interrupted, so a cancel during it is acted on here. A package that did not exist before this
            // build goes; one it replaced stays (the new one is whole, and the old one cannot be given back).
            if !destinationExisted {
                try? FileManager.default.removeItem(at: packaged.root)
                append("build: \(plan.name) cancelled, the package it had just made is removed")
            }
            await discardWork(of: footprint, for: plan, runner: nil, id: id)
            refreshLibrary()
            throw NXPocketError(.cancelled, "cancelled while packing")
        }
        refreshLibrary()
        append("packed \(packaged.package.titleID) \(packaged.manifest.name) \(packaged.package.packageVersion) — "
               + ByteCountFormatter.string(fromByteCount: packaged.package.totalSize, countStyle: .file))
        if settings.value.removeBuildFolder {
            await removeBuildFolder(of: plan, id: id)
        } else {
            await removeDecompressedCopy(of: plan, id: id)
        }
        return packaged.root
    }

    /// Once the package is written, the game's whole work folder goes: the package is complete without it (the image was copied into it,
    /// the framework hashed and copied), and it is gigabytes of extraction. Only after a build that succeeded: a failed one keeps its
    /// folder and its logs.
    private func removeBuildFolder(of plan: BuildPlan, id: UUID) async {
        let folder = plan.workFolder
        let removed = await Task.detached(priority: .utility) { BuildFolders.remove(folder) }.value
        guard let removed else {
            append("build: \(plan.name): its work folder was not removed (\(folder.lastPathComponent) is not one that is)")
            return
        }
        let size = ByteCountFormatter.string(fromByteCount: removed, countStyle: .file)
        append("build: \(plan.name): removed its work folder \(folder.lastPathComponent) (\(size)); the package and your dump are untouched")
        update(id) { $0.note = "freed \(size) (work folder)" }
    }

    /// The work folders earlier builds left, for games whose package is built and that no build in the queue is using.
    public func leftoverBuildFolders() async -> [(folder: URL, bytes: Int64)] {
        var roots: [URL] = []
        if let games = settings.value.gameURL { roots.append(games) }
        if let work = settings.value.workURL { roots.append(work) }
        let busy = Set(queue.filter { !$0.phase.isFinished }.map(\.titleID))
        let built = Set(games.filter(\.isReady).map(\.titleID))
        return await Task.detached(priority: .utility) {
            BuildFolders.find(in: roots).compactMap { folder in
                guard let titleID = BuildFolders.titleID(of: folder), built.contains(titleID), !busy.contains(titleID) else { return nil }
                return (folder, BuildFolders.size(of: folder))
            }
        }.value
    }

    /// Removes those folders. Returns the bytes freed.
    @discardableResult
    public func deleteLeftoverBuildFolders() async -> Int64 {
        let found = await leftoverBuildFolders()
        let freed = await Task.detached(priority: .utility) { found.reduce(Int64(0)) { $0 + (BuildFolders.remove($1.folder) ?? 0) } }.value
        append("build: removed \(found.count) work folder(s) left by earlier builds, \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))")
        return freed
    }

    /// Once the package is built, the `.nsp` / `.xci` the engine made out of an `.nsz` / `.xcz` can go: it is as large as
    /// the game, the dump it came from is untouched, and the next build decompresses it again. See `DecompressedCopies`.
    private func removeDecompressedCopy(of plan: BuildPlan, id: UUID) async {
        guard settings.value.removeDecompressed, plan.compressed else { return }
        let removed = await Task.detached(priority: .utility) {
            DecompressedCopies.remove(in: plan.workFolder, keeping: plan.inputs.map(\.source))
        }.value
        guard !removed.isEmpty else { return }
        let size = ByteCountFormatter.string(fromByteCount: removed.bytes, countStyle: .file)
        append("build: \(plan.name): removed the decompressed copy (\(size)): \(removed.removed.joined(separator: ", ")); the original dump and the package are untouched")
        update(id) { $0.note = "freed \(size) (decompressed copy)" }
    }

    /// Takes away what a cancelled build made in its work folder (`BuildFootprint`), once nothing it started is still
    /// writing there, and says how much that was.
    private func discardWork(of footprint: BuildFootprint, for plan: BuildPlan, runner: ProcessRunner?, id: UUID) async {
        append("build: \(plan.name) cancelled, removing what it created")
        let (stopped, removal) = await Task.detached(priority: .userInitiated) { () -> (Bool, BuildFootprint.Removal) in
            let stopped = runner?.waitUntilTreeGone() ?? true
            return (stopped, footprint.removeCreated())
        }.value
        if !stopped { append("build: something the engine started was still running after 10 s; the cleanup went on anyway") }
        let text: String
        if !footprint.isSafe {
            text = "its work folder is not one that is cleaned (\(footprint.folder.lastPathComponent)): left as it is"
        } else if removal.isEmpty {
            text = "nothing to remove, it had created nothing yet"
        } else {
            let size = ByteCountFormatter.string(fromByteCount: removal.bytes, countStyle: .file)
            text = removal.wholeFolder
                ? "removed \(footprint.folder.lastPathComponent) (\(size)), all of it was this build's"
                : "removed \(removal.items) files and folders (\(size)) this build had created in \(footprint.folder.lastPathComponent)"
        }
        append("build: \(plan.name): \(text)")
        update(id) { $0.note = text }
    }

    /// One transfer, to the device named by its UDID, looked for again first.
    private func send(_ id: UUID, package: URL, to udid: String) async throws {
        if isCancelled(id) { throw NXPocketError(.cancelled, "send cancelled") }
        // Made before anything slow, so a cancel always has something to stop, whatever step the send is in.
        let control = DeviceTransfer.Control()
        transferControl = control
        defer { transferControl = nil }
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

    /// The text of an engine line marked as an error (`[RED] …`), without its colour tag and the clock the engine puts
    /// before every message (`[21:05:47] [RED] …`).
    nonisolated static func engineError(in message: String) -> String? {
        let trimmed = EngineBuilder.withoutClock(message)
        guard trimmed.hasPrefix("[RED]") else { return nil }
        let text = trimmed.dropFirst("[RED]".count).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// The plan an item shows while its real one could not be made (it is marked failed at once).
    func placeholderPlan(_ game: FolderGame) -> BuildPlan {
        BuildPlan(titleID: game.titleID, name: game.name, inputs: [], version: nil, packageVersion: nil,
                  dlcTitleIDs: [], workFolder: URL(fileURLWithPath: NSTemporaryDirectory()), compressed: false)
    }
}
