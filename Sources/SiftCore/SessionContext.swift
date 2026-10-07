//
// Copyright © Agulhas Labs
//

/// What a starting session is sitting in, as far as this tool is concerned.
///
/// The distinction that matters is `insideRoot` versus `aboveRoots`: a session rooted at one repo can query without naming it, while one rooted above several (a portfolio session) must pass `root:` on every call or get nothing. The second case is a common one and the silent failure mode, so the primer answers it up front instead of leaving the first query to dead-end.
public enum SessionContext: Equatable, Sendable {
    /// The working directory is at or under one indexed root — queries need no `root:`.
    ///
    /// A repository whose index is on disk reads as this whether or not the roots registry remembers it.
    case insideRoot(String)
    /// The working directory is above one or more indexed roots — every query must name one.
    case aboveRoots([String])
    /// A Swift repository with no usable index on disk, whatever the roots registry holds; the first query will index it.
    case unregisteredSwiftRepository(String)
    /// Nothing Swift in view, so the primer stays silent.
    case none
}
