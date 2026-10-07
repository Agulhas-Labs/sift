//
// Copyright © Agulhas Labs
//

import Foundation

/// A committed two-file repository made read-only, and made writable again before its scope removes it.
struct ReadOnlyTree {
    /// The repository, committed and still writable.
    static func seed() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Depot {\n    func save() -> String {\n        \"depot\"\n    }\n}\n", to: "Sources/Depot.swift", in: root)
        try TestSources.write("struct Crate {\n    func load() {}\n}\n", to: "Sources/Crate.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        return root
    }

    /// The repository with no `.sift/`, every file and directory in it read-only.
    static func make() throws -> URL {
        let root = try seed()
        try chmod("a-w", root)
        return root
    }

    /// Writable again, so the temporary-directory scope can remove it.
    static func restore(_ root: URL) {
        try? chmod("a+w", root)
    }

    /// `chmod -R <mode>` over `root`.
    static func chmod(_ mode: String, _ root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["-R", mode, root.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
