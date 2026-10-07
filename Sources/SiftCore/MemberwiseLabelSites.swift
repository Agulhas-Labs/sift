//
// Copyright © Agulhas Labs
//

/// The calls that write a stored property's name as an argument label of its struct's memberwise initializer — `Gizmo(weight: 1)` for `Gizmo.weight` — which a rename of the property changes and a scan for the name as an expression never finds.
///
/// A no-store `--refs` sweep is the whole of what a rename has, so these calls are listed with the property's uses there: found by the struct's name, in the shape its initializers are, and told apart from another type's of the name as the initializer's own calls are (``SameNamedTypes/Resolver``). One the memberwise labels take, every parameter without a default supplied in order, is listed; one that may build another type of the name is listed with the flag saying so and counted apart, and so is one whose qualifier the index reads as another type's owner or as declaring no type of the name, since reading a qualifier from the index alone is not sound; one whose labels the memberwise initializer does not take is counted and not listed. A struct whose memberwise labels cannot be worked out (a tuple pattern `var (x, y)`, a signature that does not parse) is still scanned by its name, and each call writing the label is counted with that caveat rather than left out.
struct MemberwiseLabelSites {
    /// Per property asked of, the struct whose memberwise initializer takes it.
    private let owners: [Int64: Owner]
    /// Per struct name, every type of that name a call written with it may build.
    private let candidates: [String: [SameNamedTypes.Candidate]]
    private let resolver: SameNamedTypes.Resolver?

    /// The properties of `rows` the compiler's memberwise initializer takes: stored, not static, in a struct whose body declares no initializer; `source` reads a declaration's lines, to tell which parameters have defaults.
    init(rows: [SymbolRow], sameNamed: SameNamedTypes, source: ((SymbolRow) -> [String]?)? = nil) throws {
        let parameters = MemberwiseParameters(source: source)
        var owners: [Int64: Owner] = [:]
        for row in rows where row.kind == .variable && row.isStored && !row.isStatic {
            guard let parent = try sameNamed.store.parentChain(of: row).last,
                  let properties = try sameNamed.memberwiseProperties(of: parent)
            else { continue }
            // Labels that cannot be worked out still leave the struct to scan, so its calls are counted rather than lost.
            let labels = parameters.labels(of: properties)
            guard labels?.parameters.contains(where: { $0.label == row.name }) != false else { continue }
            owners[row.id] = try Owner(type: parent.name, path: sameNamed.store.qualifiedName(of: parent), labels: labels)
        }
        self.owners = owners
        let types = Set(owners.values.map(\.type))
        candidates = try types.reduce(into: [:]) { $0[$1] = try sameNamed.candidates(named: $1) }
        resolver = owners.isEmpty ? nil : try SameNamedTypes.Resolver(store: sameNamed.store)
    }

    /// The struct names to scan in the shape an initializer is reached, so the calls of the asked properties' memberwise initializers are found.
    var typeNames: Set<String> {
        Set(owners.values.map(\.type))
    }

    /// The sites among `sitesByName`, scanned by struct name, that write the name of one of `rows` as a label to its struct's memberwise initializer, each said once.
    ///
    /// A site several of the properties' structs may take is said once, under what the scan tells best of it for any of them: a `Self(…)` held for every struct is judged by each before it is said, so a struct sorted first that cannot take it never hides it from one that can.
    func calls(passing rows: [SymbolRow], among sitesByName: [String: [SyntacticCallSite]]) throws -> Calls {
        let asked = rows.compactMap { row in owners[row.id].map { (name: row.name, owner: $0) } }
        var calls = Calls(types: asked.map(\.owner.type))
        var judged: [(site: SyntacticCallSite, verdicts: [(type: String, verdict: Verdict)])] = []
        var positions: [String: Int] = [:]
        for type in Set(asked.map(\.owner.type)).sorted() {
            for site in sitesByName[type] ?? [] {
                let verdicts = try asked.filter { $0.owner.type == type }.compactMap { try verdict(of: site, passing: $0.name, to: $0.owner).map { (type, $0) } }
                let key = "\(site.path):\(site.line):\(site.calleeAt ?? "")"
                guard let position = positions[key] else {
                    positions[key] = judged.count
                    judged.append((site, verdicts))
                    continue
                }
                judged[position].verdicts += verdicts
            }
        }
        for (site, verdicts) in judged {
            switch verdicts.map(\.verdict).min() {
            case .passed: calls.passed.append(site)
            case let .flagged(flag): calls.flagged.append((site, flag))
            case .onUntoldSelf: calls.onUntoldSelf.append((site, Set(verdicts.filter { $0.verdict == .onUntoldSelf }.map(\.type)).sorted()))
            case .unfitOnSelf: calls.unfitOnSelf += 1
            case .unfit: calls.unfit += 1
            case .unread: calls.unread += 1
            case nil: break
            }
        }
        return calls
    }

