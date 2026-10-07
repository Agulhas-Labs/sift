//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Assertion-free plumbing for the suite: parse source strings, stand up disposable git repos, weigh a listing the way the block that serves one weighs it.
struct TestSources {
    /// Parses a source string as if it lived at `path` (via a temp file, mirroring the real read path).
    static func parsed(_ source: String, path: String) throws -> ParsedFile {
        try TemporaryDirectory.withScope {
            let temp = try TemporaryDirectory.make("src").appendingPathComponent("source.swift")
            try source.write(to: temp, atomically: true, encoding: .utf8)
            guard let parsed = FileParser.parse(absoluteURL: temp, repoRelativePath: path) else {
                throw SQLiteError("fixture source failed to parse: \(path)")
            }
            return parsed
        }
    }

    /// Parses a source string written at its real repo-relative location under `root` — for fixtures whose *content* gets read back, like the member-body digest path.
    static func parsed(_ source: String, path: String, in root: URL) throws -> ParsedFile {
        try write(source, to: path, in: root)
        let url = root.appendingPathComponent(path)
        guard let parsed = FileParser.parse(absoluteURL: url, repoRelativePath: path) else {
            throw SQLiteError("fixture source failed to parse: \(path)")
        }
        return parsed
    }

    /// One of the captured toolchain transcripts under `Fixtures/RunOutput`, verbatim.
    static func runOutput(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures/RunOutput") else {
            throw SQLiteError("missing run-output fixture: \(name)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// One of the captures under `Fixtures/RunOutput` that is not a transcript, as the bytes the tool wrote — `xcodebuild`'s test enumeration writes a JSON document rather than printing lines.
    static func runOutputData(_ name: String, extension fileExtension: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: fileExtension, subdirectory: "Fixtures/RunOutput") else {
            throw SQLiteError("missing run-output fixture: \(name).\(fileExtension)")
        }
        return try Data(contentsOf: url)
    }

    /// The report `RunOutputFilter` builds from a captured transcript, optionally read against the invocation that produced it.
    ///
    /// `invokedAs` is stated by the test rather than parsed out of the capture's own `Command line invocation:` line, because a reader that recovers the expectation from the log it is judging can only ever agree with it — the same reason `RunVerdict.Contract` is read from argv. Each capture's real invocation is recorded beside it in `PROVENANCE.md`.
    ///
    /// **Naming no invocation means `.unreadable`, which is a contract and not the absence of one.** A test that says nothing about how the capture was run is a test that has told the filter it cannot know which verdict was owed, so the answer refuses to take one from the log — which is exactly what the production path now does with a command it cannot read. A test asserting on the headline therefore has to state the invocation.
    ///
    /// `exitCode` is `nil` unless a test states it, exactly as `invokedAs` defaults to naming nothing — but production always has one, so a test about a verdict states it as `RunLauncher` would. The exit-code-inferred reading (`RunOutputFilter.verdict(from:exitCode:)`) needs both halves stated: exit `0`, and `-quiet` in `invokedAs`, which is read through `RunOutputFilter(invokedAs:)` exactly as the launcher reads it.
    static func runReport(_ name: String, invokedAs arguments: [String] = [], exitCode: Int32? = nil) throws -> RunReport {
        var filter = RunOutputFilter(invokedAs: arguments)
        try filter.consume(Data(runOutput(name).utf8))
        return filter.finish(exitCode: exitCode)
    }

    /// A disposable directory for fixtures that must exist on disk (no git, unlike `makeTempRepo`).
    static func makeTempDirectory() throws -> URL {
        try TemporaryDirectory.make("fixture")
    }

    /// A fresh `IndexStore` in a disposable directory.
    static func makeStore() throws -> IndexStore {
        try IndexStore(databasePath: TemporaryDirectory.make("store").appendingPathComponent("index.db").path)
    }

    /// A disposable git repository with one initial commit.
    static func makeTempRepo() throws -> URL {
        try makeTempRepo(at: TemporaryDirectory.make("repo"))
    }

    /// The same repository at a caller-chosen path, for tests whose point is where the repo sits — inside a container folder, say.
    static func makeTempRepo(at root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: root)
        try runGit(["config", "user.email", "test@example.com"], in: root)
        try runGit(["config", "user.name", "Tester"], in: root)
        try "seed\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], in: root)
        try runGit(["commit", "-m", "seed"], in: root)
        return root.resolvingSymlinksInPath()
    }

