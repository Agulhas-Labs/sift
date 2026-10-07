//
// Copyright © Agulhas Labs
//

/// `diff`'s own options: the range, an optional member to show the before/after body of instead of the change summary, and the page of declaration entries to show.
public struct DiffOptions: Sendable, Equatable {
    public var range: DiffRange
    public var member: String?
    /// Declaration entries skipped before the page starts — the cursor a `truncated:` marker names.
    public var offset: Int

    public init(range: DiffRange, member: String? = nil, offset: Int = 0) {
        self.range = range
        self.member = member
        self.offset = max(0, offset)
    }
}