    /// What the scan tells of `site` as a call passing `label` to `owner`'s memberwise initializer, or `nil` where it writes no such label.
    private func verdict(of site: SyntacticCallSite, passing label: String, to owner: Owner) throws -> Verdict? {
        guard let arguments = site.arguments, arguments.labels.contains(label) else { return nil }
        // `Self` in an extension of a type the scan cannot tell writes no scope to resolve; one whose labels the memberwise init cannot take would not compile on the struct, so it is no call of it, but is counted where no struct asked takes it.
        if site.callsUntoldSelf {
            return owner.labels?.accepts(arguments) == false ? .unfitOnSelf : .onUntoldSelf
        }
        guard let labels = owner.labels else { return .unread }
        guard labels.accepts(arguments) else { return .unfit }
        let types = candidates[owner.type] ?? []
        guard let resolver, !site.isAttribute, !types.isEmpty else { return .passed }
        // One the index reads as another type's, or as no type's, is kept and flagged: reading a qualifier from the index alone is not sound.
        let resolved = try resolver.owners(of: site, among: types)
        let read = QualifierReadings.flag(of: resolved, site: site, among: types, asked: [owner.path])
        let flag = read.isEmpty ? SameNamedTypes.flag(of: resolved, for: [owner.path]) : read
        return flag.isEmpty ? .passed : .flagged(flag)
    }
}

extension MemberwiseLabelSites {
    /// The struct whose memberwise initializer takes a property.
    private struct Owner {
        /// Its simple name, which its calls are found by.
        let type: String
        /// Its module-qualified path, which a call's resolved types are checked against.
        let path: String
        /// Its memberwise initializer's labels, or `nil` where its stored properties do not tell them.
        let labels: ParameterLabels?
    }

    /// What the scan tells of one call, best first.
    private enum Verdict: Comparable {
        case passed
        case flagged(String)
        case onUntoldSelf
        case unfitOnSelf
        case unfit
        case unread
    }

    /// The calls writing a property's label to its struct's name, by what the scan could tell of each.
    struct Calls {
        /// The names of the structs the calls were found by.
        let types: [String]
        /// Calls the memberwise initializer takes, building the struct by all the scan can tell.
        var passed: [SyntacticCallSite] = []
        /// Calls the memberwise initializer takes that may build another type of the name, each with the flag saying why.
        var flagged: [(site: SyntacticCallSite, flag: String)] = []
        /// Calls written `Self(…)` in an extension of a type the scan cannot tell, which may build the struct or any other type, each with the structs whose memberwise init may take it.
        var onUntoldSelf: [(site: SyntacticCallSite, types: [String])] = []
        /// Calls written `Self(…)` in an extension of a type the scan cannot tell whose labels no asked struct's memberwise initializer takes.
        var unfitOnSelf = 0
        /// Calls whose labels the memberwise initializer does not take.
        var unfit = 0
        /// Calls of a struct whose memberwise labels could not be worked out, so the scan cannot tell whether the initializer takes them.
        var unread = 0

        /// The calls listed with the property's uses.
        var listed: [SyntacticCallSite] {
            passed + flagged.map(\.site) + onUntoldSelf.map(\.site)
        }

        /// The flag a listed call carries where it may build another type of the name, or `""`.
        func flag(of site: SyntacticCallSite) -> String {
            if let held = onUntoldSelf.first(where: { $0.site == site }) {
                return " (Self(…) on a type the scan cannot tell, which may be \(held.types.joined(separator: " or ")))"
            }
            return flagged.first { $0.site == site }?.flag ?? ""
        }

        /// The clauses a heading counts these calls in, each saying only what was checked of them, for a property written `label`: the first names its calls, as nothing before it may.
        ///
        /// `pointer` names the flag that lists the calls the answer only counts, said after the last clause of calls it would list.
        func clauses(label: String, pointer: String? = nil) -> [String] {
            let type = Array(Set(types)).sorted().joined(separator: " or ")
            var clauses: [(count: Int, text: String)] = []
            if !passed.isEmpty {
                clauses.append((passed.count, "passing it as \(label): to the memberwise init"))
            }
            if !flagged.isEmpty {
                clauses.append((flagged.count, "\(passed.isEmpty ? "" : "more ")writing \(label): to \(type)(…) that may build another type named \(type), flagged"))
            }
            if !onUntoldSelf.isEmpty {
                clauses.append((onUntoldSelf.count, "\(passed.isEmpty && flagged.isEmpty ? "" : "more ")writing \(label): to Self(…) on a type the scan cannot tell, which may be \(Set(onUntoldSelf.flatMap(\.types)).sorted().joined(separator: " or ")), flagged"))
            }
            if unfit > 0 {
                clauses.append((unfit, "writing \(label): to \(type)(…) with labels its memberwise init does not take, not listed"))
            }
            if unfitOnSelf > 0 {
                clauses.append((unfitOnSelf, "writing \(label): to Self(…) that no asked type's memberwise init takes, not listed"))
            }
            if unread > 0 {
                clauses.append((unread, "writing \(label): to \(type)(…) not listed, as its memberwise labels could not be worked out"))
            }
            let lastListable = (passed.isEmpty ? 0 : 1) + (flagged.isEmpty ? 0 : 1) + (onUntoldSelf.isEmpty ? 0 : 1) - 1
            return clauses.enumerated().map { index, clause in
                let said = index == 0 ? "\(clause.count) \(clause.count == 1 ? "call" : "calls") \(clause.text)" : "\(clause.count) \(clause.text)"
                return index == lastListable ? said + (pointer.map { " (\($0) lists them)" } ?? "") : said
            }
        }
    }
}
