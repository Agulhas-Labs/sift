//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a nested type's bare name written outside every type: Swift's lookup finds `Net.URL` written bare only inside `Net`, its extensions, the types nested in them and its subtypes, so with no store a line writing `URL` where no type, extension or protocol is around it is counted apart; wherever something may make the name mean the nested type there, the line stays a use.
///
/// Every single-file fixture typechecks with `swiftc -parse-as-library -module-name Lib -swift-version 6`, and each kept line calls a member only the asked type has.
@Suite(.temporaryDirectories)
struct WhereNestedTypeOutsideTests {
    /// The verdict's clause for `count` lines set apart as outside every type.
    private static func setApart(_ count: Int) -> String {
        "; \(count) more line\(count == 1 ? "" : "s") writing \"URL\" bare outside every type, extension and protocol, where the name cannot mean a type nested in another, so not use"
    }

    /// The words every such clause carries, to say none is there.
    private static var anyClause: String {
        "bare outside every type"
    }

    /// `symbol` asked of an unbuilt repo holding `files`, by path, so no index store answers.
    static func answer(_ symbol: String, files: [String: String]) async throws -> String {
        let root = try TestSources.makeTempRepo()
        for (path, source) in files {
            try TestSources.write(source, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "a nested type, unbuilt")
        let engine = try SiftEngine(directory: root)
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh())
    }

    /// The fixture every gate below adds one thing to: a top-level function writing Foundation's `URL` bare, and one writing the nested type's whole path.
    private static var plain: String {
        """
        import Foundation
        enum Net { struct URL { func fetched() {} } }
        func home() -> URL? {
            URL(string: "https://example.com")
        }
        func check(_ x: Net.URL) { x.fetched() }

        """
    }

    /// A top-level function's `URL` and `URL(string:)` are Foundation's: no lookup from there reaches inside `Net`.
    @Test
    func aBareNameAtTheTopLevelIsCountedApart() async throws {
        let url = try await WhereQualifiedProtocolNoteTests.answer("Net.URL", source: Self.plain)

        #expect(url.contains("\"URL\" used by 1 line in 1 file — "), "\(url)")
        #expect(url.contains(Self.setApart(2)), "\(url)")
        #expect(url.contains("\n    :6  | func check(_ x: Net.URL) { x.fetched() }"), "\(url)")
        #expect(!url.contains(":3  |"), "\(url)")
        #expect(!url.contains(":4  |"), "\(url)")
    }

    /// A whole path written at the top level, with or without the module, is the nested type.
    @Test
    func aQualifiedNameAtTheTopLevelKeepsTheLine() async throws {
        let url = try await WhereQualifiedProtocolNoteTests.answer("Net.URL", source: "enum Net { struct URL { func fetched() {} } }\nfunc check(_ x: Lib.Net.URL) { x.fetched() }\nfunc again() { Net.URL().fetched() }\n")

        #expect(url.contains("\"URL\" used by 2 lines in 1 file — "), "\(url)")
        #expect(!url.contains(Self.anyClause), "\(url)")
    }

    /// An extension of `Net` and a type nested in `Net` or in its extension see `Net`'s members bare, as do `Net`'s own methods.
    @Test
    func aBareNameInsideTheNestingTypesScopesKeepsTheLine() async throws {
        let url = try await WhereQualifiedProtocolNoteTests.answer("Net.URL", source: """
        enum Net {
            struct URL { func fetched() {} }
            struct Inner { func take(_ x: URL) { x.fetched() } }
            static func make() -> URL { URL() }
        }
        extension Net {
            struct Deeper { func take(_ x: URL) { x.fetched() } }
        }
        """)

        #expect([3, 4, 7].allSatisfy { url.contains("\n    :\($0)  |") }, "\(url)")
        #expect(!url.contains(Self.anyClause), "\(url)")
    }

    /// A subclass of `Net` inherits its member types, and a type nested in an extension of the subclass, or a class declared in a function, sees them too.
    @Test
    func aBareNameInsideASubtypeOfTheNestingTypeKeepsTheLine() async throws {
        let url = try await WhereQualifiedProtocolNoteTests.answer("Net.URL", source: """
        class Net { struct URL { func fetched() {} } }
        class Sub: Net { func take(_ x: URL) { x.fetched() } }
        extension Sub {
            struct Deep { func take(_ x: URL) { x.fetched() } }
        }
        func probe() {
            class Local: Net { func take(_ x: URL) { x.fetched() } }
        }
        """)

        #expect([2, 4, 7].allSatisfy { url.contains("\n    :\($0)  |") }, "\(url)")
        #expect(!url.contains(Self.anyClause), "\(url)")
    }

