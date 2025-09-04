import SwiftUI

struct ContentView: View {
    @StateObject private var presenter = Presenter() // AppKit/SCKit engine

    var body: some View {
        VStack(spacing: 16) {
            Text("Share a portion of your screen in Teams")
                .font(.headline)

            Text("Click Start Selection, drag a rectangle, then share the “RegionMirror” window in Teams (Share → Window).")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Button("Start Selection") {
                presenter.startSelection()
            }
            .keyboardShortcut(.defaultAction)
        }
        .frame(width: 480, height: 200)
        .padding()
    }
}
