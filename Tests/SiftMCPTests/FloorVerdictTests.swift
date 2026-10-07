//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// Covers how a floor verdict places a read, where the filesystem has a say: the case policy it compares under, and the volume that policy is asked of.
///
/// `TranscriptScanTests` covers the placement end to end, on whatever volume the suite runs on; these pin both policies whatever that volume is.
struct FloorVerdictTests {
    private static let belowFloor = SourcePassthrough.FileVerdict(path: "Sources/App/Model.swift", servedSource: true)

    /// A call made from `/work/depot` and answered `tree: Depot`, under the given case policy.
    private static func verdict(caseSensitive: Bool, sourceLocation: SourceLocation = #_sourceLocation) throws -> FloorVerdict {
        try #require(
            FloorVerdict(
                belowFloor,
                anchor: "/work/depot",
                adopted: nil,
                tree: WorkingTree(repository: "Depot"),
                caseSensitive: { _ in caseSensitive }
            ),
            sourceLocation: sourceLocation
        )
    }

    /// Where the volume ignores case, the directory the call was made from and the tree's name are the same directory under any spelling, and a read spelled either way is that file.
    @Test(arguments: ["/work/Depot/Sources/App/Model.swift", "/work/depot/Sources/App/Model.swift", "/WORK/DEPOT/sources/app/model.swift"])
    func aCaseInsensitiveVolumePlacesEverySpellingOfTheFile(read: String) throws {
        #expect(try Self.verdict(caseSensitive: false).decides(read))
    }

    /// Where the volume heeds case, a spelling that differs is another directory: the tree's name does not match it, and it is not the directory the call was made from.
    @Test(arguments: ["/work/Depot/Sources/App/Model.swift", "/work/depot/sources/App/Model.swift"])
    func aCaseSensitiveVolumePlacesOnlyTheSpellingItHolds(read: String) throws {
        let verdict = try Self.verdict(caseSensitive: true)

        #expect(!verdict.decides(read))
        #expect(!verdict.decides("/work/depot/Sources/App/Model.swift"))
    }

    /// The same checkout named in the header's own case decides under a case-sensitive volume, so what the previous test rules out is the spelling and nothing else.
    @Test
    func aCaseSensitiveVolumePlacesTheFileWhereTheNamesAgree() throws {
        let verdict = try #require(FloorVerdict(
            Self.belowFloor,
            anchor: "/work/Depot",
            adopted: nil,
            tree: WorkingTree(repository: "Depot"),
            caseSensitive: { _ in true }
        ))

        #expect(verdict.decides("/work/Depot/Sources/App/Model.swift"))
    }

    /// The policy is asked of the directory the call named, and of the repository the answer resolved to only where the call named none.
    @Test(arguments: [(anchor: String?.some("/work"), asked: "/work"), (anchor: nil, asked: "/work/big")])
    func theVolumeAskedIsTheCallsOwn(anchor: String?, asked: String) {
        var askedOf: [String] = []
        _ = FloorVerdict(Self.belowFloor, anchor: anchor, adopted: "/work/big", tree: nil) { path in
            askedOf.append(path)
            return true
        }

        #expect(askedOf == [asked])
    }

    /// A path that no longer exists is asked of the nearest directory above it that does — the deepest one answering — and nothing answering at all is the platform's default, which ignores case.
    @Test
    func theVolumeIsAskedOfTheNearestDirectoryThatAnswers() {
        let answering = ["/work": true, "/": false]
        let lookup: (URL) -> Bool? = { answering[$0.path] }

        #expect(FloorVerdict.volumeIsCaseSensitive(at: "/work/depot/Sources", lookup: lookup))
        #expect(!FloorVerdict.volumeIsCaseSensitive(at: "/elsewhere/depot", lookup: lookup))
        #expect(!FloorVerdict.volumeIsCaseSensitive(at: "/work/depot") { _ in nil })
    }
}
