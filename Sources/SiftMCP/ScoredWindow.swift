//
// Copyright © Agulhas Labs
//

import Foundation

/// One window the audit's scan scored: the call it was, how the scan classed it, the file as the scan resolved it, and the index call that had located that file by then.
///
/// The line `sift scan-dump` prints for each, and the unit `audit --scan-diff` joins two builds' scans on — keyed by `session`, `call` and `part`: the transcript's session id, the window's own `tool_use_id`, and which of that call's two windows it is.
public struct ScoredWindow: Sendable, Equatable, Codable {
    /// The part of a call's `.indexed` lookup as an index call.
    public static var indexPart: String {
        "index"
    }

    /// The part of a call's held lookup, and of every window of a dump from before `part` was written.
    public static var lookupPart: String {
        "lookup"
    }

    public var session: String
    public let call: String
    /// ``indexPart`` for the `.indexed` lookup an index call is counted as on its way out, over MCP or on a Bash line, and ``lookupPart`` for the lookup a read, search or shell line is held as.
    public let part: String
    /// The ``SwiftLookup`` case the window ended as — `indexed(cli)` on a Bash line and `indexed(answered)` where the advice hook answered in a refusal's place — `retracted` where its call came back an error, or `refused` where the advice hook refused it.
    public var classification: String
    public let file: String?
    public let locator: LocatingCall?

    /// The key two builds' windows are joined on.
    var key: String {
        "\(session) \(call) \(part)"
    }

    public init(session: String, call: String, part: String = lookupPart, classification: String, file: String?, locator: LocatingCall?) {
        self.session = session
        self.call = call
        self.part = part
        self.classification = classification
        self.file = file
        self.locator = locator
    }

    /// The window as one line of JSON, keys sorted, with `file` and `locator` written as `null` where there is none.
    public var jsonLine: String {
        let fields: [String: Any] = [
            "session": session,
            "call": call,
            "part": part,
            "classification": classification,
            "file": file ?? NSNull(),
            "locator": locator.map { ["tool": $0.tool, "call": $0.call] } ?? NSNull(),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }

    /// The name a scan-dump line gives `lookup`: its case, with a withheld lookup's cause or rule beside it.
    static func classification(of lookup: SwiftLookup) -> String {
        switch lookup {
        case .indexed: "indexed"
        case .guided: "guided"
        case .readWholeAfterDigest: "readWholeAfterDigest"
        case .revisited: "revisited"
        case .belowFloor: "belowFloor"
        case let .textSearch(cause): "textSearch(\(cause.rawValue))"
        case let .withheldOnWorth(rule): "withheldOnWorth(\(rule.rawValue))"
        case .cold: "cold"
        case .batched: "batched"
        }
    }
}

extension ScoredWindow {
    enum CodingKeys: String, CodingKey {
        case session
        case call
        case part
        case classification
        case file
        case locator
    }

    /// Decodes a window as a dump prints it: a missing `part` reads as ``lookupPart``, a missing `file` or `locator` as none, and a missing `session`, `call` or `classification` fails.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        session = try container.decode(String.self, forKey: .session)
        call = try container.decode(String.self, forKey: .call)
        part = try container.decodeIfPresent(String.self, forKey: .part) ?? Self.lookupPart
        classification = try container.decode(String.self, forKey: .classification)
        file = try container.decodeIfPresent(String.self, forKey: .file)
        locator = try container.decodeIfPresent(LocatingCall.self, forKey: .locator)
    }
}
