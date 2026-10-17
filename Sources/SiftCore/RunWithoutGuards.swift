//
// Copyright © Agulhas Labs
//

import Foundation

/// The tests `--guard` names: ones the proof expects to pass both ways, judged apart from the tests that are meant to pin the change.
///
/// A guard checks that the change does not reach too far, so it passing without the change is the point rather than a finding. A guard matches by exact name, or by bare identifier where written as one, and never more than one test: a pattern that also caught a test meant to pin would hide the one failure this gate exists to show.
struct RunWithoutGuards {
    /// The guards the caller named, each once, in the order they were written.
    let names: [String]

    init(_ named: [String]) {
        var seen: Set<String> = []
        names = named.filter { seen.insert($0).inserted }
    }

    /// Whether a name a run printed is the test `named` points at.
    ///
    /// A guard written as a bare identifier (letters, digits and `_`, then optionally `()`) matches by identifier, whether the run printed the test bare or with its argument labels (`name(count:label:)`), and only a printed name that is not a quoted display name. Any other guard matches only the printed name written the same way, with or without its surrounding double quotes.
    static func matches(_ printed: String, _ named: String) -> Bool {
        if isBareIdentifier(named) {
            return !printed.contains("\"") && RunWithoutAnswer.identifier(of: printed) == RunWithoutAnswer.identifier(of: named)
        }
        return printed == named || unquoted(printed) == unquoted(named)
    }

    private static func isBareIdentifier(_ named: String) -> Bool {
        let body = named.hasSuffix("()") ? String(named.dropLast(2)) : named
        return !body.isEmpty && body.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "_" }
    }

    private static func unquoted(_ text: String) -> String {
        text.count >= 2 && text.hasPrefix("\"") && text.hasSuffix("\"") ? String(text.dropFirst().dropLast()) : text
    }

    /// The distinct printed names `named` matches, sorted.
    private static func matched(_ named: String, among printed: [String]) -> [String] {
        Set(printed.filter { matches($0, named) }).sorted()
    }

    /// Whether a name a run printed is one a guard names: matched by a guard that matches no other printed name.
    func isNamed(_ printed: String, among all: [String]) -> Bool {
        names.contains { Self.matches(printed, $0) && Self.matched($0, among: all).count == 1 }
    }

    /// Whether the guard held: it matched exactly one test, and that test passed both ways.
    private func holds(_ named: String, in tests: [RunWithoutAnswer.TestLine]) -> Bool {
        let matched = tests.filter { Self.matches($0.name, named) }
        return matched.count == 1 && matched[0].standing == .guardHolds
    }

    /// Whether every guard matched a test and held; true where none was named.
    func allHold(in tests: [RunWithoutAnswer.TestLine]) -> Bool {
        names.allSatisfy { holds($0, in: tests) }
    }

    /// How many guards held out of the guards named, as a sentence reads it: `1 of 2 named guards`.
    func tally(_ tests: [RunWithoutAnswer.TestLine]) -> String {
        "\(names.count { holds($0, in: tests) }) of \(names.count) named guards"
    }

    /// The clause the headline ends with when guards were named, or nothing where none was.
    func clause(_ tests: [RunWithoutAnswer.TestLine]) -> String {
        let held = names.count { holds($0, in: tests) }
        guard !names.isEmpty else {
            return ""
        }
        if held == names.count {
            return "; \(held) named \(held == 1 ? "guard passes" : "guards pass") both ways"
        }
        return "; \(held) of \(names.count) named guards \(held == 1 ? "passes" : "pass") both ways"
    }

    /// One line for each guard that matched no test either run printed, or more than one.
    func unmatchedLines(_ tests: [RunWithoutAnswer.TestLine]) -> [String] {
        names.compactMap { named in
            let matched = Self.matched(named, among: tests.map(\.name))
            return switch matched.count {
            case 0:
                "  ⚠ \(named) — named by --guard, but no test of that name ran"
            case 1:
                nil
            default:
                "  ⚠ \(named) — named by --guard, but it matches \(matched.count) tests (\(matched.prefix(3).joined(separator: ", "))); name the one meant as the run printed it"
            }
        }
    }
}

extension RunWithoutAnswer {
    /// The guards the caller named, ready to match and judge the tests a run printed.
    var guardSet: RunWithoutGuards {
        RunWithoutGuards(guards)
    }

    /// Where a guard stands, once both runs reached the tests: held where it passed both ways, failed where both ran and it did not, and undecided where one run never printed it.
    func judgeGuard(_ before: Outcome, _ after: Outcome, name: String) -> (Standing, String) {
        let withIt = failureDetail(of: name).map { " — with it: \($0)" } ?? ""
        return switch (before, after) {
        case (.passed, .passed):
            (.guardHolds, "a named guard: passes without the change and with it")
        case (.absent, _):
            (.undecided, "named as a guard; did not run without the change; \(describe(after)) with it")
        case (_, .absent):
            (.undecided, "named as a guard; \(describe(before)) without the change, and did not run with it")
        default:
            (.guardFails, "named as a guard, but \(describe(before)) without the change and \(describe(after)) with it\(withIt)")
        }
    }
}
