//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the plain source-literal section when a production literal matched around its interpolations prints the query's text: the tests spelling it whole are counted, not listed ahead of it.
@Suite(.temporaryDirectories)
struct StringsProducerFirstTests {
    private static func makeRepo(files: [String: String]) throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        for (path, contents) in files {
            try TestSources.write(contents, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "producer fixture")
        return try SiftEngine(directory: root)
    }

    private static func testFiles() -> [String: String] {
        var files: [String: String] = [:]
        for name in ["GizmoTests", "LegacyWidgetTests"] {
            files["Tests/App/\(name).swift"] = """
            import Testing

            struct \(name) {
                @Test func wording() {
                    #expect("3 of them the widgets listed below" == "")
                }
            }
            """
        }
        return files
    }

    private static var query: String {
        "the widgets listed below"
    }

    @Test("a two-word production site listed around interpolations leaves the tests counted, not listed")
    func producerFirst() throws {
        var files = Self.testFiles()
        files["Sources/App/Gizmo.swift"] = """
        struct Gizmo {
            func line(n: Int) -> String {
                "\\(n) of them the widget\\(n == 1 ? "" : "s") listed below"
            }
        }
        """
        let engine = try Self.makeRepo(files: files)
        let answer = try engine.strings(query: Self.query)

        #expect(answer.contains("source literals:\n  in tests: 2 sites in 2 files"))
        #expect(answer.contains("Gizmo.line(n:) — Sources/App/Gizmo.swift:3:"))
        #expect(!answer.contains("GizmoTests.swift:"))
        #expect(!answer.contains("of them the widgets listed below\""))
    }

    @Test("a production site matched on one word only does not take the tests' listing away")
    func oneWordProductionKeepsTests() throws {
        var files = Self.testFiles()
        files["Sources/App/Gizmo.swift"] = """
        struct Gizmo {
            func line(n: Int, rest: String) -> String {
                "\\(n) widgets \\(rest)"
            }
        }
        """
        let engine = try Self.makeRepo(files: files)
        let answer = try engine.strings(query: Self.query)

        #expect(answer.contains("matched around them on only one word of literal text"))
        #expect(answer.contains("Gizmo.line(n:rest:) — Sources/App/Gizmo.swift:3:"))

        #expect(answer.contains("Tests/App/GizmoTests.swift:5: \"3 of them the widgets listed below\""))
        #expect(answer.contains("Tests/App/LegacyWidgetTests.swift:5: \"3 of them the widgets listed below\""))
    }

    @Test("a test-file literal matched around interpolations on two words is no producer: the plain test literals stay listed")
    func aroundMatchInATestFileIsNoProducer() throws {
        var files = Self.testFiles()
        files["Tests/App/Orchard.swift"] = """
        import Testing

        struct Orchard {
            func line(n: Int) -> String {
                "\\(n) of them the widget\\(n == 1 ? "" : "s") listed below"
            }
        }
        """
        let engine = try Self.makeRepo(files: files)
        let answer = try engine.strings(query: Self.query)

        #expect(answer.contains("Tests/App/GizmoTests.swift:5: \"3 of them the widgets listed below\""))
        #expect(answer.contains("Tests/App/LegacyWidgetTests.swift:5: \"3 of them the widgets listed below\""))
        #expect(!answer.contains("in tests: 2 sites"))
    }

    @Test("no production match leaves the test literals listed")
    func noProductionMatch() throws {
        let engine = try Self.makeRepo(files: Self.testFiles())
        let answer = try engine.strings(query: Self.query)

        #expect(answer.contains("Tests/App/GizmoTests.swift:5: \"3 of them the widgets listed below\""))
        #expect(!answer.contains("in tests:"))
    }
}