    /// A linked worktree of `root`, on its own branch — the shape an agent session creates under `.claude/worktrees/`.
    static func makeWorktree(of root: URL, named name: String) throws -> URL {
        let worktree = root.appendingPathComponent(".claude/worktrees/\(name)")
        try runGit(["worktree", "add", "-b", name, worktree.path], in: root)
        return worktree.resolvingSymlinksInPath()
    }

    /// A **bare** repository at `<container>/<name>.git`, cloned from a seeded checkout so a worktree can be added at a real commit.
    ///
    /// The layout a server-side clone has, and the one where every path assumption about a git directory breaks: there is no checkout for the repository to be named after, and `repo.git` sits *beside* its worktrees rather than inside one of them.
    static func makeBareRepo(named name: String) throws -> URL {
        let seed = try makeTempRepo()
        let container = try makeTempDirectory()
        let bare = container.appendingPathComponent("\(name).git")
        try runGit(["clone", "--bare", seed.path, bare.path], in: container)
        return bare.resolvingSymlinksInPath()
    }

    /// A linked worktree of a bare repository, sited beside it — the only kind of working tree such a repository has.
    static func makeWorktree(ofBare bare: URL, named name: String) throws -> URL {
        let worktree = bare.deletingLastPathComponent().appendingPathComponent(name)
        try runGit(["worktree", "add", "-b", name, worktree.path], in: bare)
        return worktree.resolvingSymlinksInPath()
    }

