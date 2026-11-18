import SwiftUI

/// Full-screen splash shown for a moment at launch, then faded out. The artwork is downloaded by
/// `scripts/fetch-brand-assets.sh` into the `Splash` image set, which has a light and a dark
/// variant, so the image follows the device appearance on its own. Without it the in-app logo is
/// shown on the system background.
///
/// The artwork is shown whole (`scaledToFit`) and inset from the screen edges. It used to be
/// `scaledToFill`, which blew it up past the screen and cropped the ship and the footer.
struct SplashView: View {
    /// Share of the screen width the artwork may occupy. Lower = smaller splash.
    private static let artworkWidthFraction: CGFloat = 0.72

    var body: some View {
        ZStack {
            // The splash artwork has a white backdrop, so the page behind it is white too; a
            // system (black in dark mode) background would show the image as a white box.
            Color.white.ignoresSafeArea()
            GeometryReader { proxy in
                let width = proxy.size.width * Self.artworkWidthFraction
                Group {
                    if UIImage(named: "Splash") != nil {
                        Image("Splash")
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image("Logo")
                            .resizable()
                            .scaledToFit()
                    }
                }
                .frame(width: width)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
