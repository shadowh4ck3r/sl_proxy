import SwiftUI

/// Full-screen splash shown for a moment at launch, then faded out. The artwork is downloaded by
/// `scripts/fetch-brand-assets.sh` into the `Splash` image set; without it the in-app logo is used.
struct SplashView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if UIImage(named: "Splash") != nil {
                Image("Splash")
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
            } else {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220)
            }
        }
    }
}
