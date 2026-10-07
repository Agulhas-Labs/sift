//
// Copyright © Agulhas Labs
//

import CryptoKit
import Foundation

/// The git a set-aside runs: in one directory, with no repository inherited from the caller's environment, input fed on stdin and output kept as bytes — and every run a child of ``SetAsideChildren``, so a watcher can end it before it restores.
struct SetAsideGit {
    let directory: URL
    /// The repository's root, which git's own messages are stated relative to.
    let repositoryRoot: URL
    let children: SetAsideChildren

    init(directory: URL, repositoryRoot: URL? = nil, children: SetAsideChildren) {
        self.directory = directory
        self.repositoryRoot = repositoryRoot ?? directory
        self.children = children
    }
}

extension SetAsideGit {
    /// Runs git and returns its stdout, trimmed of the newline it ends on.
    func text(_ arguments: [String]) throws -> String {
        let output = try run(arguments)
        return (String(data: output, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs git, feeding `input` on stdin and sending stdout to the open descriptor `output` when one is named, with `environment` over the scrubbed one; throws with git's own message on a nonzero exit.
    @discardableResult
    func run(_ arguments: [String], input: Data? = nil, writingTo output: Int32? = nil, environment: [String: String] = [:]) throws -> Data {
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        let null = open("/dev/null", O_RDONLY | O_CLOEXEC)
        defer {
            if null >= 0 {
                close(null)
            }
        }
        // A git that exits without reading all of its input would otherwise end this process with SIGPIPE
        // on the write below — mid-restore, which is the one place that must not happen.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let streams = SetAsideChildren.Streams(
            input: input == nil ? null : stdin.fileHandleForReading.fileDescriptor,
            output: output ?? stdout.fileHandleForWriting.fileDescriptor,
            error: stderr.fileHandleForWriting.fileDescriptor
        )
        let pid = try children.spawn(
            "/usr/bin/git",
            ProcessEnvironment.gitHardening + arguments,
            in: directory,
            environment: ProcessEnvironment.withoutGit().merging(environment) { _, given in given },
            streams: streams
        )
        // The child holds its own copies now; this side's must go, or the reads below never see end-of-file.
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        try? stdin.fileHandleForReading.close()
        if let input {
            let writer = Thread {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
            writer.name = "sift.set-aside.stdin"
            writer.start()
        } else {
            try? stdin.fileHandleForWriting.close()
        }
        let (data, failure) = ProcessStreams.drain(stdout: stdout, stderr: stderr)
        let status = SetAsideChildren.exitCode(waitingFor: pid)
        children.settle(pid)
        guard status == 0 else {
            // git's first line is its diagnosis; what follows is advice written for somebody running git by hand.
            let message = (String(data: failure, encoding: .utf8) ?? "")
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? "exit \(status)"
            throw SetAsideError.git("git \(arguments.prefix(2).joined(separator: " ")) failed: \(shown(message))")
        }
        return data
    }

    /// Copies every object in `objects` out of the object database into `destination`, each under its own name, and checks each copy hashes back to its object — one `git cat-file --batch` for all of them, where a process per object cost more than the copying.
    ///
    /// Each copy is created exclusively and streamed to disk as git produces it, so no object has to fit in memory. Without `--filters`, because with them git's header states the size before filtering while the bytes after it are filtered, and the stream could not be split.
    func copyObjects(_ objects: [String], into destination: URL) throws {
        let wanted = Array(Set(objects)).sorted()
        guard !wanted.isEmpty else {
            return
        }
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let pid = try children.spawn(
            "/usr/bin/git",
            ProcessEnvironment.gitHardening + ["cat-file", "--batch"],
            in: directory,
            environment: ProcessEnvironment.withoutGit(),
            streams: SetAsideChildren.Streams(
                input: stdin.fileHandleForReading.fileDescriptor,
                output: stdout.fileHandleForWriting.fileDescriptor,
                error: stderr.fileHandleForWriting.fileDescriptor
            )
        )
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        try? stdin.fileHandleForReading.close()
        let input = Data(wanted.map { "\($0)\n" }.joined().utf8)
        let writer = Thread {
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        }
        writer.name = "sift.set-aside.batch-stdin"
        writer.start()
        let failure = ErrorDrain(stderr.fileHandleForReading)
        let reader = BatchReader(descriptor: stdout.fileHandleForReading.fileDescriptor)
        var copied: Result<Void, Error> = .success(())
        do {
            for object in wanted {
                try reader.copy(object, into: destination.appendingPathComponent(object).path)
            }
        } catch {
            copied = .failure(error)
            // Whatever is left unread must not hold git blocked on a full pipe while it is waited for.
            kill(pid, SIGTERM)
            reader.drain()
        }
        let status = SetAsideChildren.exitCode(waitingFor: pid)
        children.settle(pid)
        let message = failure.finish()
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
        try copied.get()
        guard status == 0 else {
            throw SetAsideError.git("git cat-file --batch failed: \(shown(message.isEmpty ? "exit \(status)" : message))")
        }
    }

    /// The same run, retried for a few seconds while another git holds the index lock.
    ///
    /// Only a restore waits: a set-aside that cannot take the lock has touched nothing and can simply refuse, but a restore that gives up leaves somebody's work out of their tree until they come back to it.
    func runWaitingForIndexLock(_ arguments: [String], input: Data) throws {
        var attempts = 0
        while true {
            do {
                try run(arguments, input: input)
                return
            } catch let SetAsideError.git(message) where message.contains("index.lock") {
                guard attempts < 50 else {
                    throw SetAsideError.indexLocked(message)
                }
                attempts += 1
                usleep(100_000)
            }
        }
    }

    /// `message` with every absolute spelling of the repository's root taken off the paths it names, and any path into a git directory stated from that directory — an answer is shared, and a machine's layout is no part of it.
    func shown(_ message: String) -> String {
        var text = message
        let root = repositoryRoot.path
        for spelling in Set([root, repositoryRoot.resolvingSymlinksInPath().path, "/private" + root]) where spelling.count > 1 {
            text = text.replacingOccurrences(of: spelling + "/", with: "")
        }
        return text.replacing(#/(?:/[^/'"\s]+)+/(\.git/)/#) { $0.output.1 }
    }
}

private extension SetAsideGit {
    /// `git cat-file --batch` output, read as it arrives: a header line per object, then exactly as many bytes as it names, then a newline.
    final class BatchReader {
        let descriptor: Int32
        private var pending: [UInt8] = []
        private var start = 0
        private let chunk = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 16, alignment: 16)

        init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        deinit {
            chunk.deallocate()
        }

        /// Copies the next object — which must be `object`, a blob — into a new file at `path`, hashing it as a blob the way git does, and throws unless the hash is `object`.
        func copy(_ object: String, into path: String) throws {
            guard let header = try line() else {
                throw SetAsideError.git("git cat-file --batch ended before staged object \(object)")
            }
            let fields = header.split(separator: " ")
            guard fields.count == 3, fields[0] == object, fields[1] == "blob", let size = Int(fields[2]) else {
                throw SetAsideError.store("staged object \(object) could not be copied: git answered \(header)")
            }
            let file = open(path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o644)
            guard file >= 0 else {
                throw SetAsideError.store("could not create the copy of staged object \(object): \(String(cString: strerror(errno)))")
            }
            defer { close(file) }
            let hashed = object.count == 64
                ? try stream(size, to: file, hashing: SHA256())
                : try stream(size, to: file, hashing: Insecure.SHA1())
            guard try take(1) == [UInt8(ascii: "\n")] else {
                throw SetAsideError.git("git cat-file --batch did not end staged object \(object) where its size said")
            }
            guard hashed == object else {
                throw SetAsideError.store("the copy of staged object \(object) does not hash back to it")
            }
        }

        /// Reads and discards everything left, so the process writing it can finish.
        func drain() {
            while (try? fill()) == true {
                start = pending.count
            }
        }

        private func stream(_ size: Int, to file: Int32, hashing initial: some HashFunction) throws -> String {
            var hasher = initial
            hasher.update(data: Data("blob \(size)\u{0}".utf8))
            var remaining = size
            while remaining > 0 {
                if start == pending.count, try !fill() {
                    throw SetAsideError.git("git cat-file --batch ended part-way through an object")
                }
                let count = min(remaining, pending.count - start)
                try pending.withUnsafeBytes { bytes in
                    let slice = UnsafeRawBufferPointer(rebasing: bytes[start ..< start + count])
                    hasher.update(bufferPointer: slice)
                    var written = 0
                    while written < count {
                        let result = write(file, slice.baseAddress?.advanced(by: written), count - written)
                        if result < 0, errno == EINTR {
                            continue
                        }
                        guard result > 0 else {
                            throw SetAsideError.store("could not write a copy of a staged object: \(String(cString: strerror(errno)))")
                        }
                        written += result
                    }
                }
                start += count
                remaining -= count
            }
            return SetAsideFingerprint.hex(hasher.finalize())
        }

        private func line() throws -> String? {
            while true {
                if let newline = pending[start...].firstIndex(of: UInt8(ascii: "\n")) {
                    let text = String(bytes: pending[start ..< newline], encoding: .utf8) ?? ""
                    start = newline + 1
                    return text
                }
                guard try fill() else {
                    return nil
                }
            }
        }

        private func take(_ count: Int) throws -> [UInt8] {
            while pending.count - start < count {
                guard try fill() else {
                    break
                }
            }
            let taken = Array(pending[start ..< min(pending.count, start + count)])
            start += taken.count
            return taken
        }

        /// Reads what the pipe has; `false` at end of file.
        private func fill() throws -> Bool {
            if start == pending.count {
                pending.removeAll(keepingCapacity: true)
                start = 0
            }
            while true {
                let count = read(descriptor, chunk.baseAddress, chunk.count)
                if count < 0, errno == EINTR {
                    continue
                }
                guard count >= 0 else {
                    throw SetAsideError.git("could not read from git cat-file --batch: \(String(cString: strerror(errno)))")
                }
                guard count > 0 else {
                    return false
                }
                pending.append(contentsOf: UnsafeRawBufferPointer(rebasing: chunk.prefix(count)))
                return true
            }
        }
    }

    /// A child's stderr, read to its end on a thread of its own so a full pipe never holds the child up, and its first line kept as the diagnosis.
    final class ErrorDrain: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        private var data = Data()

        init(_ handle: FileHandle) {
            let thread = Thread { [self] in
                data = (try? handle.readToEnd()) ?? Data()
                done.signal()
            }
            thread.name = "sift.set-aside.stderr"
            thread.start()
        }

        func finish() -> String {
            done.wait()
            return (String(data: data, encoding: .utf8) ?? "")
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? ""
        }
    }
}