    /// `URL` in the extension is `Holder`'s generic parameter, which its where clause makes the nested type; in a protocol it is another declaration's, which the scan cannot rule out.
    @Test
    func aGenericParameterOrAProtocolKeepsTheLine() async throws {
        let url = try await WhereQualifiedProtocolNoteTests.answer("Net.URL", source: """
        enum Net { struct URL { func fetched() {} } }
        struct Holder<URL> {}
        extension Holder where URL == Net.URL {
            func take(_ x: URL) { x.fetched() }
        }
        protocol Fetching { associatedtype URL; func take(_ x: URL) }
        """)

        #expect(url.contains("\n    :4  | func take(_ x: URL) { x.fetched() }"), "\(url)")
        #expect(!url.contains(Self.anyClause), "\(url)")
    }

    /// A file-level typealias of the name makes every bare `URL` the nested type, in an `#if` clause too, and from another file.
    @Test
    func aTopLevelTypealiasOfTheNameKeepsEveryLine() async throws {
        let here = try await WhereQualifiedProtocolNoteTests.answer("Net.URL", source: Self.plain + "#if !DEBUG\ntypealias URL = Net.URL\n#endif\n")
        let elsewhere = try await Self.answer("Net.URL", files: [
            "Sources/Lib/Lib.swift": "enum Net { struct URL { func fetched() {} } }\nfunc home(_ x: URL) { x.fetched() }\n",
            "Sources/Lib/Alias.swift": "typealias URL = Net.URL\n",
        ])

        #expect(here.contains("\n    :3  | func home() -> URL? {"), "\(here)")
        #expect(!here.contains(Self.anyClause), "\(here)")
        #expect(elsewhere.contains("\n    :2  | func home(_ x: URL) { x.fetched() }"), "\(elsewhere)")
        #expect(!elsewhere.contains(Self.anyClause), "\(elsewhere)")
    }

    /// A function or a variable of the name at the top level of another file is what an expression writing it may mean.
    @Test
    func aTopLevelFunctionOrVariableOfTheNameKeepsTheLine() async throws {
        let others = ["func URL(_: String) -> Net.URL { Net.URL() }\n": "URL(\"x\")", "let URL = Net.URL.self\n": "URL.init()"]
        for (other, call) in others {
            let url = try await Self.answer("Net.URL", files: [
                "Sources/Lib/Lib.swift": "enum Net { struct URL { func fetched() {} } }\nfunc home() { \(call).fetched() }\n",
                "Sources/Lib/Other.swift": other,
            ])

            #expect(url.contains("\n    :2  | func home() { \(call).fetched() }"), "\(url)")
            #expect(!url.contains(Self.anyClause), "\(url)")
        }
    }

    /// A local value of the name, `let URL = Net.URL.self`, is what an expression writing it means.
    @Test
    func aValueOfTheNameInTheFileKeepsTheLine() async throws {
        let url = try await WhereQualifiedProtocolNoteTests.answer("Net.URL", source: """
        enum Net { struct URL { func fetched() {} } }
        func make() {
            let URL = Net.URL.self
            URL.init().fetched()
        }
        """)

        #expect(url.contains("\n    :4  | URL.init().fetched()"), "\(url)")
        #expect(!url.contains(Self.anyClause), "\(url)")
    }

    /// A local typealias of the name, a freestanding macro or a custom attribute in the function around the line may make the name the nested type.
    @Test
    func aLocalDeclarationOrMacroKeepsTheLine() async throws {
        let url = try await WhereQualifiedProtocolNoteTests.answer("Net.URL", source: """
        enum Net { struct URL { func fetched() {} } }
        func alias(_ x: Net.URL) {
            typealias URL = Net.URL
            let y: URL = x
            y.fetched()
        }
        func expand() {
            #shim()
            let y: URL? = nil
            y?.fetched()
        }
        """)

        #expect(url.contains("\n    :4  | let y: URL = x"), "\(url)")
        #expect(url.contains("\n    :9  | let y: URL? = nil"), "\(url)")
        #expect(!url.contains(Self.anyClause), "\(url)")
    }

