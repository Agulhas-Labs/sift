//
// Copyright © Agulhas Labs
//

@testable import SiftMCP
import Testing

/// An editor's in-place flag is read from the editor's own words alone, so a later stage's or a later statement's `-i` never makes the read a write.
struct EditorFlagBeyondTheStageTests {
    /// The `-i` after the pipe or the semicolon belongs to `grep`, and the `sed` before it only prints.
    @Test(arguments: [
        "sed -n '/init/p' Sources/App/View.swift | grep -i view",
        "sed -n '1,30p' Sources/App/View.swift > /dev/null; grep -i view Sources/App/View.swift",
    ])
    func aLaterStagesFlagIsNotTheEditors(command: String) {
        #expect(ShellInspection.isSwiftLookup(command))
    }

    /// `find`'s own predicates read after `-exec`'s terminating `;` belong to `find`, never to the `-exec`'d editor — an `-iname` there is not the editor's `-i`, and the scan of the `-exec` clause must stop at the `;` rather than reading past it into `find`'s own options.
    @Test
    func findsOwnOptionAfterExecIsNotTheEditors() {
        let read = ShellQuery(#"find Sources -exec sed -n 1p {} \; -iname '*.swift'"#).editsInPlace
        let write = ShellQuery(#"find Sources -exec sed -i '' 's/a/b/' {} \;"#).editsInPlace

        #expect(read == false)
        #expect(write == true)
    }
}
