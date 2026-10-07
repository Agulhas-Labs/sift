//
// Copyright © Agulhas Labs
//

/// What makes a call site a call of a property wrapper's `init(projectedValue:)`: the parameters declared with that wrapper that one of its `$label:` arguments can be passed to.
struct ProjectedCall: Sendable, Equatable {
    /// The parameters declared with the wrapper that the call's labels reach, one per declaration, several where the scan cannot tell which declaration is called.
    var parameters: [WrappedParameter]
    /// The other wrappers a same-named declaration the call's labels reach as well declares for the same `$label:`, sorted, where labels alone cannot tell which of them the call constructs.
    var otherWrappers: [String]

    /// The note a listed site carries where its labels also reach a parameter declared with another wrapper, or `""`.
    var flag: String {
        otherWrappers.isEmpty ? "" : " (labels also reach an overload declaring " + otherWrappers.map { "@" + $0 }.joined(separator: " or ") + ")"
    }
}
