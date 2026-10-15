//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// A query answer's stale header counts the files it cites and says `cited`; `status` counts every file and keeps the plain form.
struct StaleHeaderCitedTests {
    private static var path: String {
        "Sources/App/Gizmo.swift"
    }

    @Test
    func aQueryHeaderSaysItCountsCitedFiles() {
        let forms: [(StaleFiles, String)] = [
            (StaleFiles(changed: 1, path: Self.path), "1 cited file changed: \(Self.path)"),
            (StaleFiles(deleted: 1, path: Self.path), "1 cited file deleted: \(Self.path)"),
            (StaleFiles(new: 1, path: Self.path), "1 new cited file: \(Self.path)"),
            (StaleFiles(changed: 3), "3 cited files changed"),
            (StaleFiles(deleted: 2), "2 cited files deleted"),
            (StaleFiles(new: 2), "2 new cited files"),
            (StaleFiles(changed: 1, deleted: 1, new: 2), "4 cited files: 1 changed, 1 deleted, 2 new"),
        ]
        for (files, detail) in forms {
            #expect(files.rendered(cited: true) == detail)
            #expect(SemanticAxis.stale(files).rendered == "stale since last build (\(detail))")
        }
    }

    @Test
    func theWholeTreeHeaderKeepsTheUncitedForms() {
        let forms: [(StaleFiles, String)] = [
            (StaleFiles(changed: 1, path: Self.path), "1 file changed: \(Self.path)"),
            (StaleFiles(deleted: 1, path: Self.path), "1 file deleted: \(Self.path)"),
            (StaleFiles(new: 1, path: Self.path), "1 new file: \(Self.path)"),
            (StaleFiles(changed: 3), "3 files changed"),
            (StaleFiles(deleted: 2), "2 files deleted"),
            (StaleFiles(new: 2), "2 new files"),
            (StaleFiles(changed: 1, deleted: 1, new: 2), "4 files: 1 changed, 1 deleted, 2 new"),
        ]
        for (files, detail) in forms {
            #expect(files.rendered(cited: false) == detail)
            #expect(SemanticAxis.staleByFileState(files).rendered == "stale since last build (\(detail))")
        }
    }
}
