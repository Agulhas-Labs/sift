//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// Groups are built by complete linkage: A close to B and B close to C make one group of three only when A is close to C too.
struct DupesChainedGroupTests {
    /// A fingerprint spanning six lines in a file of its own, so no two enclose each other and none falls under the size floor.
    static func fingerprint(_ name: String, callees: [String], path: String? = nil, skeleton: [DeclarationFingerprint.ControlToken] = [], typeNames: Set<String> = []) -> DeclarationFingerprint {
        DeclarationFingerprint(
            declaration: StructuralMatch(path: path ?? "Sources/Depot/\(name).swift", line: 1, endLine: 6, kind: "func", qualifiedName: "\(name).run", signature: "func run()"),
            callees: Set(callees),
            skeleton: skeleton,
            typeNames: typeNames
        )
    }

    /// Bodies calling only names of their own, so the rarity weights are the weights of a real tree's rare names.
    static var filler: [DeclarationFingerprint] {
        (0 ..< 20).map { fingerprint("Filler\($0)", callees: ["only\($0)a", "only\($0)b", "only\($0)c"]) }
    }

    /// The chain single linkage made into one group: the left body shares six names with the middle, the right body seven, and the two ends only four of eleven.
    @Test
    func aChainOfPairsIsNotOneGroup() {
        let left = Self.fingerprint("Depot", callees: (1 ... 6).map { "rare\($0)" })
        let middle = Self.fingerprint("Orchard", callees: (1 ... 9).map { "rare\($0)" })
        let right = Self.fingerprint("Catalogue", callees: (3 ... 11).map { "rare\($0)" })
        let found = DupesSearch.answer(scope: [], fingerprints: [left, middle, right] + Self.filler, filesScanned: 23)

        #expect(found.totalGroups == 1)
        #expect(found.groups.map(\.members.count) == [2])
    }
}
