//
// Copyright © Agulhas Labs
//

import Foundation

/// What `HEAD`'s reflog says of when the checkout last moved.
struct HeadReflog {
    /// When `HEAD` last moved other than by a commit made on it — a checkout, a pull, a reset, a merge, a rebase — in seconds since 1970, read off its reflog's own entry times, or `nil` when the reflog cannot be read or is empty.
    ///
    /// A commit made on `HEAD` is passed over, as what it brought is dated by its own commit time; a merge commit is not, since what it merged is dated by commits older than it. Where every entry read is such a commit, the oldest one's time stands, which is where the reflog starts. The entry's time is the reflog's, whole seconds, not the time of the commit it moved to: a checkout of an old commit is dated when it happened.
    static func lastMoveTime(in git: GitContext) -> Double? {
        let arguments = ["log", "-g", "-n", "100", "--no-show-signature", "--date=unix", "--format=%gd %gs", "HEAD"]
        guard let output = try? GitContext.run(arguments: arguments, in: git.repoRoot) else { return nil }
        var oldest: Double?
        for entry in output.split(separator: "\n") {
            guard let open = entry.firstIndex(of: "{"), let close = entry.firstIndex(of: "}"), open < close,
                  let time = Double(entry[entry.index(after: open) ..< close]) else { return nil }
            let subject = entry[entry.index(after: close)...].drop { $0 == " " }
            guard commitOnHeadPrefixes.contains(where: { subject.hasPrefix($0) }) else { return time }
            oldest = time
        }
        return oldest
    }

    private static let commitOnHeadPrefixes = ["commit:", "commit (initial):", "commit (amend):", "cherry-pick:"]
}
