//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A digest target that is one path with a space inside it is answered as that path, on every face and in every record: never split into words, so a missed or misplaced path never serves a file it did not name, and the hook never credits one.
///
/// The fixture holds `Sources/Old/Main View.swift` beside `Sources/App/View.swift`: split on its space, a path to the first ends in a word naming the second. `struct Gizmo` and `Sources/App/Depot.swift` are names a string with no `/` may hold.
@Suite(.temporaryDirectories)
struct DigestSpacedPathTests {
    private static var unrelated: String {
        "Sources/App/View.swift"
    }

    private static var spaced: String {
        "Sources/Old/Main View.swift"
    }

    /// A path to the spaced file in a directory that holds none, a path to no file at all, and a range of a path to no file.
    private static var astray: [String] {
        ["Sources/New/Main View.swift", "Sources/Old/Missing View.swift", "Sources/Old/Missing View.swift:1-2"]
    }

    private static func temporaryRegistry() throws -> RootsRegistry {
        try RootsRegistry(fileURL: TemporaryDirectory.make("roots").appendingPathComponent("roots.json"))
    }

    private static func repository() throws -> URL {
        let root = try MCPTestRepo.make()
        try MCPTestRepo.add([
            unrelated: "struct View {\n    let one = 1\n}\n",
            spaced: "struct Orchard {\n    let two = 2\n}\n",
            "Sources/App/Gizmo.swift": "struct Gizmo {}",
            "Sources/App/Depot.swift": "struct Crate {}",
        ], to: root)
        return root
    }

    // MARK: - The one reading

    @Test(arguments: [
        "Sources/Old/Main View.swift", "Sources/New/Main View.swift", "Sources/My App/ContentView.swift", "Sources/App/Two Words.swift",
        "Sources/Old/Main View.swift:1-2", "Sources/Old/Main View",
    ])
    func aPathWithASpaceInsideItIsOneName(target: String) {
        #expect(DigestSpacedTarget.names(in: target) == [target])
    }

    /// The shapes the split exists for are still split: names alone, a path after a bare name, a whole file before another name, and a string with no `/`, a file name among its words.
    @Test(arguments: [
        "Alpha Gizmo", "Phantom Mirage", "Gizmo Sources/App/Orchard.swift", "Alpha Sources/App/Beta.swift", "Sources/App/Beta.swift Alpha",
        "B Sources/Z/Foo.swift", "Alpha.go Sources/App/Beta.swift", "Sources/B/Foo.swift:12-40 Orchard", "Orchard Sources/B/Foo.swift:12-40",
        "Sources/B/Orchard.swift:5 Depot", "Alpha.swift Beta.swift", "My App.swift", "My File.swift:12-40",
    ])
    func severalNamesAreStillSplit(target: String) {
        #expect(DigestSpacedTarget.names(in: target).count > 1)
    }

    /// The MCP face's note on a spaced miss reads the string as the split does: one path is noted as one path, never with its words offered as targets, and names it would split are offered as targets.
    @Test
    func theSpacedNoteReadsTheStringAsTheSplitDoes() {
        let notes = Self.astray.map { MCPServer.spacedTargetNote(arguments: ["target": $0], missed: true) }

        #expect(notes.allSatisfy { $0?.contains("as one path") == true && $0?.contains("\"Main\"") != true })
        #expect(MCPServer.spacedTargetNote(arguments: ["target": "Gizmo Sources/App/Orchard.swift"], missed: true)?.contains("\"Gizmo\"") == true)
    }

    // MARK: - The answer

    /// The reported defect: a spaced path that missed, or was served from elsewhere, was split on its space, and its last word served an unrelated file.
    @Test(arguments: astray)
    func aStrayPathNeverServesAFileItDidNotName(target: String) async throws {
        let root = try Self.repository()

        let answer = try await DigestCommand.parse([target, "--root", root.path]).answer(registry: Self.temporaryRegistry())

        #expect(!answer.contains("struct View"))
        #expect(!answer.contains(Self.unrelated))
        #expect(!answer.contains("was not served"))
    }

    /// Through the targets list, the one entry point that splits a string, as both faces reach it.
    @Test
    func aPathToNoFileIsAMissForThatPath() async throws {
        let root = try Self.repository()
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()

        let answer = try engine.measuredDigest(targets: ["Sources/Old/Missing View.swift"], options: DigestOptions())

        #expect(answer.missed)
        #expect(answer.parts.isEmpty)
    }

    /// One of several targets is read the same way: the spaced path beside another name serves neither the unrelated file nor a split line.
    @Test
    func aStrayPathAmongSeveralTargetsIsStillOnePath() async throws {
        let root = try Self.repository()

        let answer = try await DigestCommand.parse(["Sources/New/Main View.swift", "Alpha", "--root", root.path])
            .answer(registry: Self.temporaryRegistry())

        #expect(answer.contains("struct Alpha"))
        #expect(!answer.contains("struct View"))
        #expect(!answer.contains("was not served"))
    }

