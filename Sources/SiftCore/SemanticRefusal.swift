//
// Copyright © Agulhas Labs
//

/// One declaration the index store cannot be asked about, and why — the shared vocabulary of the semantic axis's refusals.
///
/// A type of its own because both `where` and `affected` read it. The rule it carries is the one Docs/Design.md §2 makes non-negotiable — a symbol whose file was written since the build is refused rather than answered from stale data — and a second copy of it would be a second thing to get wrong. `where` and `affected` refuse in the same words because they refuse for the same reason, and a reader who has learned to act on one has learned to act on the other.
struct SemanticRefusal {
    let path: String
    let reason: Reason
    let symbol: String
    let kind: SymbolKind
    /// The command that rebuilds the store owning this declaration's file, where one is known — named in the staleness instruction so the reader runs the build that actually refreshes it, not a generic one.
    var rebuild: Rebuild?

    var group: Group {
        Group(path: path, reason: reason)
    }
}

extension SemanticRefusal {
    /// The refusal for `row`, a declaration no store in `context` resolves: its reason by `Reason.unowned`, from whether its file was `modified` since the build, whether any store has a unit for it, and the `#if` it sits under as `IfConfigLabel` names it from `source`; with the primary store's rebuild.
    static func unowned(_ row: SymbolRow, symbol: String, imports: [String], modified: Bool, context: SemanticContext, source: ((String) -> String?)?) -> SemanticRefusal {
        let fileHasUnit = context.anyStoreHasUnit(forFile: row.path)
        let condition = fileHasUnit ? IfConfigLabel.label(for: row, source: source) : nil
        let reason = Reason.unowned(modified: modified, fileHasUnit: fileHasUnit, condition: condition)
        return SemanticRefusal(path: row.path, reason: reason, symbol: symbol, kind: row.kind, rebuild: Rebuild(provenance: context.store.provenance, imports: imports))
    }
}

extension SemanticRefusal {
    /// A rebuild a staleness refusal can name exactly, rather than "build the project".
    enum Rebuild: Hashable {
        /// An in-tree `xcodebuild` store, by its build directory.
        case derivedDataPath(String)
        /// SwiftPM's `.build`, with `--build-tests` where a refused file is a test file: a plain `swift build` never rebuilds a test target.
        case swiftPM(buildTests: Bool)

        /// The rebuild for a file importing `imports` in the store `provenance` names, or `nil` where no one command is known.
        init?(provenance: DiscoveredStore.Provenance, imports: [String]) {
            switch provenance {
            case let .inTree(directory): self = .derivedDataPath(directory)
            case .swiftPMBuild: self = .swiftPM(buildTests: TestFileRecognition.isTestFile(imports: imports))
            case .config, .buildServerJSON, .derivedData: return nil
            }
        }

        /// One rebuild covering every refusal in `refusals`, or `nil` where they need different ones or any has none known; SwiftPM's with `--build-tests` covers its plain form, which it builds too.
        static func covering(_ refusals: [SemanticRefusal]) -> Rebuild? {
            let rebuilds = Set(refusals.map(\.rebuild))
            guard !rebuilds.isEmpty, !rebuilds.contains(nil) else { return nil }
            if rebuilds.isSubset(of: [.swiftPM(buildTests: false), .swiftPM(buildTests: true)]) {
                return .swiftPM(buildTests: rebuilds.contains(.swiftPM(buildTests: true)))
            }
            guard rebuilds.count == 1, let only = rebuilds.first else { return nil }
            return only
        }
    }
}

extension SemanticRefusal {
    /// Why the store cannot answer for this declaration — never healed by reindexing, since this axis moves only on a build.
    enum Reason: Hashable, Comparable {
        case modifiedSinceBuild
        case noCoveringUnit
        /// The file has a unit in the store, yet no occurrence of the declaration is recorded, and it sits under the `#if` this labels: the build may not have compiled that branch, so no build is named as the fix.
        case unrecordedUnderCondition(String)

        /// The reason a declaration no store owns is refused for: an edit since the build first, since a rebuild certainly fixes that; then a file the store compiled with the declaration under `#if`; then a file no unit covers.
        static func unowned(modified: Bool, fileHasUnit: Bool, condition: String?) -> Reason {
            if modified {
                return .modifiedSinceBuild
            }
            if fileHasUnit, let condition {
                return .unrecordedUnderCondition(condition)
            }
            return .noCoveringUnit
        }

