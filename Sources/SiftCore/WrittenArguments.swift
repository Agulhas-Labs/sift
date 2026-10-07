//
// Copyright © Agulhas Labs
//

import SwiftSyntax

/// The argument labels a call is written with: what a call site says about which declarations it can reach.
///
/// Kept beside a name-matched site so the fallback can narrow a bare name by the parameters the question already fixed, without an index store.
struct WrittenArguments: Sendable, Equatable {
    /// Each parenthesised argument's label in order, `nil` for one written without a label.
    let labels: [String?]
    /// Whether an unlabeled trailing closure follows the parentheses.
    let hasTrailingClosure: Bool
    /// The labels of the trailing closures after the first, in order, `nil` for one labelled `_`.
    let trailingLabels: [String?]
    /// The labels a compound callee spells — every parameter's, `nil` for `_` — or `nil` when the callee is a bare name.
    let calleeLabels: [String?]?
    /// Whether the call may give an unapplied instance method its instance rather than its arguments, so its labels say nothing about the method's.
    let application: Application
    /// Other labels the first argument could carry instead — a property wrapper's parameter attribute, whose first label is `wrappedValue` where the caller passes the plain value but `projectedValue` or `initialValue` where an initializer declares one of those instead.
    let alternateFirstLabels: [String]

    init(
        labels: [String?],
        hasTrailingClosure: Bool = false,
        trailingLabels: [String?] = [],
        calleeLabels: [String?]? = nil,
        application: Application = .direct,
        alternateFirstLabels: [String] = []
    ) {
        self.labels = labels
        self.hasTrailingClosure = hasTrailingClosure
        self.trailingLabels = trailingLabels
        self.calleeLabels = calleeLabels
        self.application = application
        self.alternateFirstLabels = alternateFirstLabels
    }

    /// The arguments as a call expression writes them.
    init(of call: FunctionCallExprSyntax) {
        self.init(
            labels: call.arguments.map { $0.label.flatMap(Self.label) },
            hasTrailingClosure: call.trailingClosure != nil,
            trailingLabels: call.additionalTrailingClosures.map { Self.label($0.label) },
            calleeLabels: Self.compoundLabels(of: call.calledExpression),
            application: Self.application(of: call)
        )
    }

    /// A label as the name it stands for, backticks dropped, or `nil` for `_`.
    static func label(_ token: TokenSyntax) -> String? {
        let text = token.identifier?.name ?? token.text
        return text == "_" ? nil : text
    }

    private static func compoundLabels(of callee: ExprSyntax) -> [String?]? {
        if let generic = callee.as(GenericSpecializationExprSyntax.self) {
            return compoundLabels(of: generic.expression)
        }
        let names = callee.as(DeclReferenceExprSyntax.self)?.argumentNames
            ?? callee.as(MemberAccessExprSyntax.self)?.declName.argumentNames
        return names.map { $0.arguments.map { label($0.name) } }
    }

    /// Whether the call may be a method named on its type and given the instance it runs on, whose own arguments follow in a second call or not at all.
    ///
    /// Judged generously, since a "yes" only keeps a site: a call that is itself the callee of another call, and a call of one unlabeled argument on a member of a name spelled like a type.
    private static func application(of call: FunctionCallExprSyntax) -> Application {
        if let outer = call.parent?.as(FunctionCallExprSyntax.self), outer.calledExpression.id == call.id {
            return .mayBeUnapplied
        }
        guard call.arguments.count == 1, call.arguments.first?.label == nil, call.trailingClosure == nil,
              let base = call.calledExpression.as(MemberAccessExprSyntax.self)?.base
        else { return .direct }
        if base.as(DeclReferenceExprSyntax.self)?.baseName.tokenKind == .keyword(.Self) {
            return .mayBeUnappliedOnSelf
        }
        return couldBeType(base) ? .mayBeUnapplied : .direct
    }

    /// Whether an expression could name a type: a generic specialization, a `type(of:)` call, a `.self` member, a parenthesised expression, or a name or a member whose name starts with a capital letter.
    ///
    /// A metatype held in a lowercase name — a variable or a typealias — is spelled like any value and is not seen.
    private static func couldBeType(_ expression: ExprSyntax) -> Bool {
        if expression.is(GenericSpecializationExprSyntax.self) || expression.is(TupleExprSyntax.self) {
            return true
        }
        if let call = expression.as(FunctionCallExprSyntax.self), call.arguments.first?.label?.text == "of",
           CalleeName.base(of: call.calledExpression) == "type"
        {
            return true
        }
        if expression.as(MemberAccessExprSyntax.self)?.declName.baseName.tokenKind == .keyword(.self) {
            return true
        }
        let token = expression.as(DeclReferenceExprSyntax.self)?.baseName
            ?? expression.as(MemberAccessExprSyntax.self)?.declName.baseName
        guard let token else { return false }
        return (token.identifier?.name ?? token.text).first?.isUppercase == true
    }
}

extension WrittenArguments {
    /// The same arguments given straight to the declaration called, as an initializer's always are: it has no instance to be handed first.
    var appliedDirectly: WrittenArguments {
        WrittenArguments(labels: labels, hasTrailingClosure: hasTrailingClosure, trailingLabels: trailingLabels, calleeLabels: calleeLabels)
    }

    /// The same arguments with the first label replaced — one alternative a property-wrapper attribute's first label may spell instead.
    func withFirstLabel(_ label: String) -> WrittenArguments {
        guard !labels.isEmpty else { return self }
        var relabeled = labels
        relabeled[0] = label
        return WrittenArguments(labels: relabeled, hasTrailingClosure: hasTrailingClosure, trailingLabels: trailingLabels, calleeLabels: calleeLabels, application: application)
    }

    /// How a call's arguments reach the method it names.
    enum Application: Sendable, Equatable {
        /// The arguments are the method's own.
        case direct
        /// The argument may be the instance an unapplied method runs on: the callee of another call, or one unlabeled argument on a member of a name spelled like a type.
        case mayBeUnapplied
        /// One unlabeled argument on a member of `Self`, which may be the instance only inside a type that declares the method.
        case mayBeUnappliedOnSelf
    }
}
