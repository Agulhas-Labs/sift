//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Which typealiases a nested type's name-matched usage folds in: one declared at the top level only where it writes the type's whole path.
@Suite(.temporaryDirectories)
struct WhereNestedTypeAliasFoldTests {
    private static func answer() async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            import Foundation

            enum Net {
                struct URL {
                    func fetched() {}
                }
            }
            typealias Address = URL
            func home() -> Address? { Address(string: "https://example.com") }
            func check(_ link: Net.URL) { link.fetched() }
            extension Net {
                typealias Link = URL
            }
            func open(_ link: Net.Link) { link.fetched() }
            typealias Route = Net.URL
            func walk(_ route: Route) { route.fetched() }
            """,
            to: "Sources/App/Net.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "nested alias fixture, unbuilt")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: "Net.URL", freshness: freshness)
    }

    /// A top-level alias writing only the nested type's last name is the framework type of that name, so its uses are not the nested type's.
    @Test
    func aTopLevelAliasOfTheLastNameIsNotFoldedIn() async throws {
        let output = try await Self.answer()

        #expect(!output.contains("Address(string:"), "\(output)")
        #expect(!output.contains(".Address"), "\(output)")
    }

    /// An alias declared in an extension of the parent, and a top-level one writing the whole path, are other names for the nested type, so their uses stay listed.
    @Test
    func anAliasBesideTheTypeOrWritingItsWholePathStaysFolded() async throws {
        let output = try await Self.answer()

        #expect(output.contains("func open(_ link: Net.Link)"), "\(output)")
        #expect(output.contains("func walk(_ route: Route)"), "\(output)")
    }

    /// The `--refs` answer for `symbol` over a package whose module `Lib` lives in `Sources/LibCore`, holding `files`.
    private static func references(of symbol: String, files: [String: String]) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Lib",
                targets: [.target(name: "Lib", path: "Sources/LibCore")]
            )
            """,
            to: "Package.swift",
            in: root
        )
        for (name, text) in files {
            try TestSources.write(text, to: "Sources/LibCore/\(name)", in: root)
        }
        try TestSources.commitAll(in: root, message: "module-qualified extension fixture, unbuilt")
        let engine = try SiftEngine(directory: root)
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
    }

    /// A type nested in an extension that names its module (`extension Lib.Net`) is still listed through a top-level alias writing its path without the module, kept as a use since the leading name is not proven to be one.
    @Test
    func aTopLevelAliasOfATypeInAModuleQualifiedExtensionStaysListed() async throws {
        let output = try await Self.references(of: "Net.Item", files: [
            "Net.swift": "public enum Net {}\n",
            "Ext.swift": "extension Lib.Net {\n    public struct Item {\n        public init() {}\n    }\n}\n",
            "Alias.swift": "public typealias Piece = Net.Item\n\nfunc f() {\n    _ = Piece()\n}\n",
        ])

        #expect(output.contains("_ = Piece()"), "\(output)")
    }

    /// A type nested in an extension of a framework type that names the framework (`extension Foundation.JSONDecoder`) is still listed through a top-level alias writing the framework type's path without the framework, kept as a use.
    @Test
    func aTopLevelAliasOfATypeInAFrameworkQualifiedExtensionStaysListed() async throws {
        let output = try await Self.references(of: "JSONDecoder.Opts", files: [
            "Opts.swift": """
            import Foundation

            extension Foundation.JSONDecoder {
                public struct Opts {
                    public init() {}
                }
            }

            public typealias Tuning = JSONDecoder.Opts

            func f() {
                _ = Tuning()
            }

            """,
        ])

        #expect(output.contains("_ = Tuning()"), "\(output)")
    }

    /// An extension written through a path whose leading name the tree declares as a top-level type (`extension Net.Inner`) is no module-qualified one, so a top-level alias of the rest of the path names the other top-level type.
    @Test
    func aTopLevelAliasDroppingADeclaredTypeFromAnExtensionPathIsNotFoldedIn() async throws {
        let output = try await Self.references(of: "Net.Inner.Item", files: [
            "Net.swift": """
            enum Net {
                enum Inner {}
            }

            enum Inner {
                struct Item {
                    init() {}
                }
            }

            extension Net.Inner {
                struct Item {
                    init() {}
                }
            }

            typealias Piece = Inner.Item

            func f() {
                _ = Piece()
            }

            """,
        ])

        #expect(!output.contains("_ = Piece()"), "\(output)")
    }

    /// An undeclared leading name of a dotted extension may be a type, not a module: an alias, top-level or nested, writing the path without it may name another type, so its use is kept with that reason and never folded in; one writing the whole dotted path is still proven.
    @Test(arguments: [
        "typealias Alt = ContentMode\n\nfunc f() {\n    _ = Alt.fit\n}\n",
        "enum Box {\n    typealias Alt = ContentMode\n\n    static func f() {\n        _ = Alt.fit\n    }\n}\n",
    ])
    func anAliasDroppingAnUndeclaredLeadingNameIsKeptNotFolded(text: String) async throws {
        let output = try await Self.references(of: "UIView.ContentMode", files: [
            "Ext.swift": "import UIKit\n\nextension UIView.ContentMode {\n    var isFill: Bool { self == .scaleToFill }\n}\n",
            "Alias.swift": text,
        ])

        #expect(output.contains("_ = Alt.fit"), "\(output)")
        #expect(output.contains("which may be a type rather than a module"), "\(output)")
        #expect(!output.contains("folded in here"), "\(output)")
    }

    /// The same extension's alias writing the whole dotted path names it, and is folded in.
    @Test
    func anAliasWritingTheWholeDottedPathIsFoldedIn() async throws {
        let output = try await Self.references(of: "UIView.ContentMode", files: [
            "Ext.swift": "import UIKit\n\nextension UIView.ContentMode {\n    var isFill: Bool { self == .scaleToFill }\n}\n",
            "Alias.swift": "typealias Full = UIView.ContentMode\n\nfunc f() {\n    _ = Full.scaleToFill\n}\n",
        ])

        #expect(output.contains("_ = Full.scaleToFill"), "\(output)")
        #expect(!output.contains("which may be a type rather than a module"), "\(output)")
    }
}
