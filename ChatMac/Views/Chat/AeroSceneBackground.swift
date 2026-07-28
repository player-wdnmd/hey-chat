import SwiftUI

struct AeroSceneBackground: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                AeroTheme.mainBackground

                Image("AeroLandscape")
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .opacity(0.7)

                Image("AeroEarth")
                    .resizable()
                    .scaledToFit()
                    .frame(width: min(920, geometry.size.width * 0.76))
                    .opacity(0.2)
                    .offset(x: geometry.size.width * 0.18)

                LinearGradient(
                    colors: [Color.white.opacity(0.28), Color.white.opacity(0.48)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