    /// A repository whose git directory sits outside its checkout (`git init --separate-git-dir`), returning both.
    ///
    /// The other layout whose git directory is not `<checkout>/.git`, and the one that shows the difference between asking git and doing path arithmetic: nothing about either path says the two belong together.
    static func makeRepoWithSeparateGitDirectory(named name: String) throws -> (checkout: URL, gitDirectory: URL) {
        let container = try makeTempDirectory()
        let gitDirectory = container.appendingPathComponent("\(name)-gitdir")
        let checkout = container.appendingPathComponent(name)
        try runGit(["init", "--separate-git-dir", gitDirectory.path, "-b", "main", checkout.path], in: container)
        try runGit(["config", "user.email", "test@example.com"], in: checkout)
        try runGit(["config", "user.name", "Tester"], in: checkout)
        try "seed\n".write(to: checkout.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], in: checkout)
        try runGit(["commit", "-m", "seed"], in: checkout)
        return (checkout.resolvingSymlinksInPath(), gitDirectory.resolvingSymlinksInPath())
    }

    static func write(_ text: String, to relativePath: String, in root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func commitAll(in root: URL, message: String) throws {
        try runGit(["add", "-A"], in: root)
        try runGit(["commit", "-m", message], in: root)
    }

    /// Builds a SwiftPM package with an index store — the semantic tests' fixture builder.
    ///
    /// The store lands at `<root>/.build/index/store` under the native build system, which honours the flag below, and at `<root>/.build/out` under Swift Build, which ignores it. Discovery finds either, so the fixtures exercise whichever layout the running toolchain's default build produces.
    ///
    /// `includingTests` is what `affected`'s fixtures need and the others do not: without `--build-tests` the store holds no unit for the test target at all, so every reference *from* a test is invisible and the fixture would prove the opposite of what it was written for.
    ///
    /// `arguments` follow the rest: `--build-system native` or `--build-system swiftbuild` to build one layout whatever the toolchain's default, `-c release` for the other configuration.
    static func swiftBuild(packageAt root: URL, includingTests: Bool = false, arguments: [String] = []) throws {
        try swiftBuild(packageAt: root, includingTests: includingTests, arguments: arguments, swiftPMTemporary: TemporaryDirectory.make("swiftpm"))
    }

    /// The build itself, with SwiftPM's temporary directory pointed at `swiftPMTemporary`.
    ///
    /// SwiftPM files a lock for the scratch path and one for the workspace state in `$TMPDIR`, each named for the package's own path (`…_sift-repo-<UUID>_.build.lock`), and never removes either — removing the repository leaves both behind — and the driver leaves its `TemporaryDirectory.*` there too. Given a directory of the caller's scope instead, all of it goes when the scope does.
    private static func swiftBuild(packageAt root: URL, includingTests: Bool, arguments: [String], swiftPMTemporary: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = [
            "build", "--package-path", root.path,
            "-Xswiftc", "-index-store-path",
            "-Xswiftc", root.appendingPathComponent(".build/index/store").path,
        ] + (includingTests ? ["--build-tests"] : []) + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["TMPDIR": swiftPMTemporary.path + "/"]) { _, redirected in redirected }
        let sink = Pipe()
        process.standardOutput = sink
        process.standardError = sink
        try process.run()
        // Read before waiting, for `runGit`'s reason and with a bigger margin: a pipe holds 64 KB and
        // `--build-tests` compiles the testing library, so its output does not fit.
        let output = sink.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitError(message: "swift build failed in test: \(String(data: output, encoding: .utf8)?.suffix(600) ?? "")")
        }
    }

    /// The same build, awaited instead of blocked on.
    ///
    /// `waitUntilExit` parks whatever thread it runs on for the length of a build, and inside an async test that thread is a *cooperative* one. Enough fixtures building at once and the pool has nothing left to schedule with — which is enough to make `ProcessStreamsTests`' ten-second deadline miss about one run in five, with nothing about the code under test having changed. A dedicated thread owes nothing to the pool, and the caller suspends rather than blocking, so the worker goes back to running other tests while the build runs.
    static func swiftBuildSuspending(packageAt root: URL, includingTests: Bool = false, arguments: [String] = []) async throws {
        // Made here, not on the thread: the scope it belongs to is the caller's task's, which the thread does not see.
        let swiftPMTemporary = try TemporaryDirectory.make("swiftpm")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let builder = Thread {
                do {
                    try swiftBuild(packageAt: root, includingTests: includingTests, arguments: arguments, swiftPMTemporary: swiftPMTemporary)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            builder.name = "sift.tests.fixture-build"
            builder.start()
        }
    }

    /// Runs `git` in a fixture repository, returning whatever it printed.
    ///
    /// **The environment is the parent's minus every `GIT_*` key, and that is the load-bearing line.** `git` exports `GIT_DIR`, `GIT_INDEX_FILE` and friends into every hook it runs, and a child process inherits them, so a suite run from a hook — `pre-push`, `git submodule foreach`, anything wrapping `swift test` — would point every one of these fixture repositories at the *real* repository instead: the run fails on lock files it never made, and the fixtures' `seed` commits land on the branch being pushed. `githooks/pre-push` unsets them as well, belt and braces; this is the half that holds for a caller nobody has written yet.
    ///
    /// It is the shipped rule and not a copy of it: ``ProcessEnvironment/withoutGit(from:)`` is what `GitContext` hands its own reads, for the same reason one level up.
    ///
    /// `dated` puts back exactly two keys, the author and committer dates, for a fixture whose history has to be older than the moment it was made — the only way to date a commit's committer, which is the date `git log --since` reads.
    @discardableResult
    static func runGit(_ arguments: [String], in directory: URL, dated date: Date? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessEnvironment.withoutGit()
        if let date {
            let stamp = "@\(Int(date.timeIntervalSince1970)) +0000"
            environment["GIT_AUTHOR_DATE"] = stamp
            environment["GIT_COMMITTER_DATE"] = stamp
        }
        process.environment = environment
        let sink = Pipe()
        process.standardOutput = sink
        process.standardError = sink
        try process.run()
        // Read before waiting, not after. A pipe holds 64 KB, and `git commit` prints `create mode` for
        // every file it adds — so a fixture repo of a few hundred files fills it, git blocks in `write`,
        // and `waitUntilExit` never returns. Reading only on the failure path would leave the success path
        // deadlocking, which is the worst arrangement of the two: the fixtures that hang are the big ones.
        let output = sink.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: output, encoding: .utf8) ?? ""
            throw GitError(message: "git \(arguments.joined(separator: " ")) failed in test: \(text)")
        }
        return String(data: output, encoding: .utf8) ?? ""
    }

    /// Raises a fixture engine to an open budget that survives a cold open under full-suite load.
    ///
    /// A cold open of a big fixture's store can outlast the default budget when the whole suite is running, and the answer then says `warming` rather than what the calling test pins. Named for what makes it necessary rather than for the first fixture that hit it — a SwiftUI fixture was the first, a package built with its tests the second — so every suite reaches for this instead of writing its own `engine.openBudget = 300`.
    static func raiseOpenBudgetForAColdStore(_ engine: SiftEngine) {
        engine.openBudget = 300
    }
}

