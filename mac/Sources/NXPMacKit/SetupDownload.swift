import Foundation
import NXPocketKit

/// A file fetched for the setup, checked against its pinned SHA-256 before anything of it is used.
public enum SetupDownload {
    /// `(bytes written, bytes expected)`; expected is 0 while the server has not said.
    public typealias Progress = @Sendable (Int64, Int64) -> Void

    /// Downloads `download` into `destination` (replaced) and checks its size and SHA-256. A file that does not match
    /// is deleted and refused: it is never unpacked, let alone run.
    public static func fetch(_ download: SetupPins.Download, to destination: URL, progress: @escaping Progress) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.removeItem(at: destination)
        let fetcher = Fetcher(destination: destination, progress: progress)
        try fetcher.run(download.url)
        try verify(destination, against: download)
    }

    /// A download whose hash is checked by the caller (the launcher's update checks it against the release's
    /// SHA256SUMS). Only the User-Agent is sent with it: no token, nothing about the user.
    static func fetch(_ url: URL, to destination: URL, userAgent: String, progress: @escaping Progress) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.removeItem(at: destination)
        try Fetcher(destination: destination, progress: progress, userAgent: userAgent).run(url)
    }

    public static func verify(_ file: URL, against download: SetupPins.Download) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? -1
        let digest = (try? FileDigest.sha256(ofFileAt: file)) ?? ""
        guard size == download.size, digest == download.sha256 else {
            try? FileManager.default.removeItem(at: file)
            throw NXPocketError(.packageDamaged,
                                "\(download.url.lastPathComponent) is not the pinned file (SHA-256 \(digest.prefix(12))…, \(size) bytes): it was deleted, nothing of it ran")
        }
    }

    /// One download through its own URLSession, waited for: the setup runs off the main thread, a step at a time.
    private final class Fetcher: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let destination: URL
        let progress: Progress
        let userAgent: String?
        private let done = DispatchSemaphore(value: 0)
        private var failure: Error?

        init(destination: URL, progress: @escaping Progress, userAgent: String? = nil) {
            self.destination = destination
            self.progress = progress
            self.userAgent = userAgent
        }

        func run(_ url: URL) throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            if let userAgent { configuration.httpAdditionalHeaders = ["User-Agent": userAgent] }
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            session.downloadTask(with: url).resume()
            done.wait()
            session.finishTasksAndInvalidate()
            if let failure { throw failure }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            progress(totalBytesWritten, max(totalBytesExpectedToWrite, 0))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // The file at `location` is gone once this returns: it is moved now.
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                failure = NXPocketError(.transferFailed, "\(downloadTask.originalRequest?.url?.host ?? "the server") answered \(status)")
                return
            }
            do {
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                failure = error
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error, failure == nil {
                failure = NXPocketError(.transferFailed, "the download stopped: \(error.localizedDescription)")
            }
            done.signal()
        }
    }
}

/// A command of the setup: its output goes line by line to `onLine`, and a failure says its last lines.
struct SetupCommand {
    var executable: URL
    var arguments: [String]
    var directory: URL?
    var environment: [String: String]

    @discardableResult
    func run(onLine: @escaping (String) -> Void = { _ in }) throws -> ProcessRunner.Result {
        let runner = ProcessRunner(executable: executable, arguments: arguments, currentDirectory: directory,
                                   environment: environment)
        runner.onLine = onLine
        try runner.start()
        let result = runner.waitUntilExit()
        guard result.status == 0 else {
            let tail = result.lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(3).joined(separator: " · ")
            throw NXPocketError(.engineFailed, "\(executable.lastPathComponent) \(arguments.first ?? "") failed (\(result.status)): \(tail)")
        }
        return result
    }

    /// A clean environment for what the setup runs: no user Python or pip settings that would change what is
    /// installed, Xcode's tools found through the chosen Xcode, nothing that asks for a password.
    static func environment(xcode: URL?) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": inherited["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
            "LANG": "en_US.UTF-8",
            "PIP_CONFIG_FILE": "/dev/null",
            "PIP_DISABLE_PIP_VERSION_CHECK": "1",
            "PIP_NO_INPUT": "1",
            "PYTHONNOUSERSITE": "1",
            "GIT_TERMINAL_PROMPT": "0",
        ]
        if let tmp = inherited["TMPDIR"] { environment["TMPDIR"] = tmp }
        if let xcode { environment["DEVELOPER_DIR"] = xcode.appendingPathComponent("Contents/Developer").path }
        return environment
    }
}
