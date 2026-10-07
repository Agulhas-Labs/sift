//
// Copyright © Agulhas Labs
//

/// Types the standard library, Foundation, Dispatch and Swift Testing declare that carry no `subscript(dynamicMember:)`, so a member written on one is that type's own unless the tree gives it one.
///
/// A receiver whose type the tree does not declare is kept under a qualified query unless it is one of these: a framework type such as SwiftUI's `Binding` or Foundation's `AttributedString` may hand on any member of the type it wraps. The list is closed and only ever names types known to have no such subscript.
struct PlainFrameworkTypes {
    /// Whether `name`, a type the tree does not declare, is one of the framework types known to hand on no other type's members.
    static func contains(_ name: String) -> Bool {
        names.contains(name)
    }

    private static let names: Set<String> = [
        // Standard library.
        "Array", "Bool", "Character", "ClosedRange", "Dictionary", "Double", "Duration", "Float", "Int", "Range", "Result",
        "Set", "String", "Substring", "Task",
        // Foundation.
        "Bundle", "Calendar", "Data", "Date", "DateFormatter", "Decimal", "FileHandle", "FileManager", "JSONDecoder",
        "JSONEncoder", "Locale", "NSLock", "NSRegularExpression", "Pipe", "Process", "ProcessInfo", "Thread", "TimeZone",
        "URL", "URLComponents", "URLRequest", "URLSession", "UUID",
        // Dispatch.
        "DispatchGroup", "DispatchQueue", "DispatchSemaphore",
        // Swift Testing.
        "Issue",
    ]
}
