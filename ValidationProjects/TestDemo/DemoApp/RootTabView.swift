import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            NavigationStack {
                ItemListView()
            }
            .tabItem {
                Label("Items", systemImage: "list.bullet")
                    .accessibilityIdentifier("tab.items")
            }

            SecondTabView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                        .accessibilityIdentifier("tab.about")
                }
        }
    }
}
