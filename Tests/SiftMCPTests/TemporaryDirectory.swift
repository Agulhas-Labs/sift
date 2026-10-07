//
// Copyright © Agulhas Labs
//

import Foundation
import Testing

/// The one way a test makes a temporary directory, and the promise that goes with it: everything made in a scope is removed when the scope ends.
///
/// Removed whether the scope returned or threw, passed or failed. A scope is a test case, in every suite that carries `.temporaryDirectories` (`TemporaryDirectoriesTrait`), or an explicit `withScope`; a fixture the whole process shares (a `static let`) is filed with the process instead, through `makeForProcess`. A directory asked for from `make` outside any scope is refused and recorded as an issue rather than made, because nothing would ever take it away — which is how the suite once left tens of thousands of them in `$TMPDIR`. `TemporaryDirectoryTests` fails on any other way of reaching the temporary directory from `Tests/`, and on the two test targets' copies of this file, or of the trait's, differing.
struct TemporaryDirectory {
    @TaskLocal private static var current: Scope?

    /// A fresh, empty `$TMPDIR/sift-<purpose>-<UUID>`, removed with everything in it when the current scope ends.
    static func make(_ purpose: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> URL {
        guard let scope = current else {
            Issue.record(
                Comment(rawValue: "a temporary directory (sift-\(purpose)-…) was asked for outside any scope: give the suite `.temporaryDirectories`, wrap the call in `TemporaryDirectory.withScope`, or make it on the test's task before handing it to a thread"),
                sourceLocation: sourceLocation
            )
            throw OutsideAnyScope(purpose: purpose)
        }
        let directory = try create(purpose)
        scope.file(directory)
        return directory
    }

    /// The same directory for a fixture the whole process shares — a `static let` every test in a suite reads — removed when the process exits rather than when any one test ends.
    static func makeForProcess(_ purpose: String) throws -> URL {
        let directory = try create(purpose)
        process.file(directory)
        return directory
    }

    /// Runs `body` in a scope of its own, and removes every directory made in it before returning or rethrowing.
    ///
    /// A directory that will not go is recorded against the call that opened the scope.
    static func withScope<Result>(sourceLocation: SourceLocation = #_sourceLocation, _ body: () throws -> Result) rethrows -> Result {
        let scope = Scope()
        defer { scope.removeAll(sourceLocation: sourceLocation) }
        return try $current.withValue(scope, operation: body)
    }

    /// The same, awaited.
    nonisolated(nonsending) static func withScope<Result>(
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: nonisolated(nonsending) () async throws -> Result
    ) async rethrows -> Result {
        let scope = Scope()
        defer { scope.removeAll(sourceLocation: sourceLocation) }
        return try await $current.withValue(scope, operation: body)
    }

    /// The names of the entries directly in `$TMPDIR` that contain `fragment` — read, never removed, for the pins that prove a teardown left nothing there.
    static func entries(containing fragment: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.contains(fragment) }
    }

    private static var root: URL {
        FileManager.default.temporaryDirectory
    }

    /// The scope `makeForProcess` files into, emptied by the exit handler installed with it.
    private static let process: Scope = {
        atexit { TemporaryDirectory.process.removeAll(sourceLocation: #_sourceLocation) }
        return Scope()
    }()

    private static func create(_ purpose: String) throws -> URL {
        let directory = root.appendingPathComponent("sift-\(purpose)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}

extension TemporaryDirectory {
    /// What a directory asked for outside any scope throws, after recording the issue that says how to give it one.
    struct OutsideAnyScope: Error, CustomStringConvertible {
        let purpose: String

        var description: String {
            "no temporary-directory scope to make sift-\(purpose)-… in"
        }
    }

    /// The directories one scope has made, in the order it made them.
    private final class Scope: @unchecked Sendable {
        private let lock = NSLock()
        private var directories: [URL] = []

        func file(_ directory: URL) {
            lock.lock()
            defer { lock.unlock() }
            directories.append(directory)
        }

        /// Removes each directory, newest first.
        ///
        /// One the test already took away is not an error; one that will not go is recorded against the scope's caller rather than left silently — except at process exit, where there is no test left to fail.
        func removeAll(sourceLocation: SourceLocation) {
            lock.lock()
            let made = directories
            directories = []
            lock.unlock()
            for directory in made.reversed() {
                if let error = Self.remove(directory), Test.current != nil {
                    Issue.record(Comment(rawValue: "could not remove the temporary directory \(directory.path): \(error)"), sourceLocation: sourceLocation)
                }
            }
        }

        /// Removes `directory`, and says why not if it will not go.
        ///
        /// Asked three times, a tenth of a second apart, before it is called a failure: a removal has been seen to fail once with `EPERM` under a loaded machine and succeed when asked again, and a test fails on a leak it did not make otherwise.
        private static func remove(_ directory: URL) -> Error? {
            var failure: Error?
            for attempt in 1 ... 3 {
                do {
                    try FileManager.default.removeItem(at: directory)
                    return nil
                } catch let error as CocoaError where error.code == .fileNoSuchFile {
                    return nil
                } catch {
                    failure = error
                    if attempt < 3 {
                        usleep(100_000)
                    }
                }
            }
            return failure
        }
    }
}
