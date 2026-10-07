import SwiftUI

struct SecondTabView: View {
    @State private var tapCount = 0

    var body: some View {
        VStack(spacing: 16) {
            Text("Tapped \(tapCount) times")
                .accessibilityIdentifier("aboutCounter")
            Button("Tap me") {
                tapCount += 1
            }
            .accessibilityIdentifier("aboutTapButton")
        }
    }
}