// MARK: - What a listing weighs

extension TestSources {
    /// What listing every one of `shape`'s failures would weigh, in the bytes ``RunFailureCensus/listingBudget`` is charged for them.
    ///
    /// **Composed by the block that composes listings, one entry at a time, rather than restated here.** Three tests establish their premise on this number — *the size gate is not what refused this listing* — and each built a second estimate of an entry by hand: a name and a location, then a message, and nothing else. An entry is also a `with <arguments>` field, a `↳ note` line, and each of those three clipped at ``RunFailureCensus/wordsCap``. Add a note to a fixture and the real listing crosses the budget while the hand-rolled estimate stays under it: the test goes on passing, its premise goes on reading green, and what it pins is quietly a different rule than the one its doc claims. `RunFailureSitesTests.crowdFitting()` derives its boundary this way for the same reason.
    ///
    /// One failure at a time because a shape of one is always served as a listing — one failure is one signature, which neither the size nor the repetition rule refuses — and a lone entry leads with no measurement line, so what comes back is exactly the entry that failure contributes to a listing of all of them. Two things it deliberately cannot carry, because a listing does not: the `×N` multiplier, which only a sample prints, and a resolved site line, which is ``RunFailureCensus/Entry/uncharged`` and weighs nothing here for the same reason it weighs nothing there.
    static func listingBytes(of shape: RunFailureShape) -> Int {
        shape.failures.reduce(bytes(of: shape.census.heading(of: "failure"))) { total, failure in
            total + bytes(of: RunFailureShape.of([failure], changedFiles: .of([]), paths: shape.paths).rendered())
                + shape.paths.shortening(of: failure.location)
        }
    }

    /// What listing every one of `shape`'s errors would weigh, on the terms above — where an entry is the compiler's whole sentence and whatever detail the linker hung beneath it.
    static func listingBytes(of shape: RunErrorShape) -> Int {
        shape.errors.reduce(bytes(of: shape.census.heading(of: "error"))) { total, error in
            total + bytes(of: RunErrorShape.of([error], changedFiles: .of([]), paths: shape.paths).rendered())
                + shape.paths.shortening(of: error.path)
        }
    }

    /// `lines` as the listing rule weighs them: each one, and the newline that ends it.
    private static func bytes(of lines: some Sequence<String>) -> Int {
        lines.reduce(0) { $0 + $1.utf8.count + 1 }
    }
}
