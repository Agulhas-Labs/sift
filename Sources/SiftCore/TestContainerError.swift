//
// Copyright © Agulhas Labs
//

import Foundation

/// The refusals a run owes when nothing it can see says which project or workspace to build.
public enum TestContainerError: Error, CustomStringConvertible, Sendable {
    /// More than one workspace where one had to be chosen, with their names and the directory holding them.
    case severalWorkspaces([String], directory: URL)

    /// More than one project where one had to be chosen, with their names and the directory holding them.
    case severalProjects([String], directory: URL)

    /// Neither a workspace nor a project in any directory the run looked in, with the directories it looked in.
    case nothingFound([URL])

    public var description: String {
        switch self {
        case let .severalWorkspaces(names, directory):
            "\(directory.path) holds \(names.count) workspaces — \(TestContainerError.listed(names)) — and one run builds through one: name it with --workspace <path>"
        case let .severalProjects(names, directory):
            "\(directory.path) holds \(names.count) projects — \(TestContainerError.listed(names)) — and one run builds one: name it with --project <path>"
        case let .nothingFound(directories):
            "no .xcworkspace or .xcodeproj in \(TestContainerError.listed(directories.map(\.path))): name one with --project <path> or --workspace <path>"
        }
    }

    /// What was found, as a refusal states it — every name, since the reader's next step is to name one of them.
    private static func listed(_ names: [String]) -> String {
        names.sorted().joined(separator: ", ")
    }
}