    @Test
    func aSpacedPathThatResolvesServesItsFile() async throws {
        let root = try Self.repository()

        let answer = try await DigestCommand.parse([Self.spaced, "--root", root.path]).answer(registry: Self.temporaryRegistry())

        #expect(answer.contains("struct Orchard"))
        #expect(!answer.contains("struct View"))
    }

    // MARK: - The hook's credit

    /// The usage line a stray spaced path writes credits no read of the unrelated file, whole or windowed: its answer served that file under no name it was given.
    @Test(arguments: astray)
    func theHookCreditsNoFileTheStringDidNotName(target: String) async throws {
        let root = try Self.repository()
        let scratch = try HealedCallAttributionTests.Scratch()
        defer { scratch.cleanup() }
        var entry = try await HealedCallAttributionTests.loggedEntry(calling: "digest", with: ["target": target], on: root, scratch: scratch)
        // Filed under this test's own session: the server logs the one in the environment, which a run may not have.
        entry["session"] = scratch.session
        let digested = try DigestedFilesTests.UsageLogFile([entry]).digested
        let file = root.appendingPathComponent(Self.unrelated).path
        let resolve: (String, String) -> String? = { name, _ in name == "View" ? Self.unrelated : nil }

        #expect(!digested.contains(file, session: scratch.session, agent: nil, resolve: resolve))
        #expect(!digested.locates(file, session: scratch.session, agent: nil, resolve: resolve))
        #expect((entry["parts"] as? [[String: Any]] ?? []).isEmpty)
    }

    // MARK: - A space before the first `/`

    /// The space sits in the first directory, before any `/`: still one path, served as the one file of its name, and that file alone is credited.
    @Test
    func aSpaceInTheFirstDirectoryIsStillOnePath() async throws {
        let root = try Self.repository()
        let scratch = try HealedCallAttributionTests.Scratch()
        defer { scratch.cleanup() }
        let target = "My App/Main View.swift"

        let answer = try await DigestCommand.parse([target, "--root", root.path]).answer(registry: Self.temporaryRegistry())
        var entry = try await HealedCallAttributionTests.loggedEntry(calling: "digest", with: ["target": target], on: root, scratch: scratch)
        entry["session"] = scratch.session
        let digested = try DigestedFilesTests.UsageLogFile([entry]).digested
        let resolve: (String, String) -> String? = { name, _ in name == "View" ? Self.unrelated : nil }
        let credited = { (path: String) in
            digested.contains(root.appendingPathComponent(path).path, session: scratch.session, agent: nil, resolve: resolve)
        }

        #expect(answer.contains("struct Orchard"))
        #expect(!answer.contains("struct View"))
        #expect(!answer.contains("was not served"))
        #expect(credited(Self.spaced))
        #expect(!credited(Self.unrelated))
    }

    /// A path to no file with the space in its first directory is a miss for that path, noted as read as one path, crediting nothing.
    @Test
    func aMissedPathWithASpaceInTheFirstDirectoryIsAMissNotedAsOnePath() async throws {
        let root = try Self.repository()
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        let target = "My App/Old/Missing View.swift"

        let answer = try engine.measuredDigest(targets: [target], options: DigestOptions())

        #expect(answer.missed)
        #expect(answer.parts.isEmpty)
        #expect(!answer.text.contains("struct View"))
        #expect(MCPServer.spacedTargetNote(arguments: ["target": target], missed: true)?.contains("as one path") == true)
    }

    /// In a targets list the same string is one path too: its file served beside the other target's, the unrelated file never.
    @Test
    func aSpaceInTheFirstDirectoryAmongSeveralTargetsIsStillOnePath() async throws {
        let root = try Self.repository()
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()

        let answer = try engine.measuredDigest(targets: ["My App/Main View.swift", "Gizmo"], options: DigestOptions())

        #expect(answer.text.contains("struct Orchard"))
        #expect(answer.text.contains("struct Gizmo"))
        #expect(!answer.text.contains("struct View"))
        #expect(!answer.text.contains("was not served"))
    }

    // MARK: - No `/`

    /// A string with no `/` is split when it names nothing whole, as a type and a file may well be sent together, and says the whole string was tried as one file name first, so a split reads apart from a mistyped file name.
    @Test
    func aTypeAndAFileWithNoSlashAreBothServed() async throws {
        let root = try Self.repository()

        let answer = try await DigestCommand.parse(["Gizmo Depot.swift", "--root", root.path]).answer(registry: Self.temporaryRegistry())

        #expect(answer.contains("struct Gizmo"))
        #expect(answer.contains("struct Crate"))
        #expect(answer.contains("Gizmo Depot.swift was also tried as one file name and matched nothing"))
    }

    /// A directory followed by a bare name is one path by the first `/` word: a miss, noted as read as one path so several names can be sent apart.
    @Test
    func aDirectoryBeforeANameIsAMissNotedAsOnePath() async throws {
        let root = try Self.repository()
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        let target = "Sources/App Gizmo"

        let answer = try engine.measuredDigest(targets: [target], options: DigestOptions())

        #expect(answer.missed)
        #expect(!answer.text.contains("struct Gizmo"))
        #expect(MCPServer.spacedTargetNote(arguments: ["target": target], missed: true)?.contains("as one path") == true)
    }
}
