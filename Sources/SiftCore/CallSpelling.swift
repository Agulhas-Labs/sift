//
// Copyright © Agulhas Labs
//

/// How an answer writes a call it suggests: as the CLI's arguments, or as the MCP tool's.
///
/// A paging cursor is spelled for the face that asked — `--offset 200` on the CLI, `offset: 200` in a tool call — since a caller copies it into the next call as written. A suggestion that names a target and an offset together is spelled as the whole call to repeat: a caller copying the CLI's pair into a tool call sends the offset as part of the target.
public enum CallSpelling: Sendable {
    /// `digest Sources/App/Store.swift:10-514 --offset 200`
    case commandLine
    /// `digest target:"Sources/App/Store.swift:10-514" offset:200`
    case toolCall

    /// A `digest` of `target` resumed at `offset`, spelled for the face.
    func digest(_ target: String, offset: Int) -> String {
        switch self {
        case .commandLine: "digest \(target) --offset \(offset)"
        case .toolCall: "digest target:\"\(target)\" offset:\(offset)"
        }
    }

    /// The `offset` argument alone, spelled for the face — for a truncation line with no target of its own to carry it.
    func offset(_ offset: Int) -> String {
        switch self {
        case .commandLine: "--offset \(offset)"
        case .toolCall: "offset: \(offset)"
        }
    }
}
