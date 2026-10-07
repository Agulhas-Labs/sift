//
// Copyright © Agulhas Labs
//

/// One call site found by name in the working tree, with the declaration that encloses it.
///
/// Explicitly *not* a semantic caller. The index store resolves a caller through a USR and knows it is the same symbol; this is a written-name match and knows only that the spelling agrees. It exists because a refusal the reader cannot act on is worse than a labelled approximation — see `WhereRenderer` for how the two are kept visibly separate.
public struct SyntacticCallSite: Sendable, Equatable {
    public let path: String
    public let line: Int
    /// The declaration containing the call — `SummaryState.load()`, or `(top level)` outside any declaration.
    public let enclosing: String
    /// The declared names of the types the site is written in, outermost first — `Depot` for one in `extension Depot<Int>`.
    let enclosingTypes: [String]
    /// The capitalised names the where clauses of the extensions around the site write — `Depot` for one in `extension Loader where Self: Depot`.
    let enclosingConstraints: [String]
    /// The arguments a call site is written with, or `nil` for a use that is no call.
    let arguments: WrittenArguments?
    /// Whether the site is a function's bare or instance-bound name with no call and no labels — `f`, `x.f` — which a same-named local or property spells the same way, so it is counted beside the list rather than listed in it.
    let nameOnly: Bool
    /// The type a function's bare `T.f` handed to a call is written on — `Self` as written — which makes it a site only where that type declares the function.
    let unappliedOn: String?
    /// What an attribute's or a construction's type is qualified with — `SwiftUI` in `@SwiftUI.State`, `Outer` in `Outer.Inner(x)` — which makes it a site only of a type declared under that module or those types.
    let qualifier: String?
    /// Whether the first name of `qualifier` is a generic parameter declared around the site — `Log` in `Log.Answer` inside `struct Gen<Log: P>` — or a type or typealias declared inside a function in the file, either of which Swift's lookup may find before any type of that name the index holds.
    var qualifiedByGenericParameter: Bool
    /// Whether the site is a property wrapper's `@T` attribute, which calls T's initializer where the index store may record no call.
    let isAttribute: Bool
    /// Whether the site is a `@T` attribute on a function's parameter, the one attribute the index store may record no call at, where it records one on a stored property.
    let isParameterAttribute: Bool
    /// The parameters declared `@T` a `$label:` argument at the site may be passed to, which make the site a call of T's `init(projectedValue:)` the index store may not record.
    let projection: ProjectedCall?
    /// What the call's or the use's receiver is written as, or `nil` for a receiver the scan cannot type and for a site of any other shape.
    var receiver: CallReceiver?
    /// Whether the site is a leading-dot call `.m(x)` with nothing applied after it — no member, call or subscript — which implicit member lookup resolves on its contextual type, where an instance member is only ever handed its instance and so never ends in that type.
    let isUnchainedImplicitMemberCall: Bool
    /// The `line:column` of the name a call is made through — `m` in `x.m(1)`, `T` in `T(1)`, `T` in a wrapper's `@T` attribute — which is where the index store records the call, or `nil` for a site that is no call.
    let calleeAt: String?
    /// The `line:column` of the type name a type use writes — `T` in `M.T`, never the `M` a member type starts at — which is where the index store records the reference, or `nil` for a site that is no type use.
    let nameAt: String?
    /// Whether the site is `Self(x)` or `Self.init call` in an extension of a type its file does not declare, where `Self` may be any type conforming to a protocol, which the scan cannot tell.
    let callsUntoldSelf: Bool
    /// Whether the site writes a type's name bare in the body of a protocol that declares an associated type of the name, which is what Swift reads it as there (``ProtocolBodyScope``).
    var meansOwnAssociatedType = false
    /// Whether the site writes a type's name bare where a struct, class, enum or actor declared in a body around it is what Swift reads it as (``LocalTypeShadow``).
    var meansLocalType = false
    /// Whether the site writes a type's name bare where no type, extension or protocol is around it, and no body around it declares the name or may (``BareNameOutsideTypes``).
    var writtenOutsideTypes = false
    /// The function-local typealias whose right-hand side writes the type at this site as a whole path, or `nil` for any other site.
    var localTypealias: LocalTypealias?
    /// For a type use inside a function, closure or accessor body, the declarations its name written bare may mean among the types and typealiases declared in the blocks around it, by the `line:column` of their names (``LocalTypealias``), or `nil` for any other site.
    var localDeclarations: [String]?
    /// Those of `enclosingTypes` declared inside a function, whose supertypes and members no top-level type of the same name shows.
    var localEnclosingTypes: Set<String> = []
    /// The source line the site is written on, as the name-matched block prints it beside the line number, or `nil` where the scan did not read it.
    var text: String?

