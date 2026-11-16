import SwiftUI

/// Full-screen splash shown over the app for a moment at launch. The artwork is the `Splash`
/// image asset (downloaded by `scripts/fetch-splash.sh` at build time); without it the brand
/// gradient and logo are shown so the app never launches blank.
struct SplashView: View {
    var body: some View {
        ZStack {
            Color.black
            if UIImage(named: "Splash") != nil {
                Image("Splash")
                    .resizable()
                    .scaledToFill()
            } else {
                Brand.gradient.opacity(0.5)
                BrandLogo(height: 64)
            }
        }
        .ignoresSafeArea()
    }
}

/// Wrap the root view:  `SplashGate { ContentView() }`
struct SplashGate<Content: View>: View {
    @State private var showing = true
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            content
            if showing {
                SplashView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(1400))
            withAnimation(.easeOut(duration: 0.45)) { showing = false }
        }
    }
}
