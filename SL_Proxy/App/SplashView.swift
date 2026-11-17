import SwiftUI

/// Full-screen splash shown for a moment at launch, then faded out. The artwork is downloaded by
/// `scripts/fetch-brand-assets.sh` into the `Splash` image set, which has a light and a dark
/// variant, so the image follows the device appearance on its own. Without it the in-app logo is
/// shown on the system background.
struct SplashView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            if UIImage(named: "Splash") != nil {
                Image("Splash")
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
            } else {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 160)
            }
        }
    }
}
