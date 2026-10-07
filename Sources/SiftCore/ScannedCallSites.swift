//
// Copyright © Agulhas Labs
//

/// What the call-site scan of one file found: its sites, and what decides whether its attributes are sites at all.
struct ScannedCallSites: Sendable {
    /// The sites found, by the name asked for.
    var sites: [String: [SyntacticCallSite]] = [:]
    /// The `@T` attributes on a stored property or a parameter, by T: sites of T's initializer only where T is a property wrapper.
    var attributeSites: [String: [SyntacticCallSite]] = [:]
    /// The types asked for that the file declares `@propertyWrapper`.
    var propertyWrappers: Set<String> = []
    /// The labelled parameters declared with `@T`, by T: where a `$label:` argument calls T's `init(projectedValue:)`.
    var wrappedParameters: [String: [WrappedParameter]] = [:]
}
