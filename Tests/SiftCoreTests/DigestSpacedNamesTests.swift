//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A digest target with whitespace in it: the whole string first, so a path with a space still resolves, and only where it names nothing as itself the names it is made of.
@Suite(.temporaryDirectories)
struct DigestSpacedNamesTests {
    private static func engine() async throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Gizmo {\n    var size = 1\n}\n", to: "Sources/App/Gizmo.swift", in: root)
        try TestSources.write("struct Orchard {\n    var trees = 2\n}\n", to: "Sources/App/Orchard.swift", in: root)
        try TestSources.write("struct Pair {\n    var halves = 2\n}\n", to: "Sources/App/Two Words.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        return engine
    }

    /// Every name resolving on its own, a string of them is served as the targets list of those names is.
    @Test
    func aTypeAndAPathSentAsOneTargetAreServedAsTwo() async throws {
        let engine = try await Self.engine()

        let spaced = try engine.digest(targets: ["Gizmo Sources/App/Orchard.swift"], options: DigestOptions())
        let listed = try engine.digest(targets: ["Gizmo", "Sources/App/Orchard.swift"], options: DigestOptions())

        #expect(spaced == listed)
        #expect(spaced.contains("struct Orchard"))
        #expect(!spaced.contains("no indexed file"))
        #expect(!spaced.contains("was not served"))
    }

    /// A name that resolves to nothing is named on a line of its own, and the one that resolves is still served.
    @Test
    func aNameThatResolvesNothingIsSaidNotServed() async throws {
        let engine = try await Self.engine()

        let answer = try engine.digest(targets: ["Gizmo Phantom"], options: DigestOptions())

        #expect(answer.hasPrefix("Phantom was not served: pass it as its own target\n"))
        #expect(answer.contains("struct Gizmo"))
    }

    /// The suffix-match note is for a path asked alone: a string of several names never reads as one path that was served another file.
    @Test
    func aStringOfNamesIsNeverAnsweredWithTheServedInsteadNote() async throws {
        let engine = try await Self.engine()

        let answer = try engine.digest(targets: ["Gizmo Sources/Beta/Orchard.swift"], options: DigestOptions())

        #expect(!answer.contains("no indexed file at Gizmo"))
        #expect(answer.contains("struct Gizmo"))
        #expect(answer.contains("struct Orchard"))
    }

    /// A path with a space in it is one file, served as one.
    @Test
    func aPathWithASpaceInItIsOneTarget() async throws {
        let engine = try await Self.engine()

        let answer = try engine.digest(targets: ["Sources/App/Two Words.swift"], options: DigestOptions())

        #expect(answer.contains("struct Pair"))
        #expect(!answer.contains("was not served"))
        #expect(!answer.contains("struct Gizmo"))
    }

    /// Where no name resolves the answer is the whole string's own miss, with nothing said served.
    @Test
    func aStringOfNamesThatResolveNothingKeepsTheWholeStringsMiss() async throws {
        let engine = try await Self.engine()

        let spaced = try engine.measuredDigest(targets: ["Phantom Mirage"], options: DigestOptions())
        let whole = try engine.measuredDigest(target: "Phantom Mirage", options: DigestOptions())

        #expect(spaced == whole)
        #expect(spaced.missed)
    }

    /// An offset is a cursor into one answer, so a string that would be split is refused one, exactly as the targets list is, and never answered as a miss of the whole string.
    @Test
    func anOffsetWithAStringThatWouldSplitIsRefusedAsTheListIs() async throws {
        let engine = try await Self.engine()
        let options = DigestOptions(offset: 1)

        for target in ["Gizmo Phantom", "Gizmo Orchard", "Phantom Mirage"] {
            let refusal = #expect(throws: EngineError.self) {
                try engine.measuredDigest(targets: [target], options: options)
            }
            let listed = #expect(throws: EngineError.self) {
                try engine.measuredDigest(targets: target.split(separator: " ").map(String.init), options: options)
            }
            #expect(refusal.map { "\($0)" } == listed.map { "\($0)" }, "\(target)")
            #expect(refusal.map { "\($0)" }?.contains("this call named 2 targets") == true, "\(target)")
        }
    }

    /// A string that resolves whole keeps paging as it did: the refusal is for a string that would be split.
    @Test
    func anOffsetWithAPathWithASpaceStillPages() async throws {
        let engine = try await Self.engine()

        let answer = try engine.measuredDigest(targets: ["Sources/App/Two Words.swift"], options: DigestOptions(offset: 1))

        #expect(!answer.missed)
    }

    /// A split answer carries the source its parts stand in for, summed, so a saving is measured for it as for the calls it stands for.
    @Test
    func aSplitAnswerSumsTheSourceItsPartsStandInFor() async throws {
        let engine = try await Self.engine()

        let spaced = try engine.measuredDigest(targets: ["Gizmo Sources/App/Orchard.swift"], options: DigestOptions())
        let gizmo = try engine.measuredDigest(target: "Gizmo", options: DigestOptions())
        let orchard = try engine.measuredDigest(target: "Sources/App/Orchard.swift", options: DigestOptions())

        #expect(spaced.bytes?.source == (gizmo.bytes?.source ?? 0) + (orchard.bytes?.source ?? 0))
        #expect((spaced.bytes?.source ?? 0) > 0)
    }
}
