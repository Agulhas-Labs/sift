//
// Copyright © Agulhas Labs
//

import Foundation

/// The failing tests of a run grouped by the file each failed in — what a fixer needs and a signature listing, which groups by wording, does not give.
///
/// **Printed only where the failure section above it leaves something to ask for.** A listing that names every failure with its location already is this block, and repeating it would be the same names twice. A block that illustrates a few signatures leaves the rest of the tests unnamed, and a failure the framework printed no location for is named without its file: either one earns the block, which then lists *every* failing test, so the reader has one place to take the whole set from.
///
/// **Every name comes from a failure the run's output filter recorded**, never from a search of the log's text, so a test name quoted inside an expectation's argument is only ever part of that argument.
public struct RunFailingByFile: Sendable, Equatable {
    /// How many test names the block prints before it counts the rest.
    public static let nameCap = 60

    /// The line that opens the block.
    public static var heading: String {
        "failing tests by file:"
    }

    /// What the tests with no file location are grouped under.
    public static var unplaced: String {
        "(no location)"
    }

    let groups: [Group]
    let leavesTestsToName: Bool

    /// Groups `failures` by file, and notes whether the failure section left any of them to this block.
    ///
    /// - Parameter named: The names the failure section above already printed.
    public init(failures: [RunFailureShape.Failure], named: Set<String>) {
        var order: [Placement] = []
        var seen: Set<Placement> = []
        var located: Set<String> = []
        var names: Set<String> = []
        for failure in failures {
            let placement = Placement(name: failure.name, file: failure.path.map(Self.fileName(of:)))
            names.insert(failure.name)
            if placement.file != nil {
                located.insert(failure.name)
            }
            if seen.insert(placement).inserted {
                order.append(placement)
            }
        }
        var tests: [String?: [String]] = [:]
        for placement in order {
            tests[placement.file, default: []].append(Self.displayName(of: placement.name))
        }
        groups = tests
            .map { Group(file: $0.key, tests: $0.value) }
            .sorted(by: Self.precedes)
        leavesTestsToName = names.contains { !named.contains($0) || !located.contains($0) }
    }

    /// The block, or no lines where the failure section above already named every failing test with its file.
    public func rendered() -> [String] {
        guard leavesTestsToName, !groups.isEmpty else {
            return []
        }
        var lines = [Self.heading]
        var remaining = Self.nameCap
        var unlisted = 0
        var filesCut = 0
        for group in groups {
            let shown = group.tests.prefix(remaining)
            remaining -= shown.count
            if shown.count < group.tests.count {
                unlisted += group.tests.count - shown.count
                filesCut += 1
            }
            guard !shown.isEmpty else {
                continue
            }
            let names = shown.map { RunFailureCensus.clipped($0) }.joined(separator: ", ")
            lines.append("  \(group.file ?? Self.unplaced) (\(group.tests.count)): \(names)")
        }
        if unlisted > 0 {
            lines.append("  +\(unlisted) more failing test\(unlisted == 1 ? "" : "s") in \(filesCut) file\(filesCut == 1 ? "" : "s")")
        }
        return lines
    }
}

extension RunFailingByFile {
    /// One file's failing tests, in the order each first failed.
    struct Group: Sendable, Equatable {
        /// The bare file name, or `nil` for the tests whose failures named no file.
        let file: String?
        let tests: [String]
    }

    /// One test as one file saw it fail: a test that failed in two files is listed under both.
    struct Placement: Hashable {
        let name: String
        let file: String?
    }

    /// Most failing tests first, then by file name, with the tests that named no file last.
    static func precedes(_ lhs: Group, _ rhs: Group) -> Bool {
        switch (lhs.file, rhs.file) {
        case let (left?, right?):
            lhs.tests.count != rhs.tests.count ? lhs.tests.count > rhs.tests.count : left < right
        case (_?, nil):
            true
        default:
            false
        }
    }

    /// The last component of the path the framework printed.
    static func fileName(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// A test as the runner identifies it: a Swift Testing function name as printed, and an XCTest log name as `Class.method`.
    static func displayName(of name: String) -> String {
        guard let logged = TestIdentifier.xctestLogName(name) else {
            return name
        }
        let type = logged.qualifiedType.split(separator: ".").last.map(String.init) ?? logged.qualifiedType
        return "\(type).\(logged.method)"
    }
}

extension RunFailingByFile {
    /// The paragraph `sift help run-output` gives this block.
    static var helpNote: String {
        """
        **A sample leaves tests unnamed, so a block ends the failures** where one does, or where a test is \
        named without its file: `failing tests by file:`, then one line per file, `File.swift (12): name, \
        name, …`, the files with most failing tests first, 60 names in all and then `+N more failing tests \
        in M files`. It lists every test that recorded a failure, so a fix round's list needs no grep of the \
        raw log; a test that crashed records none, and the crash line above names it instead. A full listing \
        already names each test with its file and has no such block.
        """
    }
}
