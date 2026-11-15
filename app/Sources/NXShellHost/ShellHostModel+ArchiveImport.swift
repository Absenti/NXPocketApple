import Foundation
import NXPocketKit

/// A build that comes as an archive (`GameArchiveImporter`): from a file picked in Files, read where it is, or from a link the player
/// types, downloaded first. Either way it is unpacked into `.incoming`, checked, and handed to the import that already exists, which signs
/// it and puts it in the library; what was unpacked is removed whatever happens, and so is a downloaded archive.
extension ShellHostModel {
    /// An archive picked in Files. `url` is read in place (a security-scoped URL), never copied first: a build is gigabytes. With
    /// `expectedSHA256`, the archive's hash is checked before anything is unpacked.
    public func importArchive(at url: URL, expectedSHA256: String? = nil) {
        guard !importState.isRunning else { return }
        let name = url.lastPathComponent
        importState = .running(stage: text(.archiveUnpacking), fraction: 0, detail: name)
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                // iCloud Drive keeps a file that is not on the phone as a stub: reading it through a coordinator brings it.
                let local = try await Self.materialise(url)
                try await unpack(local, name: name, sha256: expectedSHA256)
            } catch {
                importState = .failed(message(for: error))
                log.append("the archive \(name) was not imported: \(error)")
            }
        }
    }

    /// A build that is a folder, picked in Files: copied, checked and handed over as an archive's is.
    public func importFolder(at url: URL) {
        guard !importState.isRunning else { return }
        let name = url.lastPathComponent
        importState = .running(stage: text(.archiveUnpacking), fraction: 0, detail: name)
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try await handOver(name: name) { importer, progress in try importer.importFolder(url, progress: progress) }
            } catch {
                importState = .failed(message(for: error))
                log.append("the folder \(name) was not imported: \(error)")
            }
        }
    }

    /// A link to an archive: https only, downloaded to a temporary file that goes as soon as it is unpacked.
    public func importArchive(fromLink text: String, expectedSHA256: String? = nil) {
        guard !importState.isRunning else { return }
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.lowercased() == "https", url.host != nil else {
            importState = .failed(self.text(.archiveBadLink))
            return
        }
        let name = url.lastPathComponent.isEmpty ? (url.host ?? "") : url.lastPathComponent
        importState = .running(stage: self.text(.archiveDownloading), fraction: 0, detail: name)
        Task {
            var downloaded: URL?
            defer { if let downloaded { try? FileManager.default.removeItem(at: downloaded.deletingLastPathComponent()) } }
            do {
                let documents = self.documents
                let file = try await ArchiveDownload.fetch(url, documents: documents, availableSpace: { VolumeSpace.available(documents: documents) }) { fraction in
                    Task { @MainActor in
                        if case .running = self.importState { self.importState = .running(stage: self.text(.archiveDownloading), fraction: fraction, detail: name) }
                    }
                }
                downloaded = file
                try await unpack(file, name: name, sha256: expectedSHA256)
            } catch {
                // A download the network cut can be taken up again by giving the same link: the player is told so.
                let resumable = ArchiveDownload.ResumeStore(documents: self.documents).exists(for: url)
                importState = .failed(message(for: error) + (resumable ? "\n" + self.text(.archiveResumeHint) : ""))
                log.append("the archive at \(url.host ?? "a link") was not imported: \(error)")
            }
        }
    }

    private func unpack(_ archive: URL, name: String, sha256: String?) async throws {
        let hash = sha256?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? sha256 : nil
        try await handOver(name: name) { importer, progress in try importer.importArchive(archive, expectedSHA256: hash, progress: progress) }
    }

    /// Runs an import of the core off the main thread, follows its stages on screen, and hands the transfer it made to the import that
    /// exists.
    private func handOver(name: String, _ work: @escaping @Sendable (GameArchiveImporter, @escaping @Sendable (GameArchiveImporter.Stage, Double) -> Void) throws -> URL) async throws {
        let documents = documents
        let importer = GameArchiveImporter(documents: documents, availableSpace: { VolumeSpace.available(documents: documents) })
        let labels = [GameArchiveImporter.Stage.hashing: text(.archiveHashing), .unpacking: text(.archiveUnpacking), .checking: text(.archiveChecking)]
        let folder = try await Task.detached(priority: .userInitiated) {
            try work(importer) { stage, fraction in
                Task { @MainActor in
                    if case .running = self.importState { self.importState = .running(stage: labels[stage] ?? "", fraction: fraction, detail: name) }
                }
            }
        }.value
        log.append("\(name) was unpacked and checked as \(folder.lastPathComponent)")
        // The import that exists takes it from here: it verifies every file, signs and installs, or says what is missing (a certificate).
        importState = .idle
        refresh()
    }

    /// A file the player picked, made readable on this phone: an iCloud file not downloaded yet is fetched.
    private static func materialise(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            var coordinationError: NSError?
            var failure: Error?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { readable in
                if !FileManager.default.fileExists(atPath: readable.path) { failure = NXPocketError(.packageMissing, "\(url.lastPathComponent) is not on this iPhone") }
            }
            if let error = coordinationError ?? failure { continuation.resume(throwing: error) } else { continuation.resume(returning: url) }
        }
    }
}

