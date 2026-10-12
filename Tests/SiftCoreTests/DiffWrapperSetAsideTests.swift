//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A diff touching the initializers of two property wrappers gives each wrapper's report only the sites set aside for its own type.
@Suite(.temporaryDirectories)
struct DiffWrapperSetAsideTests {
    private static let native = ["--build-system", "native"]

    /// A property wrapper named `name` with two initializers, the first declared with `access`.
    private static func wrapper(_ name: String, access: String) -> String {
        """
        @propertyWrapper struct \(name) {
            var wrappedValue: Int
            \(access)init(wrappedValue: Int) { self.wrappedValue = wrappedValue }
            init(wrappedValue: Int, step: Int) { self.wrappedValue = wrappedValue }
        }
        """
    }

    /// A struct whose `@name(step:)` site is compiled only under the debug condition.
    private static func holder(_ name: String, value: Int) -> String {
        "struct \(name)Holder {\n    #if DEBUG\n    @\(name)(step: 2) var v = \(value)\n    #endif\n}\n"
    }

    @Test
    func eachWrapperReportSaysOnlyItsOwnSetAsideSite() async throws {
        let root = try TestSources.makeTempRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try TestSources.write(
            "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: \"Lib\", targets: [.target(name: \"Lib\")])\n",
            to: "Package.swift",
            in: root
        )
        try TestSources.write(".build\n", to: ".gitignore", in: root)
        let names = ["Clamp", "Dial"]
        for name in names {
            try TestSources.write(Self.wrapper(name, access: ""), to: "Sources/Lib/\(name).swift", in: root)
            try TestSources.write(Self.holder(name, value: 1), to: "Sources/Lib/\(name)Holder.swift", in: root)
        }
        try TestSources.commitAll(in: root, message: "before")
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: Self.native)
        for name in names {
            try TestSources.write(Self.wrapper(name, access: "public "), to: "Sources/Lib/\(name).swift", in: root)
            try TestSources.write(Self.holder(name, value: 3), to: "Sources/Lib/\(name)Holder.swift", in: root)
        }
        try TestSources.commitAll(in: root, message: "after")
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: Self.native + ["-c", "release"])

        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        let initializer = "init(wrappedValue:)"
        let targets = names.map { name in
            DiffCallers.Target(label: name + "." + initializer, name: initializer, kind: .initializer, path: "Sources/Lib/\(name).swift", line: 3, removed: false)
        }
        let callers = DiffCallers(store: engine.store, repoRoot: root, enumerator: FileEnumerator(repoRoot: root, config: SiftConfig()), projectDirectories: [])

        let reports = try await callers.reports(for: targets, semantic: engine.whereSemanticInput())

        #expect(reports.count == 2)
        for (name, report) in zip(names, reports) {
            let line = report.setAside.line ?? "nil"
            #expect(report.unresolvedBecause == nil, "\(name): \(report.unresolvedBecause ?? "")")
            #expect(line.hasPrefix("1 site in Sources/Lib/\(name)Holder.swift set aside"), "\(name): \(line)")
        }
    }
}
