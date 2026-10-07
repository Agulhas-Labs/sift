//
// Copyright © Agulhas Labs
//

import Foundation

/// The children's names a nested container's single digest line carries.
///
/// A container rendered as `— 8 cases/members` puts a number exactly where the content was, and the names are usually the whole answer — an `enum Strings`, a `Finish`, a `Field`. A targeted read that follows a digest regularly goes back for a container shown only as a count.
struct NestedNames {
    /// Names listed before the rest are counted instead.
    ///
    /// Two bounds rather than one because they fail differently: a type with 21 short members and a type with four very long member names both produce a line nobody reads, and only the pair catches both.
    static var cap: Int {
        12
    }

    static var width: Int {
        96
    }

    /// The `: name name name +N more` suffix for a container's line, or empty when it has no children.
    static func suffix(for children: [SymbolRow]) -> String {
        guard !children.isEmpty else { return "" }
        var names: [String] = []
        var used = 0
        for child in children {
            guard names.count < cap, used + child.name.count <= width else { break }
            names.append(child.name)
            used += child.name.count + 1
        }
        guard !names.isEmpty else { return "" }
        let remainder = children.count - names.count
        return ": " + names.joined(separator: " ") + (remainder > 0 ? " +\(remainder) more" : "")
    }
}
