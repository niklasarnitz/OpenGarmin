import SwiftUI

/// Full-screen alert shown while the watch rings the phone, with one big button that stops the sound.
struct FindMyPhoneView: View {
    let alert: FindMyPhoneAlert
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Palette.blaze.opacity(0.25))
                    .frame(width: 220, height: 220)
                    .scaleEffect(pulse ? 1.15 : 0.85)
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 88, weight: .semibold))
                    .foregroundStyle(Palette.blaze)
                    .symbolEffect(.variableColor.iterative, options: .repeat(.continuous))
            }
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            VStack(spacing: 8) {
                Text("Here I am!")
                    .font(.screenTitle)
                Text("Your watch is looking for this phone.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            Button {
                alert.stop()
            } label: {
                Label("Stop", systemImage: "speaker.slash.fill")
                    .font(.title2.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.glassProminent)
            .tint(Palette.blaze)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvas)
        .onAppear { pulse = true }
    }
}
