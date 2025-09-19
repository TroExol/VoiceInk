import SwiftUI

/// Legacy license management view removed; keeping placeholder to satisfy build references.
struct LicenseManagementView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("All features unlocked")
                .font(.title3)
                .foregroundStyle(.primary)
            Text("You now have full access to VoiceInk without subscription prompts.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(Color(.controlBackgroundColor))
    }
}
