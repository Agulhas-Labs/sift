import Foundation

struct ItemStore {
    static let all: [Item] = (0 ..< 8).map { index in
        Item(id: index, name: "Item \(index)")
    }
}
