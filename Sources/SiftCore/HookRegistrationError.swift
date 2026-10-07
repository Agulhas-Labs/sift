//
// Copyright © Agulhas Labs
//

/// The one failure a caller must not paper over: unreadable settings.
///
/// Everything else about registering the hook is best-effort, but a `settings.json` that will not parse must stop the install rather than be overwritten — the file predates this tool and may hold the user's entire Claude Code configuration.
///
/// `Equatable` is spelled out because it is not free: an enum with no associated values gets that conformance implicitly, and `hooksNotMergeable` ends it — without the annotation the `#expect(throws: .settingsNotAnObject)` tests do not compile.
public enum HookRegistrationError: Error, Equatable, CustomStringConvertible {
    case settingsNotAnObject
    /// A `hooks` object, an event's array, or an entry's hook list is present but not the shape a registration merges into.
    ///
    /// Separated from "absent" on purpose. Absent means start from empty; the wrong shape means something is there that a merge would have to replace, and replacing a user's configuration to install a hook is never the right trade — the same judgement the status line makes about its single slot.
    case hooksNotMergeable(key: String)
    /// A `permissions` object or its `allow` list is present but not the shape an allow rule is added to or removed from.
    case permissionsNotMergeable(key: String)

    public var description: String {
        switch self {
        case .settingsNotAnObject:
            "settings.json is not a JSON object — refusing to rewrite it. Fix or move the file, then re-run."
        case let .hooksNotMergeable(key):
            "settings.json's \"\(key)\" is not the shape a Claude Code hook registration takes — refusing to rewrite it, because merging would mean replacing what is there. Fix or move the file, then re-run."
        case let .permissionsNotMergeable(key):
            "settings.json's \"\(key)\" is not the shape Claude Code's permission rules take — refusing to rewrite it, because merging would mean replacing what is there. Fix or move the file, then re-run."
        }
    }
}
