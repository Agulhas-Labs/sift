//
// Copyright © Agulhas Labs
//

@testable import SiftMCP
import Testing

/// The recursive-flag reading, and the `sed` exemption it carries.
struct ShellQueryIsRecursiveTests {
    /// A `sed` exempt from the recursive-flag reading is the stage's own command word, never a word among its arguments: `grep -rn sed Sources/Alpha.swift More` names `sed` as a pattern, not a command, and still walks the tree it is pointed at.
    @Test
    func sedNamedAsAPatternDoesNotExemptARecursiveGrep() {
        #expect(ShellQuery("grep -rn sed Sources/Alpha.swift More").isRecursive)
        #expect(!ShellQuery("sed -r 's/a/b/' Sources/Alpha.swift").isRecursive)
    }
}
