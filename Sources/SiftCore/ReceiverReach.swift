//
// Copyright © Agulhas Labs
//

/// What a qualified query's narrowing by receiver makes of a site: dropped only where the receiver is provably another type of the tree.
enum ReceiverReach: Sendable, Equatable {
    /// Written on, or inside, a type that may reach the member asked about: kept.
    case reaches
    /// Written on, or inside, another type the tree declares: dropped.
    case another
    /// Written on, or inside, a type no tree declaration shows to be another, for the reason given: kept, and counted apart by that reason.
    case unproven(Unproven)
    /// Written on a receiver the scan cannot type, a variable or a chain: kept, and counted apart.
    case untyped

    /// Whether the site stays listed.
    var isKept: Bool {
        self != .another
    }

    /// The clauses a name's line counts the kept sites by, one for each reason sites were kept only because their receiver could not be shown to be another type, or `[]` where none was.
    ///
    /// The receivers written on each clause's sites are named with their counts, the most common three, so a name as common as `record` is read by whom it was written on without listing every site.
    static func keptClauses(_ reaches: [(site: SyntacticCallSite, reach: ReceiverReach)]) -> [String] {
        Unproven.allCases.compactMap { reason in
            let sites = reaches.filter { $0.reach == .unproven(reason) }
            guard !sites.isEmpty else { return nil }
            var counts: [String: Int] = [:]
            for entry in sites {
                if case let .type(name, _, _)? = entry.site.receiver {
                    counts[name, default: 0] += 1
                }
            }
            let top = counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.prefix(3)
            let named = top.isEmpty ? "" : " (" + top.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ") + (counts.count > top.count ? ", …" : "") + ")"
            return "\(sites.count) \(reason.wording)\(named)"
        }
    }
}

extension ReceiverReach {
    /// The first entry for each line and reason, so clauses count lines as a name-only reference's kept count does.
    static func onePerLine(_ reaches: [(site: SyntacticCallSite, reach: ReceiverReach)]) -> [(site: SyntacticCallSite, reach: ReceiverReach)] {
        var seen: Set<String> = []
        return reaches.filter { entry in
            guard case let .unproven(reason) = entry.reach else { return true }
            return seen.insert("\(entry.site.path):\(entry.site.line):\(reason)").inserted
        }
    }

    /// Why a site written on a type name is kept although the name may be another type's, each counted on the name's line in its own clause.
    enum Unproven: CaseIterable, Sendable {
        /// The tree declares no type of the receiver's name, or the site is inside a type it does not declare: a framework's type may hand on the member.
        case undeclared
        /// The receiver is written behind a qualifier the scan does not resolve, which may name another module's type.
        case qualified
        /// The tree declares a type of the name, but none in sight of the site: in another module, nested, under an `#if`, or private to another file.
        case outOfSight
        /// The tree's type of the name has a supertype outside the tree, which may hand on the member.
        case inheritsOutside
        /// A type around the site is declared inside a function, whose supertypes and members the scan does not see.
        case localScope
        /// A type around the site is an extension of a type outside the tree, which may supply the name.
        case extendedScope
        /// A type around the site has a supertype outside the tree, which may supply the name.
        case inheritedScope
        /// A type around the site, or the receiver's, carries an attribute that may be an attached macro, which may supply or reshape the name.
        case macro

        /// The clause's wording after its count.
        var wording: String {
            switch self {
            case .undeclared:
                "on types the tree does not declare"
            case .qualified:
                "on types behind a qualifier the scan does not resolve"
            case .outOfSight:
                "on tree types out of the site's sight"
            case .inheritsOutside:
                "on tree types a supertype outside the tree may hand it on"
            case .localScope:
                "on names a type declared in a function may supply"
            case .extendedScope:
                "on names an extension of a type outside the tree may supply"
            case .inheritedScope:
                "on names a supertype outside the tree of a type around them may supply"
            case .macro:
                "on names an attached macro may supply or reshape"
            }
        }
    }
}