        /// The fact stated of one declaration, after its file's path.
        var rawValue: String {
            switch self {
            case .modifiedSinceBuild: "was changed since the last build"
            case .noCoveringUnit: "has no unit in the store covering this declaration"
            case let .unrecordedUnderCondition(condition): "has " + Self.unrecorded(under: condition, declarationCount: 1)
            }
        }

        /// What the reader should actually do, which differs by cause: an edited file is certainly fixed by a rebuild, a missing unit only might be — and where the store owning the stale file says which build refreshes it, that command rather than the generic advice.
        func instruction(rebuild: Rebuild?) -> String {
            switch self {
            case .modifiedSinceBuild:
                switch rebuild {
                case let .derivedDataPath(directory): "; rebuild with -derivedDataPath \(directory)"
                case let .swiftPM(buildTests): "; rebuild with `sift run -- swift build\(buildTests ? " --build-tests" : "")`, then retry"
                case nil: "; build the project, then retry"
                }
            case .noCoveringUnit:
                // Only a test file gets a command: a plain `swift build` never builds a test target, while a non-test file SwiftPM's own build left without a unit is usually compiled out, which no build fixes.
                rebuild == .swiftPM(buildTests: true)
                    ? "; build with `sift run -- swift build --build-tests`, then retry — it may be in a target the last build skipped"
                    : "; build this target, then retry — it may be in a target the last build skipped"
            case .unrecordedUnderCondition:
                // A branch this build's conditions leave out is compiled by no build of the same configuration, so none is named.
                ""
            }
        }

        /// The same fact stated of several files at once, agreeing with the plural subject the collapsed line puts in front of it ("their files …") — the singular `rawValue` reads as a grammar mistake there.
        var filesClause: String {
            switch self {
            case .modifiedSinceBuild: "were changed since the last build"
            case .noCoveringUnit: "have no unit in the store covering them"
            case let .unrecordedUnderCondition(condition): "hold " + Self.unrecorded(under: condition, declarationCount: 2)
            }
        }

        /// The shorter clause used once the declarations above have already named the path, so the refusal need not repeat it — agreeing with how many declarations it is stated for, so a lone "it" is never left standing for several.
        func shortClause(declarationCount: Int) -> String {
            switch self {
            case .modifiedSinceBuild: "changed since the last build"
            case .noCoveringUnit: declarationCount == 1 ? "no unit in the store covers it" : "no unit in the store covers them"
            case let .unrecordedUnderCondition(condition): Self.unrecorded(under: condition, declarationCount: declarationCount)
            }
        }

        /// The same fact as `rawValue`, agreeing with how many declarations it is stated for — the one-file line states it whether or not it then names them, and the singular wording `rawValue` carries would otherwise claim one declaration for a group that holds several.
        func statedWithoutNaming(declarationCount: Int) -> String {
            switch self {
            // The file is the subject, so an edit to it is singular however many declarations it holds.
            case .modifiedSinceBuild: "was changed since the last build"
            case .noCoveringUnit: declarationCount == 1 ? "has no unit in the store covering this declaration" : "has no unit in the store covering these declarations"
            case let .unrecordedUnderCondition(condition): "has " + Self.unrecorded(under: condition, declarationCount: declarationCount)
            }
        }

        /// The `#if` refusal's own words, agreeing with how many declarations they are stated for.
        private static func unrecorded(under condition: String, declarationCount: Int) -> String {
            declarationCount == 1
                ? "no occurrence recorded in this build; the declaration is under \(condition), which this build may not have compiled"
                : "no occurrences recorded in this build; the declarations are under \(condition), which this build may not have compiled"
        }

        static func < (lhs: Reason, rhs: Reason) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }
}

extension SemanticRefusal {
    /// The grouping key: refusals differing only by declaration collapse onto one line.
    struct Group: Hashable, Comparable {
        let path: String
        let reason: Reason

        static func < (lhs: Group, rhs: Group) -> Bool {
            (lhs.path, lhs.reason) < (rhs.path, rhs.reason)
        }
    }
}