    /// A scoped import of a declaration of the name brings it into the file, as another module's typealias may.
    @Test
    func aScopedImportOfTheNameKeepsTheLine() async throws {
        let url = try await WhereQualifiedProtocolNoteTests.answer("Net.URL", source: "import typealias Ext.URL\nenum Net { struct URL { func fetched() {} } }\nfunc home(_ x: URL) { x.fetched() }\n")

        #expect(url.contains("\n    :3  | func home(_ x: URL) { x.fetched() }"), "\(url)")
        #expect(!url.contains(Self.anyClause), "\(url)")
    }

    /// A freestanding macro expanded at file scope in any file, or a macro the repository declares that introduces the name, may declare the name at the top level.
    @Test
    func aMacroThatMayIntroduceTheNameKeepsTheLine() async throws {
        let expanded = try await Self.answer("Net.URL", files: [
            "Sources/Lib/Lib.swift": Self.plain,
            "Sources/Lib/Other.swift": "#shim()\n",
        ])
        let declared = try await Self.answer("Net.URL", files: [
            "Sources/Lib/Lib.swift": Self.plain,
            "Sources/Macros/Macros.swift": "@freestanding(declaration, names: named(URL))\npublic macro shim() = #externalMacro(module: \"Plugin\", type: \"Shim\")\n",
        ])

        #expect(expanded.contains("\n    :3  | func home() -> URL? {"), "\(expanded)")
        #expect(!expanded.contains(Self.anyClause), "\(expanded)")
        #expect(declared.contains("\n    :3  | func home() -> URL? {"), "\(declared)")
        #expect(!declared.contains(Self.anyClause), "\(declared)")
    }

    /// A macro attached to a declaration at file scope, here another package's peer macro expanding to `typealias URL = Net.URL`, may declare the name beside it for the whole module, in a top-level `#if` clause too.
    ///
    /// Modelled on an `import Dep` the scan never reads: `swift build` of the real shape succeeds only with `@Aliased` there ("cannot find type 'URL' in scope" without it).
    @Test
    func anAttachedMacroAtFileScopeKeepsTheLine() async throws {
        let net = "enum Net { struct URL { func fetched() {} } }\n"
        let uses = "func home() -> URL { URL() }\nfunc check() { home().fetched() }\n"
        let plain = try await Self.answer("Net.URL", files: [
            "Sources/Lib/Net.swift": net,
            "Sources/Lib/Uses.swift": uses,
            "Sources/Lib/Anchor.swift": "import Dep\n@Aliased func anchor() {}\n",
        ])
        let conditional = try await Self.answer("Net.URL", files: [
            "Sources/Lib/Net.swift": net,
            "Sources/Lib/Uses.swift": uses,
            "Sources/Lib/Anchor.swift": "import Dep\n#if canImport(Dep)\n@Dep.Aliased func anchor() {}\n#endif\n",
        ])

        for url in [plain, conditional] {
            #expect(url.contains("\n    :1  | func home() -> URL { URL() }"), "\(url)")
            #expect(!url.contains(Self.anyClause), "\(url)")
        }
    }

    /// A macro the repository declares whose names say the name however spaced, or names it cannot spell ahead, may introduce it.
    @Test
    func aMacroWhoseNamesMayBeTheNameKeepsTheLine() async throws {
        let roles = ["@freestanding(declaration, names: named( URL ))", "@attached(peer, names: prefixed(_))", "@attached(peer, names: overloaded)"]
        for role in roles {
            let url = try await Self.answer("Net.URL", files: [
                "Sources/Lib/Lib.swift": Self.plain,
                "Sources/Macros/Macros.swift": "\(role)\npublic macro shim() = #externalMacro(module: \"Plugin\", type: \"Shim\")\n",
            ])

            #expect(url.contains("\n    :3  | func home() -> URL? {"), "\(role): \(url)")
            #expect(!url.contains(Self.anyClause), "\(role): \(url)")
        }
    }

    /// A typealias of the name in an `#if` clause of the function around the line may make the name the nested type there, whichever way the condition goes.
    @Test
    func aConditionalLocalTypealiasKeepsTheLine() async throws {
        let url = try await WhereQualifiedProtocolNoteTests.answer("Net.URL", source: """
        enum Net { struct URL { func fetched() {} } }
        func conditional() {
            #if swift(>=5.9)
            typealias URL = Net.URL
            #endif
            URL().fetched()
        }
        """)

        #expect(url.contains("\n    :6  | URL().fetched()"), "\(url)")
        #expect(!url.contains(Self.anyClause), "\(url)")
    }
}
