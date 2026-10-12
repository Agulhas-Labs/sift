//
// Copyright © Agulhas Labs
//

/// The closing hint of the repository overview: how to go one level deeper.
///
/// A module sharing its name with a type needs the trailing slash, because the bare name serves the type; one query finds them all.
struct OverviewModuleHints {
    let store: IndexStore

    func lines(for overview: [ModuleOverview]) throws -> [String] {
        var lines = ["digest <Module> lists one module's declarations; digest <Type> serves a type's shape"]
        let shadowed = try store.modulesNamedLikeTypes()
        for row in overview where shadowed.contains(row.module) {
            lines.append("digest \(row.module)/ lists module \(row.module); digest \(row.module) serves the type of that name")
        }
        return lines
    }
}
