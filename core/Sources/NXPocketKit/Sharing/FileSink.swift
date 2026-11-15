import Foundation

/// One file being written, through a descriptor opened without following a link: a link planted where a planned file goes
/// (the folder is in `Documents`, which Files can write to) is a refusal, never a write through it.
final class FileSink {
    private var fd: Int32

    /// Opens `url`, cuts it to `offset` bytes and positions there. A file that is shorter than `offset` is a failure: the
    /// journal promised bytes the disk does not have.
    init(url: URL, offset: Int64) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
        }
        guard descriptor >= 0 else {
            let reason = errno == ELOOP ? "a link stands where the file goes" : String(cString: strerror(errno))
            throw NXPocketError(errno == ELOOP ? .symbolicLink : .transferFailed,
                                "\(url.lastPathComponent) could not be opened: \(reason)", path: url.lastPathComponent)
        }
        fd = descriptor
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= offset,
              ftruncate(fd, off_t(offset)) == 0, lseek(fd, off_t(offset), SEEK_SET) == off_t(offset) else {
            Darwin.close(fd)
            fd = -1
            throw NXPocketError(.transferFailed, "\(url.lastPathComponent) is not what the journal says", path: url.lastPathComponent)
        }
    }

    deinit { close() }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var done = 0
            while done < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + done, raw.count - done)
                if written < 0 {
                    if errno == EINTR { continue }
                    let code: NXPocketError.Code = errno == ENOSPC ? .notEnoughSpace : .transferFailed
                    throw NXPocketError(code, "writing failed: \(String(cString: strerror(errno)))")
                }
                done += written
            }
        }
    }

    /// Everything written so far is on the disk, not in the system's cache.
    func sync() throws {
        if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 {
            throw NXPocketError(.transferFailed, "the disk did not confirm the write: \(String(cString: strerror(errno)))")
        }
    }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }
}