    public init(path: String, line: Int, enclosing: String) {
        self.init(path: path, line: line, enclosing: enclosing, enclosingTypes: [], arguments: nil)
    }

    init(
        path: String,
        line: Int,
        enclosing: String,
        enclosingTypes: [String],
        enclosingConstraints: [String] = [],
        arguments: WrittenArguments?,
        nameOnly: Bool = false,
        unappliedOn: String? = nil,
        qualifier: String? = nil,
        qualifiedByGenericParameter: Bool = false,
        isAttribute: Bool = false,
        isParameterAttribute: Bool = false,
        projection: ProjectedCall? = nil,
        receiver: CallReceiver? = nil,
        isUnchainedImplicitMemberCall: Bool = false,
        calleeAt: String? = nil,
        nameAt: String? = nil,
        callsUntoldSelf: Bool = false
    ) {
        self.path = path
        // A call is cited at the line of the name it is made through, not the first line of its expression, so the last call of a multi-line chain is read where it is written.
        self.line = calleeAt.flatMap { Int($0.prefix { $0 != ":" }) } ?? line
        self.enclosing = enclosing
        self.enclosingTypes = enclosingTypes
        self.enclosingConstraints = enclosingConstraints
        self.arguments = arguments
        self.nameOnly = nameOnly
        self.unappliedOn = unappliedOn
        self.qualifier = qualifier
        self.qualifiedByGenericParameter = qualifiedByGenericParameter
        self.isAttribute = isAttribute
        self.isParameterAttribute = isParameterAttribute
        self.projection = projection
        self.receiver = receiver
        self.isUnchainedImplicitMemberCall = isUnchainedImplicitMemberCall
        self.calleeAt = calleeAt
        self.nameAt = nameAt
        self.callsUntoldSelf = callsUntoldSelf
    }

    /// Whether the site is listed among a function's sites rather than counted beside them, where `owners` are the simple names of the types declaring the function.
    ///
    /// A `T.f` handed to a call is spelled exactly as another type's static property or enum case is handed on — `configure(Mode.fast)` — so it is the function's only on a type that declares it, or on `Self` inside one, as a call `Self.m(x)` is.
    func isListed(ownedBy owners: Set<String>) -> Bool {
        guard let type = unappliedOn else { return !nameOnly }
        return type == "Self" ? enclosingTypes.contains(where: owners.contains) : owners.contains(type)
    }

    /// Whether `other` is the same written call or attribute as this site, however either was since read as a call of which initializer.
    func isSamePlace(as other: SyntacticCallSite) -> Bool {
        path == other.path && line == other.line && calleeAt == other.calleeAt && isAttribute == other.isAttribute
    }

    /// The site with its receiver untyped where the receiver names one of `localTypes` or `values`, or the call is made on self inside one of `localTypes`, since the index records none of them; the types around it among `localTypes` are recorded as local.
    func untyped(namingAnyOf localTypes: Set<String>, orValues values: Set<String> = []) -> SyntacticCallSite {
        var site = self
        site.localEnclosingTypes = Set(enclosingTypes.filter(localTypes.contains))
        // A qualifier headed by a name declared inside a function names nothing the index holds.
        if let head = qualifier?.split(separator: ".").first, localTypes.contains(String(head)) {
            site.qualifiedByGenericParameter = true
        }
        switch receiver {
        case .enclosingSelf where enclosingTypes.contains(where: localTypes.contains):
            break
        case let .type(name, _, _) where localTypes.contains(name) || values.contains(name):
            break
        default:
            return site
        }
        // Copied rather than rebuilt, so nothing but the receiver changes.
        site.receiver = nil
        return site
    }

    /// The site as a call of a property wrapper's `init(projectedValue:)`, made by a `$label:` argument it passes to one of `projection`'s parameters.
    func projecting(_ projection: ProjectedCall) -> SyntacticCallSite {
        var projected = SyntacticCallSite(
            path: path,
            line: line,
            enclosing: enclosing,
            enclosingTypes: enclosingTypes,
            enclosingConstraints: enclosingConstraints,
            arguments: WrittenArguments(labels: ["projectedValue"]),
            projection: projection,
            calleeAt: calleeAt
        )
        projected.text = text
        projected.localEnclosingTypes = localEnclosingTypes
        return projected
    }

    /// The site with the text of its line among `sourceLines`, the file's lines in order, as the block prints it.
    func reading(_ sourceLines: [String]) -> SyntacticCallSite {
        var read = self
        read.text = sourceLines.indices.contains(line - 1) ? NameMatchedSites.sourceText(sourceLines[line - 1]) : nil
        return read
    }
}
