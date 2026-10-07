//
// Copyright © Agulhas Labs
//

/// A declaration's access level as written (or inherited syntactically from its extension).
public enum AccessLevel: String, Sendable, Comparable, CaseIterable {
    case privateLevel = "private"
    case fileprivateLevel = "fileprivate"
    case internalLevel = "internal"
    case packageLevel = "package"
    case publicLevel = "public"
    case openLevel = "open"

    /// Ordering follows visibility: `private` is the most restricted, `open` the least.
    public static func < (lhs: AccessLevel, rhs: AccessLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

extension AccessLevel {
    private var rank: Int {
        switch self {
        case .privateLevel: 0
        case .fileprivateLevel: 1
        case .internalLevel: 2
        case .packageLevel: 3
        case .publicLevel: 4
        case .openLevel: 5
        }
    }
}
