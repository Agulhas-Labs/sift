//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// What the hook reads of a command that writes heredocs: every body gone, and the same reading however long the command is.
struct HeredocBodyTests {
    /// A heredoc shape, and the text the whole-command rescan made of it before the scan learned to resume, recorded from that implementation and held byte for byte.
    ///
    /// The reading decides refusals, so a faster scan that read any of these differently would be a changed refusal. The last two cases hold a tab behind a backslash followed by a lone combining accent: blanked, the tab joins the accent into one character, so the scanned text stops matching the command character for character — the first before any body is taken out, when the command is kept whole, and the second only once a body with an apostrophe in it is gone, when what is left is kept as it stands.
    private static let shapes: [(command: String, expected: String)] = [
        ("cat > a.sh <<'EOF'\ngrep -n x F.swift\nEOF\necho done", "cat > a.sh <<'EOF'\necho done"),
        ("cat <<EOF\nline\nEOF\n", "cat <<EOF\n"),
        ("cat <<\"EOF\"\nit's\nEOF\ngrep x F.swift", "cat <<\"EOF\"\ngrep x F.swift"),
        ("cat <<-EOF\n\tbody\n\tEOF\nnext", "cat <<-EOF\nnext"),
        ("cat <<A <<B\na body\nA\nb body\nB\nafter", "cat <<A <<B\nafter"),
        ("cat <<E1; cat <<E2\none\nE1\ntwo\nE2\nls", "cat <<E1; cat <<E2\nls"),
        ("x=$(cat <<EOF\nbody\nEOF\n)\necho $x", "x=$(cat <<EOF\n)\necho $x"),
        ("echo \"$(cat <<EOF\nit's\nEOF\n)\"\nls", "echo \"$(cat <<EOF\n)\"\nls"),
        ("x=`cat <<EOF\nbody\nEOF\n`\nls", "x=`cat <<EOF\n`\nls"),
        ("printf 'a\nEOF\nb'\ncat <<EOF\nbody\nEOF\ntail", "printf 'a\nEOF\nb'\ncat <<EOF\ntail"),
        ("cat <<EOF\nbody \"\nEOF\nnext \"quoted\"", "cat <<EOF\nnext \"quoted\""),
        ("cat <<'A'\nit's\nA\ncat <<'B'\ngrep -n x F.swift\nB\nls", "cat <<'A'\ncat <<'B'\nls"),
        ("cat <<EOF\n\"\nEOF\ncat <<EOF\n'\nEOF\ncat <<EOF\n`\nEOF\nls", "cat <<EOF\ncat <<EOF\ncat <<EOF\nls"),
        ("cat <<\\EOF\n$x\nEOF\nls", "cat <<\\EOF\nls"),
        ("cat <<'E O F'\nx\nE O F\nls", "cat <<'E O F'\nls"),
        ("cat <<EOF\nbody\nmore", "cat <<EOF\n"),
        ("cat <<EOF", "cat <<EOF"),
        ("cat <<EOF\n", "cat <<EOF\n"),
        ("cat <<< \"x\"\nls", "cat <<< \"x\"\nls"),
        ("echo $((1<<3))\ncat <<EOF\nb\nEOF\nls", "echo $((1<<3))\ncat <<EOF\nls"),
        ("echo \"<<EOF\"\nls\nEOF", "echo \"<<EOF\"\nls\nEOF"),
        ("echo \\<<EOF\nls\nEOF\nx", "echo \\<<EOF\nls\nEOF\nx"),
        ("cat <<EOF\r\nbody\r\nEOF\r\nls", "cat <<EOF\r\nbody\r\nEOF\r\nls"),
        ("cat <<EOF # note\nbody\nEOF\nls", "cat <<EOF # note\nls"),
        ("echo \\\t\u{301}\ncat <<EOF\nbody\nEOF\nls", "echo \\\t\u{301}\ncat <<EOF\nbody\nEOF\nls"),
        ("cat <<A\nit's\nA\necho \\\t\u{301}\ncat <<B\nbody2\nB\nls", "cat <<A\necho \\\t\u{301}\ncat <<B\nbody2\nB\nls"),
    ]

    /// Every recorded shape reads as it did.
    @Test
    func everyShapeReadsAsItDid() {
        for shape in Self.shapes {
            #expect(ShellSyntax.withoutHeredocBodies(shape.command) == shape.expected, "\(String(reflecting: shape.command))")
        }
    }

    /// A comment goes before the bodies are looked for, so a `<<` written in one opens nothing and a comment after an opener leaves its body to be taken out.
    @Test
    func commentsGoFirst() {
        #expect(ShellSyntax.runnableText("# <<EOF\nls") == "\nls")
        #expect(ShellSyntax.runnableText("cat <<EOF # note\nbody\nEOF\nls") == "cat <<EOF \nls")
    }

    /// Five thousand heredocs in about 180 KB are read in a small part of the time a rescan per body takes.
    ///
    /// Scanning the rest of the command again after each body made the cost the command's length times its heredocs: two minutes for this command in a debug build, where resuming the scan takes a tenth of a second. The bound sits over a hundred times above the resumed scan's cost, since a suite run beside five others can slow one test that much, and still six times below the rescan's.
    @Test
    func manyHeredocsAreReadInLinearTime() {
        let heredoc = "cat > part.txt <<'EOF'\none part\nEOF\n"
        let command = String(repeating: heredoc, count: 5000) + "ls"
        #expect(command.utf8.count > 175_000)

        let clock = ContinuousClock()
        var reading = ""
        let elapsed = clock.measure {
            reading = ShellSyntax.withoutHeredocBodies(command)
        }

        #expect(reading == String(repeating: "cat > part.txt <<'EOF'\n", count: 5000) + "ls")
        #expect(elapsed < .seconds(20))
    }
}
