//
// Copyright © Agulhas Labs
//

import Foundation

/// The project or workspace a run was not given, decided from the names one directory holds.
///
/// Apart from the command that calls it because the deciding is the part worth pinning: which candidate wins over which, which names are not candidates at all, and what a directory that decides nothing hands back.
public struct TestContainerChoice {
    /// The container `names` decide on inside `directory`, or `nil` where they name no candidate at all — the caller's cue to look somewhere else.
    ///
    /// **One workspace wins over any number of projects**: a workspace exists to say which projects are built together, so where there is one, building a project inside it directly is the wrong build. **More than one workspace refuses rather than falling through to the projects beside it**, because the thing that would have decided is itself undecided, and choosing a project there would be a guess dressed as a default. An `.xcworkspace` inside an `.xcodeproj` is the one Xcode keeps for its own use and is never a candidate — the path a scheme is built through is the project itself.
    ///
    /// The container comes back as an absolute path: the directory that held it is not always the one every `xcodebuild` is started from.
    public static func chosen(among names: [String], in directory: URL) throws -> TestInvocation.Container? {
        let workspaces = names.filter { $0.hasSuffix(".xcworkspace") && !$0.contains(".xcodeproj/") }
        if workspaces.count == 1, let name = workspaces.first {
            return .workspace(TestContainerChoice.path(of: name, in: directory))
        }
        guard workspaces.isEmpty else {
            throw TestContainerError.severalWorkspaces(workspaces, directory: directory)
        }
        let projects = names.filter { $0.hasSuffix(".xcodeproj") }
        if projects.count == 1, let name = projects.first {
            return .project(TestContainerChoice.path(of: name, in: directory))
        }
        guard projects.isEmpty else {
            throw TestContainerError.severalProjects(projects, directory: directory)
        }
        return nil
    }

    private static func path(of name: String, in directory: URL) -> String {
        directory.appendingPathComponent(name).path
    }

    /// The container a run builds: the working directory's own names decide it first, then the repository root's — but a SwiftPM manifest in the working directory settles it there, `nil`, before the root is ever asked.
    ///
    /// A package built from a directory nested under a repository root that holds an app's own project must never pick up that project: the manifest is the working directory's answer, whatever sits above it.
    public static func chosen(inWorkingDirectory workingDirectory: URL, names workingDirectoryNames: [String], andRepositoryRoot repositoryRoot: URL?, names repositoryRootNames: [String]) throws -> TestInvocation.Container? {
        if let chosen = try TestContainerChoice.chosen(among: workingDirectoryNames, in: workingDirectory) {
            return chosen
        }
        if workingDirectoryNames.contains(where: SwiftPMManifest.isManifestPath) {
            return nil
        }
        guard let repositoryRoot else {
            throw TestContainerError.nothingFound([workingDirectory])
        }
        if let chosen = try TestContainerChoice.chosen(among: repositoryRootNames, in: repositoryRoot) {
            return chosen
        }
        throw TestContainerError.nothingFound([workingDirectory, repositoryRoot])
    }
}
