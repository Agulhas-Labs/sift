//
// Copyright © Agulhas Labs
//

import Foundation

/// `sift diff --member`: one changed declaration's before and after, addressed the way `digest` addresses a member — or by the exact address an ambiguity refusal lists, so every refusal can be retried as written (Docs/AnswerContract.md §5).
///
/// An address is `<path>#<Type.member>:<line>` — the after side's line — or `…:before:<line>` for a declaration the range removed, since a removed one has no after side and two same-labeled overloads can share a line number across the two sides.
struct DiffMemberRenderer {
    static func body(target: String, files: [FileDiff], range: DiffRange) -> String {
        let hits = matches(for: target, in: files)
        switch hits.count {
        case 0:
            return "\(target) is not among the declarations changed by \(range.described) — `sift diff` without --member lists the ones that are; an unchanged member's source is `sift digest \(target)`."
        case 1:
            return bodyText(path: hits[0].path, change: hits[0].change, range: range)
        default:
            var lines = ["\(target) is ambiguous — \(hits.count) changed declarations match; pass one of these addresses to --member:"]
            for (path, change) in hits {
                // Two extensions of one type share a dotted path; the heading each sits under is what tells them apart.
                let container = change.containerDisplay != change.containerPath ? ", in \(change.containerDisplay)" : ""
                lines.append("  \(address(path: path, change: change)) — \(change.symbolKind.rawValue), \(describedKind(change.kind))\(container)")
            }
            return lines.joined(separator: "\n")
        }
    }

    /// The exact spelling this renderer accepts back for one change.
    static func address(path: String, change: DeclarationChange) -> String {
        guard let pin = change.addressLine else { return "\(path)#\(change.label)" }
        return "\(path)#\(change.label):\(pin.before ? "before:" : "")\(pin.line)"
    }

    /// Whether `target` — an address, or a `Type.member` label matched from its end as `digest` matches one — names this change in this file.
    ///
    /// The gatherer asks this of every change as it is built, so only the bodies a `--member` answer can print are kept.
    static func accepts(_ target: String, path: String, change: DeclarationChange) -> Bool {
        if let hash = target.lastIndex(of: "#") {
            var label = String(target[target.index(after: hash)...])
            var pin: (line: Int, before: Bool)?
            if let match = label.firstMatch(of: /:(before:)?(\d+)$/), let line = Int(match.output.2) {
                pin = (line, match.output.1 != nil)
                label = String(label[..<match.range.lowerBound])
            }
            guard String(target[..<hash]) == path, change.label == label else { return false }
            guard let pin else { return true }
            return change.addressLine.map { $0.line == pin.line && $0.before == pin.before } ?? false
        }
        return matches(QualifiedPath.components(of: target), change: change)
    }
}

private extension DiffMemberRenderer {
    static func describedKind(_ kind: DeclarationChange.Kind) -> String {
        switch kind {
        case .added: "added"
        case .removed: "removed"
        case .changed: "changed"
        case .moved: "moved"
        }
    }

    /// An address picks exactly one change; anything else is a `Type.member` label, matched from its end as `digest` matches one.
    static func matches(for target: String, in files: [FileDiff]) -> [(path: String, change: DeclarationChange)] {
        files.flatMap { file in file.changes.map { (path: file.path, change: $0) } }.filter { accepts(target, path: $0.path, change: $0.change) }
    }

    static func matches(_ qualifiers: [String], change: DeclarationChange) -> Bool {
        guard !qualifiers.isEmpty else { return false }
        let chain = (change.containerPath.isEmpty ? [] : change.containerPath.split(separator: ".").map(String.init)) + [change.name]
        guard qualifiers.count <= chain.count else { return false }
        if chain.suffix(qualifiers.count) == qualifiers[...] {
            return true
        }
        var baseNamed = chain
        baseNamed[baseNamed.count - 1] = QualifiedPath.baseName(of: baseNamed[baseNamed.count - 1])
        return baseNamed.suffix(qualifiers.count) == qualifiers[...]
    }

    static func bodyText(path: String, change: DeclarationChange, range: DiffRange) -> String {
        let sides = [change.oldRange.map { "before \($0.described)" }, change.newRange.map { "after \($0.described)" }].compactMap(\.self)
        var lines = ["\(change.label) (\(change.symbolKind.rawValue)) — \(describedKind(change.kind)), \(sides.joined(separator: ", ")) — \(address(path: path, change: change))", ""]
        if change.oldCondition != nil || change.newCondition != nil {
            lines.append("condition: \(change.oldCondition ?? "(none)") → \(change.newCondition ?? "(none)")")
            lines.append("")
        }
        if change.kind == .moved {
            lines.append("moved from \(change.oldRange?.described ?? "?") (before) to \(change.newRange?.described ?? "?"), its text unchanged — `sift digest \(change.label)` shows it.")
            return lines.joined(separator: "\n")
        }
        guard change.oldBody != nil || change.newBody != nil else {
            // A container matched on both sides whose own line changed carries no body on either side by
            // design: its members are diffed separately, so this request has landed on the type's own
            // declaration line rather than on one of its members.
            lines.append("before: \(change.oldSignature ?? "")")
            lines.append("after:  \(change.newSignature ?? "")")
            lines.append("")
            lines.append("this is the container's own declaration line — the summary (`sift diff` without --member) lists its members' changes one by one, and `sift digest \(change.label)` shows the type whole.")
            return lines.joined(separator: "\n")
        }
        lines.append("before (\(range.fromLabel)):")
        lines.append(change.oldBody ?? "(added by this change — nothing here before)")
        lines.append("")
        lines.append("after (\(range.to.described)):")
        lines.append(change.newBody ?? "(removed by this change — nothing here after)")
        return lines.joined(separator: "\n")
    }
}
