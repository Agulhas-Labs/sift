//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A qualified query keeps a site written on another tree type's name inside an extension that extends no type of its name the tree declares in the extension's sight: one qualified by a module that is no tree path, or one written bare where the tree's top-level type of the name is private to another file or under an `#if`.
///
/// Each fixture typechecks with swiftc as module App for the iOS simulator, the `#if DEBUG` one with `DEBUG` defined and without, and the one importing Kit against Kit's emitted module.
@Suite(.temporaryDirectories)
struct WhereExtensionOfAnotherTypeTests {
    private static var nestedTwin: String {
        """
        import UIKit

        struct Depot { var stock = 0 }
        struct Spare { var stock = 1 }
        enum Theme {
            struct UILabel {
                var themed: Int { Spare().stock }
            }
        }
        """
    }

    private static var qualified: String {
        """
        extension UIKit.UILabel {
            var qualified: Int { Spare().stock }
        }
        extension App.Theme.UILabel {
            var moduled: Int { Spare().stock }
        }
        """
    }

    private static var bare: String {
        """
        extension UILabel {
            var labelled: Int { Spare().stock }
        }
        """
    }

    private static func twin(_ prefix: String, under condition: String? = nil) -> String {
        let declaration = """
        \(prefix)struct UILabel {
            var plain: Int { Spare().stock }
        }
        """
        return condition.map { "#if \($0)\n\(declaration)\n#endif" } ?? declaration
    }

    private static func answer(_ files: [String: String]) async throws -> String {
        let root = try TestSources.makeTempRepo()
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(name: "App", targets: [.target(name: "Kit"), .target(name: "App", dependencies: ["Kit"])])
        """
        try TestSources.write(manifest, to: "Package.swift", in: root)
        for (name, source) in files {
            try TestSources.write(source, to: "Sources/\(name).swift", in: root)
        }
        try TestSources.commitAll(in: root, message: "fixture")
        return try await CallSiteHeadingTests.lookup("Depot.stock", in: root)
    }

    /// `extension UIKit.UILabel` beside `enum Theme { struct UILabel }` extends the framework's class, which may supply the name; `extension App.Theme.UILabel`, the tree's path behind its module, extends the tree's type, so a site there is still dropped as `Spare`'s.
    @Test
    func aSiteInAModuleQualifiedExtensionOfAFrameworkTypeIsKept() async throws {
        let output = try await Self.answer(["App/Uses": Self.nestedTwin + "\n" + Self.qualified])

        #expect(output.contains("on types outside the tree"), "\(output)")
        #expect(output.contains("in UIKit.UILabel.qualified"), "\(output)")
        #expect(!output.contains(".moduled"), "\(output)")
        #expect(!output.contains("in Theme.UILabel.themed"), "\(output)")
        #expect(output.contains("2 on other types dropped"), "\(output)")
    }

    /// A top-level twin private to another file, or under an `#if` the extension does not share, may not be what `extension UILabel` extends, so a site there is kept; a site inside the twin itself is still dropped.
    @Test(arguments: [("private ", nil), ("", "DEBUG")] as [(String, String?)])
    func aSiteInABareExtensionATwinMayNotBeIsKept(prefix: String, condition: String?) async throws {
        let output = try await Self.answer(["App/Uses": Self.nestedTwin + "\n" + Self.bare, "App/Twin": Self.twin(prefix, under: condition)])

        #expect(output.contains("on types outside the tree"), "\(output)")
        #expect(output.contains("in UILabel.labelled"), "\(output)")
        #expect(!output.contains("in UILabel.plain"), "\(output)")
        #expect(output.contains("2 on other types dropped"), "\(output)")
    }

    /// An internal top-level twin under no `#if` is the type `extension UILabel` extends, so a site there is dropped as `Spare`'s.
    @Test
    func aSiteInABareExtensionOfAVisibleTwinIsDropped() async throws {
        let output = try await Self.answer(["App/Uses": Self.nestedTwin + "\n" + Self.bare, "App/Twin": Self.twin("")])

        #expect(!output.contains("in UILabel.labelled"), "\(output)")
        #expect(output.contains("3 on other types dropped"), "\(output)")
    }

    /// An internal `UILabel` in another module is out of `extension UILabel`'s sight even where the extension's file imports that module, so the extension extends UIKit's class and a site there is kept.
    @Test
    func aSiteInABareExtensionOfATwinInAnotherModuleIsKept() async throws {
        let twin = "struct UILabel {\n    var plain = 0\n}"
        let output = try await Self.answer(["App/Uses": "import Kit\n" + Self.nestedTwin + "\n" + Self.bare, "Kit/Twin": twin])

        #expect(output.contains("on types outside the tree"), "\(output)")
        #expect(output.contains("in UILabel.labelled"), "\(output)")
        #expect(output.contains("1 on other types dropped"), "\(output)")
    }
}
