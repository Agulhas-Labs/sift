//
// Copyright © Agulhas Labs
//

import Foundation

/// Which of the four lookup rules a tool is judged by, whatever server exposes it.
///
/// A read is a read and a grep is a grep; the name on the front is an accident of which MCP server is registered. The Xcode server's `XcodeRead`/`XcodeGrep`/`XcodeGlob` take the same arguments under different names — `filePath` for `file_path`, and `pattern`/`path`/`glob`/`type` unchanged — so they are the same lookups with a different label on them.
///
/// This matters twice, and the second time is the one that bites. Refusing `Read` while leaving `XcodeRead` open teaches a detour rather than a habit. But *counting* `Read` while leaving `XcodeRead` uncounted is worse: the traffic the refusal displaces would land somewhere the metric cannot see, and the share would climb while nothing improved. That failure — a number that flatters because the denominator moved — is the easiest one for a metric like this to make.
///
/// Matched on the suffix so a server prefix never has to be enumerated. `NotebookRead` lands on the read rule and nothing comes of it: it carries no file path either spelling.
public struct LookupTool {
    /// The rule name, or `nil` for a tool this has no opinion about.
    public static func rule(for tool: String) -> String? {
        if tool == "Bash" {
            return "Bash"
        }
        if tool.hasSuffix("Read") {
            return "Read"
        }
        if tool.hasSuffix("Grep") {
            return "Grep"
        }
        if tool.hasSuffix("Glob") {
            return "Glob"
        }
        return nil
    }

    /// The file a read was pointed at, under either spelling of the argument.
    public static func readPath(in input: [String: Any]) -> String? {
        input["file_path"] as? String ?? input["filePath"] as? String
    }

    /// Whether a tool writes a file whole or edits one in place, which puts the file's text in the context that called it.
    ///
    /// A file this context wrote is one it holds, so a later read of it is a revisit rather than a lookup, on both ends: the hook lets it through and the scan files it as revisited. An edit is here too because the harness takes one only of a file the context has already read or written. The file is named by the same argument a read's is, so ``readPath(in:)`` reads it.
    public static func writes(_ tool: String) -> Bool {
        ["Write", "Edit", "MultiEdit"].contains(tool)
    }
}
