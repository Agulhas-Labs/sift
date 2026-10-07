//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A type another module of the tree declares, written bare at a site whose file imports that module, is not used to drop the site: the scan cannot see the dependencies, macros and generic parameters that may give the name another meaning, so every such site stays listed.
@Suite(.temporaryDirectories)
struct WhereImportedTypeKeptTests {
    private static var package: String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(name: "App", targets: [
            .target(name: "App", dependencies: ["Kit", "Mid"]),
            .target(name: "Mid", dependencies: ["Kit"]),
            .target(name: "Kit"),
        ])
        """
    }

    private static var kit: String {
        "import Dep\n\npublic struct Crate {\n    public var stock: Int { 1 }\n    public init() {}\n}\n"
    }

    private static var mid: String {
        "import Kit\n\n@Generates public struct Holder {}\n"
    }

    private static var depot: String {
        "struct Depot {\n    var stock = 0\n}\nclass Shelf {}\nstruct Tidy: Shelf {\n    var stock: Int { 1 }\n}\n"
    }

    /// Each way the name may not be the Kit type, by the function holding the site and the App file that writes it.
    private static let kept: [String: String] = [
        "Plain.overloaded()": "import Dep\nimport Kit\n\nstruct Plain {\n    func overloaded() -> Int { Crate().stock }\n}\n",
        "Plain.scoped()": "import struct Dep.Crate\nimport Kit\n\nstruct Plain {\n    func scoped() -> Int { Crate().stock }\n}\n",
        "Plain.freestanding()": "import Kit\n\n#aliasCrate\n\nstruct Plain {\n    func freestanding() -> Int { Crate().stock }\n}\n",
        "Plain.nested()": "import Kit\n\nstruct Plain {\n    #aliasCrate\n    func nested() -> Int { Crate().stock }\n}\n",
        "Plain.peered()": "import Kit\nimport Mid\n\nstruct Plain {\n    func peered() -> Int { Crate().stock }\n}\n",
        "Bag.parameterised()": "import Kit\n\nstruct Bag<Crate> {}\n\nextension Bag {\n    func parameterised() -> Int { Crate().stock }\n}\n",
        "Plain.imported()": "import Kit\n\nstruct Plain {\n    func imported() -> Int { Crate().stock }\n}\n",
    ]

    private static func answer(uses: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(package, to: "Package.swift", in: root)
        try TestSources.write(kit, to: "Sources/Kit/Kit.swift", in: root)
        try TestSources.write(mid, to: "Sources/Mid/Mid.swift", in: root)
        try TestSources.write(depot, to: "Sources/App/Depot.swift", in: root)
        try TestSources.write(uses, to: "Sources/App/Uses.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        return try await CallSiteHeadingTests.lookup("Depot.stock", in: root)
    }

    /// A site writing a name a Kit type shares, however the name may be shadowed, stays listed and none is dropped.
    @Test(arguments: kept.keys.sorted())
    func aSiteWritingAnImportedTreeTypeNameStaysListed(site: String) async throws {
        let output = try await Self.answer(uses: Self.kept[site, default: ""])

        #expect(output.contains("in \(site)"), "\(output)")
        #expect(!output.contains("dropped"), "\(output)")
    }

    /// A supertype written behind a qualifier that is no module or type of the tree, `Dep.Shelf`, is a dependency's even though the tree declares a `Shelf`, so a site on the subtype stays listed, where a subtype of the tree's own `Shelf` is dropped.
    @Test
    func aSupertypeBehindAForeignQualifierIsOutsideTheTree() async throws {
        let output = try await Self.answer(uses: "import Dep\n\nfinal class Sack: Dep.Shelf {}\n\nstruct Plain {\n    func shelved() -> Int { Sack().stock }\n    func tidied() -> Int { Tidy().stock }\n}\n")

        #expect(output.contains("in Plain.shelved()"), "\(output)")
        #expect(!output.contains("in Plain.tidied()"), "\(output)")
        #expect(output.contains("1 on other types dropped"), "\(output)")
    }
}
