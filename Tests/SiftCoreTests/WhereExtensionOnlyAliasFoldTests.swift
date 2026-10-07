//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Typealiases of a type the tree only extends, which a no-store `where` cannot prove name it because the extension does not say which module's type it is: their uses are kept, never dropped, and never worded as folded.
@Suite(.temporaryDirectories)
struct WhereExtensionOnlyAliasFoldTests {
    /// Two declared modules, `Lib` at `Sources/Lib` and `Other` at `Sources/Other`.
    private static var manifest: String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "Lib",
            targets: [.target(name: "Lib", path: "Sources/Lib"), .target(name: "Other", path: "Sources/Other")]
        )

        """
    }

    /// An extension of a framework type by its bare name, and an alias writing the framework's module before it.
    private static var extensionFile: String {
        """
        import Foundation

        extension JSONDecoder {
            func tuned() -> JSONDecoder { self }
        }

        typealias Dec = Foundation.JSONDecoder

        func f() {
            _ = Dec()
        }

        """
    }

    private static var reason: String {
        "kept as a use though not proven to name it, as its path starts at an extension of a type its module does not visibly declare, whose module is unknown"
    }

    /// The `--refs` answer for `symbol` over a tree holding `files`.
    private static func references(of symbol: String, files: [String: String]) async throws -> String {
        let root = try TestSources.makeTempRepo()
        for (path, text) in files {
            try TestSources.write(text, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "extension-only alias fixture, unbuilt")
        let engine = try SiftEngine(directory: root)
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
    }

    /// An alias writing another module before a type the tree only extends may name it, so its uses are kept and say why, and its declaration line stays a use.
    @Test
    func anAliasOfATypeTheTreeOnlyExtendsIsKept() async throws {
        let output = try await Self.references(of: "JSONDecoder", files: ["Package.swift": Self.manifest, "Sources/Lib/Ext.swift": Self.extensionFile])

        #expect(output.contains(":10  | _ = Dec()"), "\(output)")
        #expect(output.contains(":7  | typealias Dec = Foundation.JSONDecoder"), "\(output)")
        #expect(output.contains("1 written as Lib.Dec (Foundation.JSONDecoder), a typealias of its path behind a leading name that may be its module, \(Self.reason)"), "\(output)")
        #expect(!output.contains("folded in here"), "\(output)")
    }

    /// The extension's own module written before the path is no proof either: that module declares no such type, so the alias is kept, at the top level or nested.
    @Test(arguments: [
        "typealias Own = Lib.JSONDecoder\n\nfunc g() {\n    _ = Own()\n}\n",
        "enum Box {\n    typealias Own = Lib.JSONDecoder\n\n    static func g() {\n        _ = Own()\n    }\n}\n",
    ])
    func anAliasWritingTheExtensionsOwnModuleIsKept(text: String) async throws {
        let output = try await Self.references(of: "JSONDecoder", files: [
            "Package.swift": Self.manifest,
            "Sources/Lib/Ext.swift": Self.extensionFile,
            "Sources/Lib/Own.swift": text,
        ])

        #expect(output.contains("_ = Own()"), "\(output)")
        #expect(output.contains("(Lib.JSONDecoder)"), "\(output)")
        #expect(output.contains(Self.reason) || output.contains(Self.reason.replacingOccurrences(of: "as a use", with: "as uses")), "\(output)")
        #expect(!output.contains("folded in here"), "\(output)")
    }

    /// An alias writing the bare name names what the extension extends wherever the extension is visible, so it still folds.
    @Test
    func anAliasWritingTheBareNameStillFolds() async throws {
        let output = try await Self.references(of: "JSONDecoder", files: [
            "Package.swift": Self.manifest,
            "Sources/Lib/Ext.swift": Self.extensionFile,
            "Sources/Lib/Plain.swift": "typealias Plain = JSONDecoder\n\nfunc g() {\n    _ = Plain()\n}\n",
        ])

        #expect(output.contains("_ = Plain()"), "\(output)")
        #expect(output.contains("1 written as Lib.Plain, a typealias naming it, folded in here"), "\(output)")
    }

    /// Where the module is also guessed from the path, the reason given is the extension's, which is what leaves the module unknown.
    @Test
    func theExtensionsReasonOutranksAGuessedModule() async throws {
        let output = try await Self.references(of: "JSONDecoder", files: ["Sources/App/Ext.swift": Self.extensionFile])

        #expect(output.contains(":10  | _ = Dec()"), "\(output)")
        #expect(output.contains(Self.reason), "\(output)")
        #expect(!output.contains("this type's module is guessed from the path"), "\(output)")
    }

    /// An extension that writes the module names the type in full, so an alias writing another module before it names another type and stays out.
    @Test
    func anExtensionWritingItsModuleKeepsAnotherModulesAliasOut() async throws {
        let output = try await Self.references(of: "Foundation.JSONDecoder", files: [
            "Package.swift": Self.manifest,
            "Sources/Lib/Ext.swift": Self.extensionFile
                .replacingOccurrences(of: "extension JSONDecoder", with: "extension Foundation.JSONDecoder")
                .replacingOccurrences(of: "Dec = Foundation.JSONDecoder", with: "Dec = Other.JSONDecoder"),
        ])

        #expect(output.contains("extension Foundation.JSONDecoder"), "\(output)")
        #expect(!output.contains("_ = Dec()"), "\(output)")
        #expect(!output.contains("kept as"), "\(output)")
    }

    /// A bare name resolves a type the tree knows only through an extension that writes its module, answered as that extension; an alias writing the whole dotted path is folded in, and one writing the bare name is kept, since the leading name is not proven to be a module.
    @Test
    func aBareNameResolvesAnExtensionWrittenThroughItsModule() async throws {
        let output = try await Self.references(of: "JSONDecoder", files: [
            "Package.swift": Self.manifest,
            "Sources/Lib/Ext.swift": Self.extensionFile.replacingOccurrences(of: "extension JSONDecoder", with: "extension Foundation.JSONDecoder"),
            "Sources/Lib/Bare.swift": "typealias Bare = JSONDecoder\n\nfunc h() {\n    _ = Bare()\n}\n",
        ])

        #expect(!output.contains("nearest symbols"), "\(output)")
        #expect(output.contains("Lib.Foundation.JSONDecoder — extension — extension Foundation.JSONDecoder — Sources/Lib/Ext.swift:3-5"), "\(output)")
        #expect(output.contains(":10  | _ = Dec()"), "\(output)")
        #expect(output.contains("_ = Bare()"), "\(output)")
        #expect(output.contains("1 written as Lib.Dec, a typealias naming it, folded in here"), "\(output)")
        #expect(output.contains("which may be a type rather than a module"), "\(output)")
    }

    /// A dotted extension beside a private type of its final name may extend another type, so an alias writing its whole path is kept as a use, not dropped and not folded in, when the bare name finds only the private type.
    @Test
    func aDottedExtensionBesideAPrivateTwinKeepsItsAliasUses() async throws {
        let output = try await Self.references(of: "JSONDecoder", files: [
            "Package.swift": Self.manifest,
            "Sources/Lib/Ext.swift": Self.extensionFile.replacingOccurrences(of: "extension JSONDecoder", with: "extension Foundation.JSONDecoder"),
            "Sources/Lib/Twin.swift": "private struct JSONDecoder {}\n",
        ])

        #expect(output.contains(":10  | _ = Dec()"), "\(output)")
        #expect(!output.contains("folded in here"), "\(output)")
        #expect(output.contains("may extend another type of the name than the one asked"), "\(output)")
    }

    /// A dotted extension beside a nested type of its final name, or a typealias of it, may extend another type just as beside a private one: the bare name finds that declaration rather than nothing, so the alias's uses are kept, not dropped.
    ///
    /// One under `#if` is kept the same way.
    @Test(arguments: [
        ("Sources/Lib/Nested.swift", "struct Outer {\n    struct JSONDecoder {}\n}\n"),
        ("Sources/Lib/Hidden.swift", "enum Outer {\n    private struct JSONDecoder {}\n}\n"),
        ("Sources/Lib/Renamed.swift", "struct Plain {}\n\nprivate typealias JSONDecoder = Plain\n"),
        ("Sources/Lib/Platform.swift", "#if os(Linux)\nstruct JSONDecoder {}\n#endif\n"),
    ])
    func aDottedExtensionBesideANestedOrAliasedTwinKeepsItsAliasUses(path: String, text: String) async throws {
        let output = try await Self.references(of: "JSONDecoder", files: [
            "Package.swift": Self.manifest,
            "Sources/Lib/Ext.swift": Self.extensionFile.replacingOccurrences(of: "extension JSONDecoder", with: "extension Foundation.JSONDecoder"),
            path: text,
        ])

        #expect(output.contains(":10  | _ = Dec()"), "\(output)")
        #expect(!output.contains("folded in here"), "\(output)")
        #expect(output.contains("may extend another type of the name than the one asked"), "\(output)")
    }

    /// An alias writing a nested type's own path is folded in as proven, though the type's extension written with that path is now followed too.
    @Test
    func anAliasOfANestedTypesOwnPathStillFolds() async throws {
        let output = try await Self.references(of: "JSONDecoder", files: [
            "Package.swift": Self.manifest,
            "Sources/Lib/Nested.swift": "struct Outer {\n    struct JSONDecoder {}\n}\n\nextension Outer.JSONDecoder {\n    func tuned() {}\n}\n\ntypealias Dec = Outer.JSONDecoder\n\nfunc f() {\n    _ = Dec()\n}\n",
        ])

        #expect(output.contains(":12  | _ = Dec()"), "\(output)")
        #expect(output.contains("folded in here"), "\(output)")
        #expect(!output.contains("kept as a use"), "\(output)")
    }

    /// Where the extension's module declares the type where every file sees it, the extension is that type's, and an alias writing another module before it stays out as it did.
    @Test
    func aTypeTheModuleDeclaresKeepsAnotherModulesAliasOut() async throws {
        let output = try await Self.references(of: "JSONDecoder", files: [
            "Package.swift": Self.manifest,
            "Sources/Lib/Ext.swift": Self.extensionFile,
            "Sources/Lib/Declared.swift": "struct JSONDecoder {}\n",
        ])

        #expect(output.contains("Lib.JSONDecoder"), "\(output)")
        #expect(!output.contains("_ = Dec()"), "\(output)")
        #expect(!output.contains("kept as"), "\(output)")
    }

    /// Sites a name-matched answer cannot see through leave the alias's uses kept: a type of the name the extension cannot see (private, under `#if`, in another module), one only a typealias names, a macro that may declare one, an alias in a type whose supertype is outside the tree, and a dependency's dynamic member of the alias's name.
    @Test(arguments: [
        ("Sources/Lib/Hidden.swift", "private struct JSONDecoder {}\n"),
        ("Sources/Lib/Platform.swift", "#if os(Linux)\nstruct JSONDecoder {}\n#endif\n"),
        ("Sources/Other/Decoder.swift", "public struct JSONDecoder {}\n"),
        ("Sources/Lib/Renamed.swift", "typealias JSONDecoder = Foundation.JSONDecoder\n"),
        ("Sources/Lib/Made.swift", "#makeGizmo()\n"),
        ("Sources/Lib/Holder.swift", "class Holder: Base {\n    typealias Dec = Foundation.JSONDecoder\n    func g() { _ = Dec() }\n}\n"),
        ("Sources/Lib/Proxy.swift", "func g(_ proxy: Proxy) { _ = proxy.Dec }\n"),
    ])
    func aHiddenSiteBesideTheAliasLeavesItsUsesKept(path: String, text: String) async throws {
        let output = try await Self.references(of: "JSONDecoder", files: ["Package.swift": Self.manifest, "Sources/Lib/Ext.swift": Self.extensionFile, path: text])

        #expect(output.contains(":10  | _ = Dec()"), "\(output)")
        #expect(output.contains("kept as a use though not proven to name it") || output.contains("kept as uses though not proven to name it"), "\(output)")
        if path.hasSuffix("Holder.swift") {
            #expect(output.contains("func g() { _ = Dec() }"), "\(output)")
        }
    }
}