/// An archive downloaded from a link: https, to a file of its own under the temporary folder, with the size checked against the free
/// space as soon as the server says it, and cancelled with the task. A download that fails on the network is taken up again from where it
/// stopped (the system's resume data, when the server allows ranges), up to three times; the resume data is kept on the phone, so the same
/// link typed again after the app was closed goes on too, and is forgotten when the download ends.
enum ArchiveDownload {
    struct Failure: Error {
        var error: Error
        var resumeData: Data?
        var cancelled: Bool
    }

    /// The resume data of unfinished downloads, one small file for each link.
    struct ResumeStore {
        let folder: URL

        init(documents: URL) { folder = documents.appendingPathComponent(".import-downloads", isDirectory: true) }

        func url(for link: URL) -> URL {
            folder.appendingPathComponent(String(FileDigest.sha256(of: Data(link.absoluteString.utf8)).prefix(32)) + ".resume")
        }

        func load(for link: URL) -> Data? { BoundedRead.dataIfPresent(at: url(for: link), limit: 1 << 20) }

        func exists(for link: URL) -> Bool { FileManager.default.fileExists(atPath: url(for: link).path) }

        func save(_ data: Data, for link: URL) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: url(for: link), options: .atomic)
        }

        func remove(for link: URL) { try? FileManager.default.removeItem(at: url(for: link)) }
    }

    static let attempts = 3

    static func fetch(_ link: URL, documents: URL, availableSpace: @escaping () -> Int64?, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let store = ResumeStore(documents: documents)
        var resume = store.load(for: link)
        var attempt = 0
        while true {
            do {
                let file = try await once(link, resume: resume, availableSpace: availableSpace, progress: progress)
                store.remove(for: link)
                return file
            } catch let failure as Failure {
                if let data = failure.resumeData { store.save(data, for: link) } else { store.remove(for: link) }
                if failure.cancelled { throw NXPocketError(.cancelled, "stopped") }
                attempt += 1
                // A resume that was refused (the file changed, the data is stale) starts again from the beginning, once; a network that
                // fails is waited for a little and tried again.
                guard attempt <= attempts, isWorthRetrying(failure.error) else { throw failure.error }
                resume = failure.resumeData
                try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
            }
        }
    }

    /// The failures a second try can mend: the network's, not the player's (a full disk) nor the server's answer.
    static func isWorthRetrying(_ error: Error) -> Bool {
        if let failure = error as? NXPocketError { return failure.code == .transferFailed }
        guard let url = error as? URLError else { return false }
        switch url.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed, .secureConnectionFailed: return true
        default: return false
        }
    }

    private static func once(_ link: URL, resume: Data?, availableSpace: @escaping () -> Int64?, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let box = DownloadBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let delegate = Delegate(availableSpace: availableSpace, progress: progress, continuation: continuation)
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60
                let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
                let task: URLSessionDownloadTask
                if let resume {
                    task = session.downloadTask(withResumeData: resume)
                } else {
                    var request = URLRequest(url: link)
                    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                    task = session.downloadTask(with: request)
                }
                box.set(task, session)
                task.resume()
            }
        } onCancel: { box.cancel() }
    }

    private final class DownloadBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDownloadTask?
        private var session: URLSession?
        func set(_ task: URLSessionDownloadTask, _ session: URLSession) { lock.withLock { self.task = task; self.session = session } }
        /// Cancelling keeps what arrived: the error that follows carries the resume data.
        func cancel() { lock.withLock { task?.cancel(byProducingResumeData: { _ in }) } }
    }

    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let availableSpace: () -> Int64?
        let progress: @Sendable (Double) -> Void
        var continuation: CheckedContinuation<URL, Error>?

        init(availableSpace: @escaping () -> Int64?, progress: @escaping @Sendable (Double) -> Void, continuation: CheckedContinuation<URL, Error>) {
            self.availableSpace = availableSpace
            self.progress = progress
            self.continuation = continuation
        }

        private func finish(_ result: Result<URL, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(with: result)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesExpectedToWrite > 0 {
                // The archive and what is unpacked from it are on the phone together: the download alone must leave room for the rest.
                if let free = availableSpace(), totalBytesExpectedToWrite - totalBytesWritten > free {
                    downloadTask.cancel()
                    finish(.failure(NXPocketError(.notEnoughSpace, "\(GameImporter.bytes(totalBytesExpectedToWrite)) to download, \(GameImporter.bytes(free)) free")))
                    return
                }
                progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return finish(.failure(NXPocketError(.packageMissing, "the link answered \(http.statusCode)")))
            }
            // The file the system hands over goes when this returns: it is moved into a folder of its own first.
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = folder.appendingPathComponent("download")
                try FileManager.default.moveItem(at: location, to: target)
                finish(.success(target))
            } catch {
                finish(.failure(NXPocketError(.transferFailed, "the download could not be kept: \(error.localizedDescription)")))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            session.finishTasksAndInvalidate()
            guard let error else { return }
            let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            let cancelled = (error as? URLError)?.code == .cancelled
            // What this reports to the loop above: the error and what can be resumed. A full disk was reported already.
            finish(.failure(Failure(error: cancelled ? NXPocketError(.cancelled, "stopped") : error, resumeData: resume, cancelled: cancelled)))
        }
    }
}

/// A file the player picked or was sent, waiting for the warning to be read.
public struct ArchiveRequest: Identifiable, Equatable {
    public let id = UUID()
    public var url: URL
    public var isFolder: Bool
}
