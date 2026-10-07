//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftMCP
import Testing

/// The `PostToolUse` hook finds the repository holding each file of a patch once per directory, however many files of that directory the patch edits.
@Suite(.temporaryDirectories)
struct PatchRootLookupTests {
    /// A patch of 300 files in one directory costs one repository lookup across the parse checks and the nudge, whether or not a repository holds the directory.
    @Test(arguments: [String?.none, "/nowhere"])
    func aPatchOfManyFilesInOneDirectoryLooksTheRepositoryUpOnce(found: String?) throws {
        let marks = try ReuseNudgeMarks(directory: TemporaryDirectory.make("nudge-marks"))
        let payloads: [[String: Any]] = (0 ..< 300).map { index in
            ["tool_name": "Edit", "tool_input": ["file_path": "/nowhere/App/Shelf\(index).swift"], "session_id": "s1"]
        }
        var (lookups, checked) = ([String](), [String?]())

        let lookUp = { (directory: String) -> String? in
            lookups.append(directory)
            return found
        }

        PostToolUseCommand.answer(toEach: payloads, output: RecordedOutput().output, marks: marks, timeBudget: 60, lookUp: lookUp) { _, root, _ in
            checked.append(root)
            return nil
        }

        #expect(lookups == ["/nowhere/App"])
        #expect(checked == Array(repeating: found, count: 300))
    }
}
