//
// Copyright © Agulhas Labs
//

/// A cross-root lead for a missed name: another registered root whose last index accounts for it, and how.
///
/// The verb is carried rather than assumed because the two relations are different promises: a root that *declares* the name holds the type itself, one that *extends* it holds members bolted onto a type declared in some dependency no registry indexed. Saying "declared" for both would lie about exactly the thing the caller is trying to locate.
public struct SiblingPointer: Sendable, Equatable {
    public let root: String
    /// `true` when the root's index declares the name; `false` when it only extends a type of that name.
    public let declares: Bool

    public init(root: String, declares: Bool) {
        self.root = root
        self.declares = declares
    }

    /// The pointer as both renderers print it.
    public func line(for name: String) -> String {
        "\(name) is \(declares ? "declared" : "extended") in \(root) (per that root's last index) — retry with root=\(root)"
    }
}
