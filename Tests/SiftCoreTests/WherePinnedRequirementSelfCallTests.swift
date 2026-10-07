//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A `Self(x)` in an extension of a protocol whose where clause pins `Self` to another type, `extension Maker where Self == Lid`, calls that type's initializer, not the protocol's `init` requirement: the index store records it as `Lid.init`, so the requirement's sweep with no store leaves it out too, listed or held.
@Suite(.temporaryDirectories)
struct WherePinnedRequirementSelfCallTests {
    static func repo() throws -> URL {
        try ProjectedValueCallTests.repo([
            "Sources/Probe/Lid.swift": "struct Lid: Maker {\n    init(size: Int) {}\n}\n",
            "Sources/Probe/Maker.swift": """
            protocol Maker {
                init(size: Int)
            }

            extension Maker where Self == Lid {
                static func make() -> Self { Self(size: 1) }
                static func again() -> Self { Self.init(size: 2) }
            }

            extension Maker {
                static func plain() -> Self { Self(size: 3) }
            }
            """,
        ])
    }

    /// The lines of the maker file `answer` lists as sites, under a heading naming the file with a store (`Maker.swift (1):`) or without one (`Maker.swift:`).
    static func listedLines(_ answer: String) -> [Int] {
        var underMaker = false
        var lines: [Int] = []
        for row in answer.split(separator: "\n") {
            if let heading = row.wholeMatch(of: #/ +(\S+\.swift)(?: \(\d+\))?:/#) {
                underMaker = heading.output.1.hasSuffix("Maker.swift")
            } else if underMaker, let site = row.firstMatch(of: #/^ +:(\d+)  /#), let line = Int(site.output.1) {
                lines.append(line)
            }
        }
        return lines
    }

    @Test
    func aPinnedSelfCallIsNotTheRequirementsWithNoStore() async throws {
        let root = try Self.repo()

        let maker = try await WhereInitializerCallsTests.lookup("Maker.init(size:)", in: root)

        #expect(Self.listedLines(maker) == [11], "\(maker)")
        #expect(!maker.contains("may be Maker's"), "\(maker)")
    }

    /// The store records the pinned calls as the pinned type's initializer and the unpinned one as the requirement's, the split the no-store answer makes.
    @Test
    func theStoreListsTheRequirementsCallsAsTheNoStoreSweepDoes() async throws {
        let root = try Self.repo()
        let unbuilt = try await WhereInitializerCallsTests.lookup("Maker.init(size:)", in: root)

        let built = try await ProjectedValueCallTests.builtLookups(["Maker.init(size:)"], in: root)[0]

        #expect(built.contains("semantic: fresh"), "\(built)")
        #expect(Self.listedLines(built) == Self.listedLines(unbuilt), "store:\n\(built)\nno store:\n\(unbuilt)")
    }
}
