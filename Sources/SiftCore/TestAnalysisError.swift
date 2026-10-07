//
// Copyright © Agulhas Labs
//

/// What stops `test --analyse` answering: a narrowing that names nothing, which is the one thing it cannot answer around.
public enum TestAnalysisError: Error, CustomStringConvertible, Sendable {
    /// `--plan` named a plan no `.xctestplan` under the repository carries, listed with the names that were found.
    case noSuchPlan(name: String, found: [String])

    public var description: String {
        switch self {
        case let .noSuchPlan(name, found):
            guard !found.isEmpty else {
                return "no test plan is named \(name), and no .xctestplan was found under this repository at all — drop --plan and the answer covers every declared test, which is what a package with no plans runs."
            }
            return "no test plan is named \(name). The plans found under this repository are: \(found.joined(separator: ", ")). Pass one of those, or drop --plan to answer over all of them."
        }
    }
}
