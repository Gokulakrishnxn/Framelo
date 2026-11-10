import SwiftUI

/// Launch screen shown for three seconds while the library is prepared and interrupted recordings are recovered.
struct SplashView: View {
    @State private var appeared = false
    @State private var progress = 0.0

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            RadialGradient(colors: [Theme.accent.opacity(0.22), .clear], center: .center, startRadius: 10, endRadius: 420)
                .opacity(appeared ? 1 : 0)
                .ignoresSafeArea()

            VStack(spacing: Theme.l) {
                LogoMark(size: 92)
                    .shadow(color: Theme.accent.opacity(0.55), radius: appeared ? 34 : 0)
                    .scaleEffect(appeared ? 1 : 0.72)
                    .opacity(appeared ? 1 : 0)

                VStack(spacing: 6) {
                    Text("Framelo")
                        .font(.system(size: 38, weight: .semibold))
                        .kerning(-0.5)
                        .foregroundStyle(Theme.text)
                    Text("Record. Polish. Share.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                }
                .offset(y: appeared ? 0 : 12)
                .opacity(appeared ? 1 : 0)

                Capsule()
                    .fill(Theme.control)
                    .frame(width: 180, height: 3)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.accent).frame(width: 180 * progress, height: 3)
                    }
                    .padding(.top, Theme.l)
                    .opacity(appeared ? 1 : 0)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.78)) { appeared = true }
            withAnimation(.easeInOut(duration: 2.8)) { progress = 1 }
        }
    }
}
