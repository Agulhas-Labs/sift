import SwiftUI

struct ItemDetailView: View {
    let item: Item

    var body: some View {
        VStack(spacing: 12) {
            Text(item.name)
                .font(.title)
                .accessibilityIdentifier("itemDetail.name")
            Text("Identifier \(item.id)")
                .accessibilityIdentifier("itemDetail.id")
        }
        .navigationTitle(item.name)
    }
}
