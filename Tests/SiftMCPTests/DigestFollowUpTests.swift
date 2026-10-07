//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers attributing a ranged read back to the digest member it took — the report on what digests are not carrying.
struct DigestFollowUpTests {
    private static var answer: String {
        """
        head: abc1234  dirty: 0  parse_errors: 0  semantic: syntactic-only
        CrateData — LibCore — Sources/Models/CrateData.swift:9-54 (+1 extension)
        package struct CrateData: Equatable

        stored properties:
          package let width: Double?  :11  /// Bay width in metres.

        members:
          package init(width: Double?)  :33-53

        extension CrateData (package) — Sources/Models/CrateData.swift:56-134
          struct CrateSet: Identifiable, Equatable — 5 members  :58-70
          enum Finish: Int, Equatable — 8 cases/members: matte gloss satin  :103-133
        """
    }

    private static func toolUse(_ name: String, id: String, at timestamp: String? = nil, input: [String: Any]) -> Data {
        var object: [String: Any] = [
            "type": "assistant",
            "message": ["content": [["type": "tool_use", "id": id, "name": name, "input": input]]],
        ]
        if let timestamp {
            object["timestamp"] = timestamp
        }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private static func digestResult(id: String, text: String) -> Data {
        let object: [String: Any] = [
            "type": "user",
            "message": ["content": [["type": "tool_result", "tool_use_id": id, "content": [["type": "text", "text": text]]]]],
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// Folds a digest of `CrateData` and then one read of it, returning what the read was attributed to.
    private static func followUp(read: [String: Any]) -> DigestFollowUp {
        var scan = DigestFollowUpScan()
        scan.consume(line: toolUse("mcp__sift__digest", id: "d1", input: ["target": "CrateData"]))
        scan.consume(line: digestResult(id: "d1", text: answer))
        scan.consume(line: toolUse("Read", id: "r1", input: read))
        return scan.result
    }

    /// A container shown as `— 5 members` gave a number where the names were the content, and the read went to get them.
    @Test
    func aReadOfAContainerShownOnlyAsACountIsRecordedAsSuch() {
        let result = Self.followUp(read: ["file_path": "/repo/Sources/Models/CrateData.swift", "offset": 58, "limit": 13])

        #expect(result.collapsedNested == 1)
        #expect(result.namedMember == 0)
        #expect(result.collapsed.map(\.name) == ["struct CrateSet: Identifiable, Equatable"])
    }

    /// The same shape of line, once it carries names, is no longer a gap — this is what tells the two apart, and the whole report turns on it.
    @Test
    func aContainerThatListedItsNamesIsNotCountedAsAGap() {
        let result = Self.followUp(read: ["file_path": "/repo/Sources/Models/CrateData.swift", "offset": 103, "limit": 31])

        #expect(result.collapsedNested == 0)
        #expect(result.namedMember == 1)
    }

    /// A read of a member the digest spelled out and located is the loop working, not a gap.
    @Test
    func aReadOfANamedMemberIsTheLoopWorking() {
        let result = Self.followUp(read: ["file_path": "/repo/Sources/Models/CrateData.swift", "offset": 33, "limit": 21])

        #expect(result.namedMember == 1)
        #expect(result.collapsedNested == 0)
    }

    /// Taking back most of what the digest described is not a verdict on any one member.
    @Test
    func aReadOfEssentiallyTheWholeDeclarationIsNotAttributedToAMember() {
        let result = Self.followUp(read: ["file_path": "/repo/Sources/Models/CrateData.swift", "offset": 1, "limit": 140])

        #expect(result.wholeDeclaration == 1)
        #expect(result.namedMember == 0)
        #expect(result.collapsedNested == 0)
    }

    /// Only a ranged read says what was wanted; a whole-file read took everything and names nothing.
    @Test
    func aWholeFileReadSaysNothingAboutWhichMemberWasWanted() {
        let result = Self.followUp(read: ["file_path": "/repo/Sources/Models/CrateData.swift"])

        #expect(result.total == 0)
    }

    /// A read of a file no digest described cannot be attributed to one.
    @Test
    func aReadOfAnUndigestedFileIsNotAttributed() {
        let result = Self.followUp(read: ["file_path": "/repo/Sources/Models/Elsewhere.swift", "offset": 10, "limit": 5])

        #expect(result.total == 0)
    }

    /// A ranged read of a digested file after `--until` isn't attributed — the follow-up scan's window cuts the same way the audit's own lookup window does.
    @Test
    func aRangedReadAfterUntilIsNotAttributed() {
        var scan = DigestFollowUpScan(until: TranscriptScan.instant("2026-08-02T00:00:00Z"))
        scan.consume(line: Self.toolUse("mcp__sift__digest", id: "d1", input: ["target": "CrateData"]))
        scan.consume(line: Self.digestResult(id: "d1", text: Self.answer))
        scan.consume(line: Self.toolUse(
            "Read", id: "r1", at: "2026-08-02T09:00:00Z",
            input: ["file_path": "/repo/Sources/Models/CrateData.swift", "offset": 33, "limit": 21]
        ))

        #expect(scan.result.total == 0)
    }

    /// `locatedNames` returns a set, so taking `.first` of a qualified target would pick between `Module` and `Type` at random — `Hasher` is seeded per process, and the same transcript would then report different numbers on successive runs of the same binary.
    @Test
    func aModuleQualifiedDigestIsFiledUnderEveryStemItCouldMean() {
        var scan = DigestFollowUpScan()
        scan.consume(line: Self.toolUse("mcp__sift__digest", id: "d1", input: ["target": "LibCore.CrateData"]))
        scan.consume(line: Self.digestResult(id: "d1", text: Self.answer))
        scan.consume(line: Self.toolUse("Read", id: "r1", input: ["file_path": "/repo/Sources/Models/CrateData.swift", "offset": 33, "limit": 21]))

        #expect(scan.result.namedMember == 1)
    }

    /// `digest`'s several targets arrive as a list, so a read of the file any one of them could mean has to attribute the same way a single-target digest's would.
    @Test
    func aSeveralTargetsDigestIsFiledUnderStemsFromEveryTarget() {
        var scan = DigestFollowUpScan()
        scan.consume(line: Self.toolUse("mcp__sift__digest", id: "d1", input: ["targets": ["Engine.start", "LibCore.CrateData"]]))
        scan.consume(line: Self.digestResult(id: "d1", text: Self.answer))
        scan.consume(line: Self.toolUse("Read", id: "r1", input: ["file_path": "/repo/Sources/Models/CrateData.swift", "offset": 33, "limit": 21]))

        #expect(scan.result.namedMember == 1)
    }

    /// A read of a different region of the file asked for enough lines to look like the whole declaration, and was scored as having taken it.
    ///
    /// Judging by the read's own `limit` rather than by what it overlapped put a read pointing somewhere else entirely into "essentially the whole declaration again".
    @Test
    func aReadOfADifferentRegionIsNotScoredAsTakingTheWholeDeclaration() {
        let result = Self.followUp(read: ["file_path": "/repo/Sources/Models/CrateData.swift", "offset": 500, "limit": 200])

        #expect(result.wholeDeclaration == 0)
        #expect(result.unrecordedContent == 1)
    }

    /// Below the last declaration a digest described is what the visitor skips — a `#if DEBUG` `#Preview` block above all.
    ///
    /// Filing those as "no member covers those lines" overstates digest defects: the preview is skipped on purpose, so nothing was ever going to record it.
    @Test
    func aReadBelowEverythingDescribedIsContentNoDigestRecords() {
        let result = Self.followUp(read: ["file_path": "/repo/Sources/Models/CrateData.swift", "offset": 140, "limit": 20])

        #expect(result.unrecordedContent == 1)
        #expect(result.unattributed == 0)
    }

    /// Above the first declaration there is nothing but the file-head doc comment and the imports.
    @Test
    func aReadAboveEverythingDescribedIsTheFileHeadNotAGap() {
        let result = Self.followUp(read: ["file_path": "/repo/Sources/Models/CrateData.swift", "offset": 1, "limit": 8])

        #expect(result.unrecordedContent == 1)
        #expect(result.unattributed == 0)
    }

    /// A read landing *between* two described members is the remainder, and it is the one that reads as a defect.
    ///
    /// The digest described lines either side of these and said nothing about them, which is a claim about the digest rather than about what a digest records — so it keeps the row the split exists to leave honest.
    @Test
    func aReadInAGapBetweenDescribedMembersStaysTheDefectSignal() {
        let fileAnswer = """
        head: abc1234  dirty: 0  parse_errors: 0  semantic: syntactic-only
        Sources/Models/Gapped.swift — module: LibCore

            func first() -> Int  :10-14
            func second() -> Int  :60-64
        """
        var scan = DigestFollowUpScan()
        scan.consume(line: Self.toolUse("mcp__sift__digest", id: "d1", input: ["target": "Sources/Models/Gapped.swift"]))
        scan.consume(line: Self.digestResult(id: "d1", text: fileAnswer))
        scan.consume(line: Self.toolUse("Read", id: "r1", input: ["file_path": "/repo/Sources/Models/Gapped.swift", "offset": 30, "limit": 10]))

        #expect(scan.result.unattributed == 1)
        #expect(scan.result.unrecordedContent == 0)
    }

    /// An open-ended read below the last declaration runs to the end of the file, which is where the previews are.
    @Test
    func anOpenEndedReadBelowEverythingDescribedIsAlsoUnrecordedContent() {
        let result = Self.followUp(read: ["file_path": "/repo/Sources/Models/CrateData.swift", "offset": 200])

        #expect(result.unrecordedContent == 1)
        #expect(result.unattributed == 0)
    }

    /// A container with nothing in it withheld no names, so it is not the gap the report calls actionable.
    @Test
    func anEmptyContainerIsNotAGapAnyoneCanAct() {
        let members = DigestAnswer.members(in: "  protocol Marker — 0 members  :10-12")

        #expect(members.count == 1)
        #expect(members[0].collapsed == false)
    }

    /// The colons in a signature are not line ranges, and reading one as a range would attribute the member to whatever line the parameter type happened to spell.
    @Test
    func aSignaturesOwnColonsAreNotReadAsLineRanges() {
        let members = DigestAnswer.members(in: "  func save(to url: URL, retries: Int = 3) -> Bool  :42-58")

        #expect(members.count == 1)
        #expect(members[0].low == 42)
        #expect(members[0].high == 58)
    }

    /// A file digest lists a container and its children, so a read of a named member overlaps the container line above it too.
    ///
    /// Attributing it to the container scores the loop working as the gap it exists to detect — and does it for every ranged read that follows a file digest, inflating the row on any machine whose sessions digest files.
    @Test
    func aMemberReadUnderAFileDigestBeatsTheContainerLineAboveIt() {
        let fileAnswer = """
        head: abc1234  dirty: 0  parse_errors: 0  semantic: syntactic-only
        Sources/Models/CrateData.swift — module: LibCore

        struct CrateData — 12 members  :9-200
            package let width: Double?  :11
            package init(width: Double?)  :33-53
        """
        var scan = DigestFollowUpScan()
        scan.consume(line: Self.toolUse("mcp__sift__digest", id: "d1", input: ["target": "Sources/Models/CrateData.swift"]))
        scan.consume(line: Self.digestResult(id: "d1", text: fileAnswer))
        scan.consume(line: Self.toolUse("Read", id: "r1", input: ["file_path": "/repo/Sources/Models/CrateData.swift", "offset": 33, "limit": 21]))

        #expect(scan.result.namedMember == 1)
        #expect(scan.result.collapsedNested == 0)
    }

    /// A stored property advertises a zero-span range, so narrowest-overlap alone let it beat the collapsed container the read had plainly gone for.
    ///
    /// Containment is tested before width for that reason — and the error mattered in the flattering direction, understating the one row the audit exists to surface.
    @Test
    func aZeroSpanNeighbourDoesNotBeatTheContainerTheReadCovered() {
        let fileAnswer = """
        head: abc1234  dirty: 0  parse_errors: 0  semantic: syntactic-only
        Sources/Models/CrateData.swift — module: LibCore

        struct CrateData — 12 members  :9-200
            let width: Double?  :100
            enum Kind — 9 cases/members  :120-200
        """
        var scan = DigestFollowUpScan()
        scan.consume(line: Self.toolUse("mcp__sift__digest", id: "d1", input: ["target": "Sources/Models/CrateData.swift"]))
        scan.consume(line: Self.digestResult(id: "d1", text: fileAnswer))
        // From the property through the enum, so the zero-span line is genuinely inside the read and competes.
        scan.consume(line: Self.toolUse("Read", id: "r1", input: ["file_path": "/repo/Sources/Models/CrateData.swift", "offset": 100, "limit": 101]))

        #expect(scan.result.collapsedNested == 1)
        #expect(scan.result.namedMember == 0)
        // The container the read actually covered, not merely *a* collapsed one: asserting the count alone would let
        // a wrong rule pass this case while attributing it to the enclosing struct.
        #expect(scan.result.collapsed.map(\.name) == ["enum Kind"])
    }

    /// A file digest renders its top-level line in the count form and then enumerates every child beneath it, so the line names nothing while the answer names everything.
    ///
    /// No tie-break fixes this — each trades one class of false positive for another — because the fault is in the classifier: a container with a listed member inside it withheld nothing.
    @Test
    func aContainerWhoseChildrenAreListedBeneathItIsNotShownAsACount() {
        let members = DigestAnswer.members(in: """
        struct RootResolver — 7 members  :12-104
            public static func resolve(directory: URL) throws -> ResolvedRoot  :18-48
            private static func probe(_ target: String) -> Bool  :50-70
        """)

        #expect(members.count == 3)
        #expect(members[0].collapsed == false)
    }

    /// A nested type genuinely shown as a count keeps its verdict — nothing of it is listed, which is the whole complaint.
    @Test
    func aContainerWithNothingListedInsideItStaysACount() {
        let members = DigestAnswer.members(in: """
        struct CrateData — 12 members  :9-200
            enum Kind — 9 cases/members  :120-140
            func summary() -> String  :150-160
        """)

        #expect(members[0].collapsed == false)
        #expect(members[1].collapsed == true)
    }

    /// A read that overruns its member's advertised range by a line is the loop working, and must not fall through to the container above it.
    ///
    /// Requiring containment lost the member the moment a read asked for one line more than the digest advertised, which is both commoner than the case it fixed and the flattering direction to be wrong in.
    @Test
    func aReadThatOverrunsItsMemberByOneLineStillBelongsToIt() {
        let fileAnswer = """
        head: abc1234  dirty: 0  parse_errors: 0  semantic: syntactic-only
        Sources/Core/DigestRenderer.swift — module: SiftCore

        struct DigestRenderer — 26 members  :10-479
            func render(target: String) throws -> String  :34-64
        """
        var scan = DigestFollowUpScan()
        scan.consume(line: Self.toolUse("mcp__sift__digest", id: "d1", input: ["target": "Sources/Core/DigestRenderer.swift"]))
        scan.consume(line: Self.digestResult(id: "d1", text: fileAnswer))
        scan.consume(line: Self.toolUse("Read", id: "r1", input: ["file_path": "/repo/Sources/Core/DigestRenderer.swift", "offset": 34, "limit": 32]))

        #expect(scan.result.namedMember == 1)
        #expect(scan.result.collapsedNested == 0)
    }
}
