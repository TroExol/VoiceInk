import SwiftUI

struct SystemAudioCaptureSettingsView: View {
    @StateObject private var preferences = SystemAudioCapturePreferences.shared
    @ObservedObject private var loopbackManager = SystemAudioLoopbackManager.shared

    private var selectedLoopbackBinding: Binding<String> {
        Binding(
            get: { preferences.selectedLoopbackDeviceUID ?? "" },
            set: { newValue in
                preferences.selectedLoopbackDeviceUID = newValue.isEmpty ? nil : newValue
            }
        )
    }

    private var selectedDevice: LoopbackAudioDevice? {
        guard let uid = preferences.selectedLoopbackDeviceUID else { return nil }
        return loopbackManager.availableDevices.first { $0.uid == uid }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Toggle(isOn: $preferences.isEnabled) {
                Text("Capture system audio")
            }
            .toggleStyle(.switch)
            .localizedHelp("Mix system playback into VoiceInk recordings using a loopback or virtual audio device.")

            if preferences.isEnabled {
                loopbackDeviceSection
                formatSection
                balanceSection
                systemVolumeSection
                instructionsSection
            }
        }
        .animation(.easeInOut, value: preferences.isEnabled)
        .onAppear { loopbackManager.loadDevices() }
    }

    private var loopbackDeviceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Loopback device")
                    .font(.headline)
                Spacer()
                Button(action: { loopbackManager.loadDevices() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }

            if loopbackManager.availableDevices.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No compatible loopback devices detected.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("Install a virtual audio device like BlackHole or Loopback, then return to this screen and refresh.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                Picker("Loopback device", selection: selectedLoopbackBinding) {
                    Text("Automatic (use current output)").tag("")
                    ForEach(loopbackManager.availableDevices) { device in
                        Text(device.displayName).tag(device.uid)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 320)

                if let device = selectedDevice {
                    Text("Channels: \(device.channelCount)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recording format")
                .font(.headline)

            Picker("Output format", selection: $preferences.outputMode) {
                ForEach(SystemAudioCapturePreferences.OutputMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)

            if preferences.outputMode == .multichannel {
                HStack {
                    Text("Channel count")
                    Spacer()
                    Stepper(value: $preferences.multichannelCount, in: 2...8) {
                        Text("\(preferences.multichannelCount)")
                            .frame(width: 30)
                    }
                    .frame(width: 140)
                }
            }
        }
    }

    private var balanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recording mix")
                .font(.headline)

            sliderRow(
                title: "Microphone level",
                value: $preferences.microphoneLevel,
                help: "Adjust how prominent the microphone should be in the final mix."
            )

            sliderRow(
                title: "System audio level",
                value: $preferences.systemLevel,
                help: "Adjust the level of the captured system audio relative to the microphone."
            )
        }
    }

    private var systemVolumeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Live monitoring")
                .font(.headline)

            sliderRow(
                title: "System volume during capture",
                value: $preferences.captureVolume,
                help: "VoiceInk can automatically adjust the Mac's output volume to avoid feedback while still letting you hear playback.",
                format: { "\(Int($0 * 100))%" }
            )

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fade duration")
                    Text("Smoothly ramp the system volume when recording starts or ends.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Slider(value: $preferences.fadeDuration, in: 0.1...2.0, step: 0.05)
                    .frame(width: 180)
                Text(String(format: "%.1fs", preferences.fadeDuration))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var instructionsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Install a loopback driver", systemImage: "info.circle")
                    .font(.headline)

                Text("VoiceInk relies on a virtual audio device (loopback) to capture system playback. If you haven't installed one yet, follow the steps below:")
                    .font(.footnote)

                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Download and install a loopback driver:")
                    Link("BlackHole (free)", destination: URL(string: "https://existential.audio/blackhole/")!)
                    Link("Loopback (paid)", destination: URL(string: "https://rogueamoeba.com/loopback/")!)
                }
                .font(.footnote)

                Text("2. Restart any apps that should be captured, then select the virtual device above.")
                    .font(.footnote)

                Text("3. Set the virtual device as the output inside the media app (or in macOS sound settings) so that VoiceInk can hear it.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sliderRow(title: String, value: Binding<Double>, help: String, format: ((Double) -> String)? = nil) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(help)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Slider(value: value, in: 0...1)
                .frame(width: 180)
            Text(format?(value.wrappedValue) ?? String(format: "%.0f%%", value.wrappedValue * 100))
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }
}
