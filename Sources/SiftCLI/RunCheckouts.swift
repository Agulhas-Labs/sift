//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// The checkout `sift run` was started in and the one its command builds, which a `--package-path`, `-C` or `-project` naming another repository makes two.
///
/// Read by ``RunCommandKind/builtDirectory(of:from:)``, the reading the stop gate's transcript reader places a run by, so the run and the gate agree on which checkout it built.
struct RunCheckouts {
    /// The repository `sift run` was started in, `nil` outside one.
    let launched: URL?
    /// The directory the command reads its project from — `nil` where a flag spells it through a variable.
    let builtDirectory: String?
    /// The repository the command builds: ``launched`` unless a flag names a directory in another, and `nil` where that is spelled through a variable or lies in no repository.
    let built: URL?

    init(arguments: [String], workingDirectory: URL, launched: URL?) {
        self.launched = launched
        builtDirectory = RunCommandKind.builtDirectory(of: arguments, from: workingDirectory.path)
        built = builtDirectory.flatMap { $0 == workingDirectory.path ? launched : GitContext.discoverRoot(from: URL(fileURLWithPath: $0)) }
    }

    /// Whether the command builds a checkout other than ``launched``, or one nobody can name: a build of a sibling package says nothing about the tree `sift run` was started in.
    var buildsElsewhere: Bool {
        built.map { CanonicalPath.of($0.path) } != launched.map { CanonicalPath.of($0.path) }
    }

    /// Why `--without` or `--without-line` refuses this command, or `nil` where it builds the checkout the change is set aside from.
    ///
    /// Refused rather than followed: the pathspec names files in the checkout `sift run` was started in, and setting them aside proves nothing about a command that builds another one.
    func setAsideRefusal(flag: String) -> String? {
        guard buildsElsewhere else {
            return nil
        }
        let reads = builtDirectory.map { "builds \($0)" } ?? "names the directory it builds through a variable"
        return "sift run \(flag): the command \(reads), not the checkout the change is set aside from — run it from the checkout it builds."
    }
}