extension SemanticRefusal {
    /// Refusals collapsed to one line per reason — the same file refused for five declarations is one fact, not five, and five different files refused for the same reason are one fact too.
    ///
    /// The header already says how many files are stale, so naming each one again below buys nothing. A reason confined to a single file keeps that file's name and its declarations listed, since there both are still one thing to read; a reason spread across several files loses that detail and states only the count, because the `for N declarations` sentence outgrows what naming every file adds. Different reasons never share a line — a rebuild fixes one kind of refusal and not the other, so folding them together would misdirect the reader.
    ///
    /// Told not to name declarations — where the answer has already listed every one in full, as `where` does above its refusal — the single-file line keeps its reason and instruction, and drops the path too when every declaration it named shares that one file. That short form only ever stands for *every* declaration the answer listed; told otherwise, and given a way to name them, the refused ones are named directly instead, so "it"/"them" has a referent even where the rest of the list was answered.
    static func lines(
        _ refusals: [SemanticRefusal],
        namingDeclarations: Bool = true,
        declarationsSpanMultipleFiles: Bool = false,
        allListedRefused: Bool = true,
        shortName: ((SemanticRefusal) -> String)? = nil
    ) -> [String] {
        guard !refusals.isEmpty else { return [] }
        var byReason: [Reason: [SemanticRefusal]] = [:]
        for refusal in refusals {
            byReason[refusal.reason, default: []].append(refusal)
        }
        var lines: [String] = []
        for reason in byReason.keys.sorted() {
            let reasonRefusals = byReason[reason] ?? []
            if !namingDeclarations, !allListedRefused, let shortName {
                lines.append(contentsOf: namedLines(reasonRefusals, reason: reason, shortName: shortName))
                continue
            }
            let paths = Set(reasonRefusals.map(\.path))
            if paths.count == 1 {
                lines.append(contentsOf: detailLines(reasonRefusals, namingDeclarations: namingDeclarations, declarationsSpanMultipleFiles: declarationsSpanMultipleFiles))
            } else {
                let noun = reasonRefusals.count == 1 ? "declaration" : "declarations"
                lines.append("")
                lines.append("semantic REFUSED for \(reasonRefusals.count) \(noun): their files \(reason.filesClause)\(reason.instruction(rebuild: Rebuild.covering(reasonRefusals)))")
            }
        }
        return lines
    }

    /// The named form: only some of the listed declarations were refused, so the line names the refused ones by `shortName` instead of relying on the path or the listed declarations' file span to imply which they are.
    private static func namedLines(_ refusals: [SemanticRefusal], reason: Reason, shortName: (SemanticRefusal) -> String) -> [String] {
        let names = refusals.map(shortName).sorted().joined(separator: ", ")
        return [
            "",
            "semantic REFUSED for \(names) — \(reason.shortClause(declarationCount: refusals.count))\(reason.instruction(rebuild: Rebuild.covering(refusals)))",
        ]
    }

    /// The one-file form: the file's path, its declarations by name unless told not to name them, and — when every one of them belongs to the same in-tree store — that store's own rebuild command rather than the generic advice.
    ///
    /// Not told to name declarations, and the declarations above already confine themselves to this one file, the path is dropped too — a reader who has just read that file's name in every line above gains nothing from a third repetition, so the reason is stated in the shorter clause instead.
    private static func detailLines(_ refusals: [SemanticRefusal], namingDeclarations: Bool, declarationsSpanMultipleFiles: Bool = false) -> [String] {
        var grouped: [Group: [String]] = [:]
        for refusal in refusals {
            // Kind included because a qualified name alone does not distinguish same-named declarations, which would render as an uninformative "Lib.Base, Lib.Base".
            grouped[refusal.group, default: []].append("\(refusal.symbol) (\(refusal.kind.rawValue))")
        }
        var lines: [String] = []
        for group in grouped.keys.sorted() {
            let symbols = grouped[group] ?? []
            let noun = symbols.count == 1 ? "declaration" : "declarations"
            let rebuild = Rebuild.covering(refusals.filter { $0.group == group })
            lines.append("")
            if !namingDeclarations, !declarationsSpanMultipleFiles {
                lines.append("semantic REFUSED — \(group.reason.shortClause(declarationCount: symbols.count))\(group.reason.instruction(rebuild: rebuild))")
            } else {
                let named = namingDeclarations ? " (\(symbols.count) \(noun): \(symbols.joined(separator: ", ")))" : ""
                let stated = group.reason.statedWithoutNaming(declarationCount: symbols.count)
                lines.append("semantic REFUSED — \(group.path) \(stated)\(group.reason.instruction(rebuild: rebuild))\(named)")
            }
        }
        return lines
    }
}
