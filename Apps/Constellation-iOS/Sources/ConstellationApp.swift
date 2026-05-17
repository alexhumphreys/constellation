import SwiftUI

@main
struct ConstellationApp: App {
    @State private var context: AppContext?
    @State private var loadError: String?

    var body: some Scene {
        WindowGroup {
            Group {
                if let context {
                    RootView(context: context)
                        .preferredColorScheme(.dark)
                } else if let loadError {
                    LoadFailureView(message: loadError)
                } else {
                    ProgressView("opening sky…")
                        .task { await bootstrap() }
                }
            }
            .background(Theme.Sky.bg1.ignoresSafeArea())
        }
    }

    private func bootstrap() async {
        do {
            let ctx = try AppContext()
            try await ctx.seedIfEmpty()
            context = ctx
        } catch {
            loadError = String(describing: error)
        }
    }
}

private struct LoadFailureView: View {
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Text("Couldn't open the store.")
                .font(.title3)
            Text(message)
                .font(.footnote)
                .monospaced()
                .multilineTextAlignment(.center)
                .padding()
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Sky.bg1)
    }
}
