import SwiftUI

struct ItemListView: View {
    let items: [Item] = ItemStore.all

    var body: some View {
        List(items) { item in
            NavigationLink(value: item) {
                Text(item.name)
                    .accessibilityIdentifier("itemRow.\(item.id)")
            }
        }
        .navigationTitle("Items")
        .navigationDestination(for: Item.self) { item in
            ItemDetailView(item: item)
        }
    }
}
