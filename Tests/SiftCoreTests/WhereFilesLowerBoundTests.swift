//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The files view drops the `used by` verdict, so a target the store never built has to be said by its heading: the set of files is a lower bound there.
@Suite(.serialized, .temporaryDirectories)
struct WhereFilesLowerBoundTests {
    @Test
    func aTargetNotBuiltMakesTheHeadingALowerBound() async throws {
        let root = try Self.twoTargetPackage()
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: ["--target", "Core"])

        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let files = try await engine.lookup(symbol: "A", freshness: engine.ensureFresh(), options: WhereOptions(filesOnly: true))

        #expect(files.contains("a lower bound (target Extra not built)"), "\(files)")
    }

    @Test
    func aFullyBuiltPackageHeadingIsNotALowerBound() async throws {
        let root = try Self.twoTargetPackage()
        try await TestSources.swiftBuildSuspending(packageAt: root)

        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let files = try await engine.lookup(symbol: "A", freshness: engine.ensureFresh(), options: WhereOptions(filesOnly: true))

        #expect(files.contains("files naming "), "\(files)")
        #expect(!files.contains("a lower bound"), "\(files)")
    }

    private static func twoTargetPackage() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version:5.9
            import PackageDescription

            let package = Package(
                name: "Probe",
                targets: [.target(name: "Core"), .target(name: "Extra", dependencies: ["Core"])]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write("public struct A {\n    public init() {}\n    public func f() {}\n}\n\npublic func begin() {\n    A().f()\n}\n", to: "Sources/Core/A.swift", in: root)
        try TestSources.write("import Core\n\nfunc finish(_ a: A) {\n    a.f()\n}\n", to: "Sources/Extra/Extra.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        return root
    }
}
