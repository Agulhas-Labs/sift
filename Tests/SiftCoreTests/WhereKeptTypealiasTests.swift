//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Typealiases a no-store `where` keeps rather than folds, beside the ones it proves: a kept alias never crowds a proven one out of the fold, and every use of either is listed.
@Suite(.temporaryDirectories)
struct WhereKeptTypealiasTests {
    /// The `--refs` answer for `symbol` over a tree holding `files`, none of them a `Package.swift`, so every module is guessed from the path.
    private static func references(of symbol: String, files: [String: String]) async throws -> String {
        let root = try TestSources.makeTempRepo()
        for (path, text) in files {
            try TestSources.write(text, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "kept typealias fixture, unbuilt")
        let engine = try SiftEngine(directory: root)
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
    }

    /// `Sources/App/Link.swift`: a top-level `URL` whose module is guessed, `count` aliases writing it behind a leading name (`Foundation.URL`), each used, and then, where `proven` is set, an alias proven to name it, used last.
    private static func keptAliases(_ count: Int, proven: Bool) -> String {
        let kept = (0 ..< count).map { "typealias Link\($0) = Foundation.URL\nfunc use\($0)() { _ = Link\($0)() }\n" }.joined()
        let tail = proven ? "typealias Hold = URL\nfunc g() { _ = Hold() }\n" : ""
        return "struct URL {\n    init() {}\n}\n" + kept + tail
    }

    /// As many kept aliases as the fold follows leave room for a proven one: its use is listed and folded in, not dropped behind a lower-bound note.
    @Test
    func keptAliasesLeaveAProvenOneInTheFold() async throws {
        let cap = WhereRenderer.typealiasFoldCap
        let output = try await Self.references(of: "URL", files: ["Sources/App/Link.swift": Self.keptAliases(cap, proven: true)])

        #expect(output.contains("| func g() { _ = Hold() }"), "\(output)")
        #expect(output.contains("1 written as Sources.Hold, a typealias naming it, folded in here"), "\(output)")
        #expect(!output.contains("so the count is a lower bound"), "\(output)")
    }

    /// More kept aliases than the fold follows are all kept: no use of one drops, so nothing is a lower bound.
    @Test
    func keptAliasesPastTheCapAreAllListed() async throws {
        let cap = WhereRenderer.typealiasFoldCap
        let output = try await Self.references(of: "URL", files: ["Sources/App/Link.swift": Self.keptAliases(cap + 1, proven: false)])

        #expect(output.contains("| func use\(cap)() { _ = Link\(cap)() }"), "\(output)")
        #expect(output.contains("\(cap + 1) written as"), "\(output)")
        #expect(!output.contains("so the count is a lower bound"), "\(output)")
    }

    /// A kept alias sharing its name with a proven one keeps the uses of the name, naming both, since a scan by name cannot tell which of them a use writes: here the top-level `Link`, kept, is the one `f` writes.
    @Test
    func aKeptAliasSharingAProvenOnesNameIsNamed() async throws {
        let output = try await Self.references(of: "Net.URL", files: ["Sources/App/Net.swift": """
        enum Net {
            struct URL {
                init() {}
            }
        }

        enum Holder {
            typealias Link = Net.URL
        }

        typealias Link = App.Net.URL

        func f() {
            _ = Link()
        }

        """])

        #expect(output.contains(":14  | _ = Link()"), "\(output)")
        #expect(output.contains(
            "1 written as Sources.Link (App.Net.URL), a typealias of its path behind a leading name that may be its module, and Sources.Holder.Link, a typealias naming it whose name a kept one shares, kept as a use though not proven to name it, as this type's module is guessed from the path"
        ), "\(output)")
        #expect(!output.contains("folded in here"), "\(output)")
    }

    /// An alias of a kept alias writes no leading name of its own, so the clause calls it what it is rather than one writing the type's path behind a leading name.
    @Test
    func anAliasOfAKeptAliasIsNamedAsOne() async throws {
        let output = try await Self.references(of: "Net.URL", files: ["Sources/App/Net.swift": """
        enum Net {
            struct URL {
                init() {}
            }
        }

        typealias Link = App.Net.URL
        typealias Hold = Link

        func f() {
            _ = Hold()
        }

        """])

        #expect(output.contains(":11  | _ = Hold()"), "\(output)")
        #expect(output.contains(
            "written as Sources.Link (App.Net.URL), a typealias of its path behind a leading name that may be its module, and Sources.Hold (Link), an alias of a kept typealias, kept as uses though not proven to name it"
        ), "\(output)")
    }
}
