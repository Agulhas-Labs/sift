//
// Copyright © Agulhas Labs
//

/// A catalog's parsed shape, as the two formats hold it — cheap to match against repeatedly, unlike the JSON or property-list bytes it was read from.
enum CatalogContent {
    case modern(sourceLanguage: String, strings: [String: Any])
    case legacy([String: String])
}
