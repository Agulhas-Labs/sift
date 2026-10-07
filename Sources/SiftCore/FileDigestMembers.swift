//
// Copyright © Agulhas Labs
//

import Foundation

/// The member lines a file digest prints beneath each top-level container of one file.
///
/// A file digest enumerates the members of its top-level declarations and only names those of a type one level down, which keeps a file of several nested types short. A file whose only type sits inside an extension of its namespace is a single type in effect, so that type's members are the file's and are enumerated beneath it with their ranges.
struct FileDigestMembers {
    let renderer: DigestRenderer
    /// The file's one type where an extension wraps it, whose members are enumerated rather than named.
    let expanded: Int64?

    /// Reads which type, if any, the file's top-level declarations wrap as the file's only type.
    ///
    /// A type declared at top level, or a second one directly inside an extension, keeps the naming for all of them.
    init(renderer: DigestRenderer, topLevel: [SymbolRow]) throws {
        self.renderer = renderer
        guard !topLevel.contains(where: \.kind.isTypeDeclaration) else {
            expanded = nil
            return
        }
        var wrapped: [SymbolRow] = []
        for row in topLevel where row.kind == .extensionKind {
            wrapped += try renderer.store.children(of: row.id).filter(\.kind.isTypeDeclaration)
        }
        expanded = wrapped.count == 1 ? wrapped.first?.id : nil
    }

    /// Every line the file digest lists before it is paged, in source order: each of `topLevel`, then the lines beneath it — each line carrying the declaration it names, so a page's reach can be read off the lines it keeps.
    func budget(topLevel: [SymbolRow], suites: SuiteAnnotation?, options: DigestOptions, outlineBudget: inout Int) throws -> [DigestRenderer.BudgetedLine] {
        var budgeted: [DigestRenderer.BudgetedLine] = []
        for row in topLevel {
            // Names are suppressed at this level alone: the children are enumerated as full member lines directly
            // beneath, so naming them on the summary line prints each one twice in the answer whose whole purpose
            // is compression.
            let line = try renderer.containerAwareLine(row, options: options, indent: "", outlineBudget: &outlineBudget, namingChildren: false)
            budgeted.append(DigestRenderer.BudgetedLine(text: line, counted: true, row: row))
            guard row.kind.isContainer else { continue }
            budgeted += try lines(under: row, suites: suites, options: options, outlineBudget: &outlineBudget)
        }
        return budgeted
    }

    /// The lines beneath `row`, and beneath the one member of it this file expands.
    func lines(
        under row: SymbolRow,
        suites: SuiteAnnotation?,
        options: DigestOptions,
        outlineBudget: inout Int
    ) throws -> [DigestRenderer.BudgetedLine] {
        var budgeted: [DigestRenderer.BudgetedLine] = []
        let suite = try suites?.suite(owning: row)
        for child in try renderer.store.children(of: row.id) {
            // One level down the children are *not* enumerated, so the same suppression here would leave a
            // nested container as a bare signature — neither its members nor even their number. The exception is
            // the file's one type where an extension wraps it, whose members are enumerated beneath it instead.
            let expands = child.id == expanded
            let line = try renderer.containerAwareLine(
                child,
                options: options,
                indent: "    ",
                outlineBudget: &outlineBudget,
                namingChildren: !expands
            )
            // Eligibility (and, for a test, recording it as the suite's latest) is decided now, over every
            // child whatever page ends up served; the source itself is inlined only into the members a
            // page actually keeps.
            var helper: SymbolRow?
            if let suites, let suite, try suites.classify(child, suite: suite) {
                helper = child
            }
            budgeted.append(DigestRenderer.BudgetedLine(text: line, counted: true, helper: helper, row: child))
            guard expands else { continue }
            // The expanded child is a type in its own right, not a member of `row`, so its own members are
            // classified against *its* suite — the same lookup the top-level path runs over a type's own
            // children — rather than the suite (if any) that owns `row`.
            let innerSuite = try suites?.suite(owning: child)
            for member in try renderer.store.children(of: child.id) {
                var innerHelper: SymbolRow?
                if let suites, let innerSuite, try suites.classify(member, suite: innerSuite) {
                    innerHelper = member
                }
                try budgeted.append(DigestRenderer.BudgetedLine(
                    text: renderer.containerAwareLine(member, options: options, indent: "        ", outlineBudget: &outlineBudget),
                    counted: true,
                    helper: innerHelper,
                    row: member
                ))
            }
        }
        return budgeted
    }
}
