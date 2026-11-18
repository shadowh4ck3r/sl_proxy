import SwiftUI

/// Full-screen splash shown for a moment at launch, then faded out. The artwork is downloaded by
/// `scripts/fetch-brand-assets.sh` into the `Splash` image set, which has a light and a dark
/// variant, so the image follows the device appearance on its own. Without it the in-app logo is
/// shown on the system background.
struct SplashView: View {
    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            GeometryReader { proxy in
                let width = proxy.size.width * 0.72
                Group {
                    if UIImage(named: "Splash") != nil {
                        Image("Splash").resizable().scaledToFit()
                    } else {
                        Image("Logo").resizable().scaledToFit()
                    }
                }
                .frame(width: width)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
