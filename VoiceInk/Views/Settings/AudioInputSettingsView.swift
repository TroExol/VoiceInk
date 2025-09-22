import SwiftUI

struct AudioInputSettingsView: View {
    @ObservedObject var audioDeviceManager = AudioDeviceManager.shared
    @ObservedObject private var systemAudioService = SystemAudioCaptureService.shared
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                heroSection
                mainContent
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private var mainContent: some View {
        VStack(spacing: 40) {
            inputModeSection

            if audioDeviceManager.inputMode == .custom {
                customDeviceSection
            } else if audioDeviceManager.inputMode == .prioritized {
                prioritizedDevicesSection
            }

            systemAudioCaptureSection
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 40)
    }
    
    private var heroSection: some View {
        VStack(spacing: 24) {
            Image(systemName: "waveform")
                .font(.system(size: 40))
                .foregroundStyle(.blue)
                .padding(20)
                .background(Circle()
                    .fill(Color(.windowBackgroundColor).opacity(0.4))
                    .shadow(color: .black.opacity(0.1), radius: 10, y: 5))
            
            VStack(spacing: 8) {
                Text("Audio Input")
                    .font(.system(size: 28, weight: .bold))
                Text("Configure your microphone preferences")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }
    
    private var inputModeSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Input Mode")
                .font(.title2)
                .fontWeight(.semibold)
            
            HStack(spacing: 20) {
                ForEach(AudioInputMode.allCases, id: \.self) { mode in
                    InputModeCard(
                        mode: mode,
                        isSelected: audioDeviceManager.inputMode == mode,
                        action: { audioDeviceManager.selectInputMode(mode) }
                    )
                }
            }
        }
    }

    private var systemAudioCaptureSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("System Audio Capture")
                .font(.title2)
                .fontWeight(.semibold)

            Toggle(isOn: $systemAudioService.isCaptureEnabled) {
                Text("Record system audio (requires loopback device)")
            }
            .toggleStyle(.switch)

            if systemAudioService.isCaptureEnabled {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Loopback Device")
                            .font(.headline)

                        Spacer()

                        Button(action: systemAudioService.refreshDevices) {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                    }

                    if systemAudioService.availableDevices.isEmpty {
                        Text("No loopback devices detected. Install BlackHole or a similar virtual audio driver and press Refresh.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Picker("Loopback Device", selection: loopbackDeviceBinding) {
                            ForEach(systemAudioService.availableDevices, id: \.uid) { device in
                                Text(displayName(for: device)).tag(device.uid)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()

                        if let selected = selectedLoopbackDevice {
                            Text(formatDeviceDetails(selected))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recording Balance")
                            .font(.headline)

                        Slider(value: $systemAudioService.mixBalance, in: 0...1) {
                            Text("Recording Balance")
                        } minimumValueLabel: {
                            Text("Mic")
                        } maximumValueLabel: {
                            Text("System")
                        }

                        let micPercentage = Int((1 - systemAudioService.mixBalance) * 100)
                        let systemPercentage = Int(systemAudioService.mixBalance * 100)

                        Text("Mic \(micPercentage)% • System \(systemPercentage)%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Monitoring Volume During Capture")
                            .font(.headline)

                        Slider(value: $systemAudioService.playbackVolumeDuringCapture, in: 0...1) {
                            Text("Monitoring Volume During Capture")
                        } minimumValueLabel: {
                            Text("Mute")
                        } maximumValueLabel: {
                            Text("Full")
                        }

                        let playbackPercentage = Int(systemAudioService.playbackVolumeDuringCapture * 100)
                        Text("System output stays at \(playbackPercentage)% while recording")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            loopbackInstructions
        }
    }

    private var loopbackInstructions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Loopback driver setup")
                .font(.headline)

            Text("1. Install a loopback driver such as BlackHole or Loopback.")
                .font(.caption)
            Text("2. In Audio MIDI Setup, create a Multi-Output device that routes audio to your speakers and the loopback input.")
                .font(.caption)
            Text("3. Select the loopback device above and adjust the recording balance to match your needs.")
                .font(.caption)

            if let url = URL(string: "https://existential.audio/blackhole/") {
                Link("Download BlackHole", destination: url)
                    .font(.subheadline)
            }
        }
        .padding()
        .background(CardBackground(isSelected: false))
    }

    private var selectedLoopbackDevice: LoopbackDevice? {
        guard let uid = systemAudioService.selectedDeviceUID else { return nil }
        return systemAudioService.availableDevices.first { $0.uid == uid }
    }

    private var loopbackDeviceBinding: Binding<String> {
        Binding(
            get: { systemAudioService.selectedDeviceUID ?? "" },
            set: { newValue in
                systemAudioService.selectedDeviceUID = newValue.isEmpty ? nil : newValue
            }
        )
    }

    private func displayName(for device: LoopbackDevice) -> String {
        device.isRecommended ? "\(device.name) (Recommended)" : device.name
    }

    private func formatDeviceDetails(_ device: LoopbackDevice) -> String {
        let channelText = "\(device.channelCount) channel" + (device.channelCount == 1 ? "" : "s")
        let sampleRate = Int(device.sampleRate)
        return "\(channelText) • \(sampleRate) Hz"
    }
    
    private var customDeviceSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Available Devices")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Button(action: { audioDeviceManager.loadAvailableDevices() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            
            Text("Note: Selecting a device here will override your Mac\'s system-wide default microphone.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.bottom, 8)

            VStack(spacing: 12) {
                ForEach(audioDeviceManager.availableDevices, id: \.id) { device in
                    DeviceSelectionCard(
                        name: device.name,
                        isSelected: audioDeviceManager.selectedDeviceID == device.id,
                        isActive: audioDeviceManager.getCurrentDevice() == device.id
                    ) {
                        audioDeviceManager.selectDevice(id: device.id)
                    }
                }
            }
        }
    }
    
    private var prioritizedDevicesSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if audioDeviceManager.availableDevices.isEmpty {
                emptyDevicesState
            } else {
                prioritizedDevicesContent
                Divider().padding(.vertical, 8)
                availableDevicesContent
            }
        }
    }
    
    private var prioritizedDevicesContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Prioritized Devices")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Devices will be used in order of priority. If a device is unavailable, the next one will be tried. If no prioritized device is available, the system default microphone will be used.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Warning: Using a prioritized device will override your Mac\'s system-wide default microphone if it becomes active.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
            
            if audioDeviceManager.prioritizedDevices.isEmpty {
                Text("No prioritized devices")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                prioritizedDevicesList
            }
        }
    }
    
    private var availableDevicesContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Available Devices")
                .font(.title2)
                .fontWeight(.semibold)
            
            availableDevicesList
        }
    }
    
    private var emptyDevicesState: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.slash.circle.fill")
                .font(.system(size: 48))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            
            VStack(spacing: 8) {
                Text("No Audio Devices")
                    .font(.headline)
                Text("Connect an audio input device to get started")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .background(CardBackground(isSelected: false))
    }
    
    private var prioritizedDevicesList: some View {
        VStack(spacing: 12) {
            ForEach(audioDeviceManager.prioritizedDevices.sorted(by: { $0.priority < $1.priority })) { device in
                devicePriorityCard(for: device)
            }
        }
    }
    
    private func devicePriorityCard(for prioritizedDevice: PrioritizedDevice) -> some View {
        let device = audioDeviceManager.availableDevices.first(where: { $0.uid == prioritizedDevice.id })
        return DevicePriorityCard(
            name: prioritizedDevice.name,
            priority: prioritizedDevice.priority,
            isActive: device.map { audioDeviceManager.getCurrentDevice() == $0.id } ?? false,
            isPrioritized: true,
            isAvailable: device != nil,
            canMoveUp: prioritizedDevice.priority > 0,
            canMoveDown: prioritizedDevice.priority < audioDeviceManager.prioritizedDevices.count - 1,
            onTogglePriority: { audioDeviceManager.removePrioritizedDevice(id: prioritizedDevice.id) },
            onMoveUp: { moveDeviceUp(prioritizedDevice) },
            onMoveDown: { moveDeviceDown(prioritizedDevice) }
        )
    }
    
    private var availableDevicesList: some View {
        let unprioritizedDevices = audioDeviceManager.availableDevices.filter { device in
            !audioDeviceManager.prioritizedDevices.contains { $0.id == device.uid }
        }
        
        return Group {
            if unprioritizedDevices.isEmpty {
                Text("No additional devices available")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(unprioritizedDevices, id: \.id) { device in
                    DevicePriorityCard(
                        name: device.name,
                        priority: nil,
                        isActive: audioDeviceManager.getCurrentDevice() == device.id,
                        isPrioritized: false,
                        isAvailable: true,
                        canMoveUp: false,
                        canMoveDown: false,
                        onTogglePriority: { audioDeviceManager.addPrioritizedDevice(uid: device.uid, name: device.name) },
                        onMoveUp: {},
                        onMoveDown: {}
                    )
                }
            }
        }
    }
    
    private func moveDeviceUp(_ device: PrioritizedDevice) {
        guard device.priority > 0,
              let currentIndex = audioDeviceManager.prioritizedDevices.firstIndex(where: { $0.id == device.id })
        else { return }
        
        var devices = audioDeviceManager.prioritizedDevices
        devices.swapAt(currentIndex, currentIndex - 1)
        updatePriorities(devices)
    }
    
    private func moveDeviceDown(_ device: PrioritizedDevice) {
        guard device.priority < audioDeviceManager.prioritizedDevices.count - 1,
              let currentIndex = audioDeviceManager.prioritizedDevices.firstIndex(where: { $0.id == device.id })
        else { return }
        
        var devices = audioDeviceManager.prioritizedDevices
        devices.swapAt(currentIndex, currentIndex + 1)
        updatePriorities(devices)
    }
    
    private func updatePriorities(_ devices: [PrioritizedDevice]) {
        let updatedDevices = devices.enumerated().map { index, device in
            PrioritizedDevice(id: device.id, name: device.name, priority: index)
        }
        audioDeviceManager.updatePriorities(devices: updatedDevices)
    }
}

struct InputModeCard: View {
    let mode: AudioInputMode
    let isSelected: Bool
    let action: () -> Void
    
    private var icon: String {
        switch mode {
        case .systemDefault: return "macbook.and.iphone"
        case .custom: return "mic.circle.fill"
        case .prioritized: return "list.number"
        }
    }
    
    private var titleKey: LocalizedStringKey {
        LocalizedStringKey(mode.rawValue)
    }
    
    private var descriptionKey: LocalizedStringKey {
        switch mode {
        case .systemDefault: return "Use system's default input device"
        case .custom: return "Select a specific input device"
        case .prioritized: return "Set up device priority order"
        }
    }
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isSelected ? .blue : .secondary)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(titleKey)
                        .font(.headline)
                    
                    Text(descriptionKey)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(CardBackground(isSelected: isSelected))
        }
        .buttonStyle(.plain)
    }
}

struct DeviceSelectionCard: View {
    let name: String
    let isSelected: Bool
    let isActive: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .font(.system(size: 18))
                
                Text(name)
                    .foregroundStyle(.primary)
                
                Spacer()
                
                if isActive {
                    Label("Active", systemImage: "wave.3.right")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(.green.opacity(0.1))
                        )
                }
            }
            .padding()
            .background(CardBackground(isSelected: isSelected))
        }
        .buttonStyle(.plain)
    }
}

struct DevicePriorityCard: View {
    let name: String
    let priority: Int?
    let isActive: Bool
    let isPrioritized: Bool
    let isAvailable: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onTogglePriority: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    
    var body: some View {
        HStack {
            // Priority number or dash
            if let priority = priority {
                Text("\(priority + 1)")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
            } else {
                Text("-")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
            }
            
            // Device name
            Text(name)
                .foregroundStyle(isAvailable ? .primary : .secondary)
            
            Spacer()
            
            // Status and Controls
            HStack(spacing: 12) {
                // Active status
                if isActive {
                    Label("Active", systemImage: "wave.3.right")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(.green.opacity(0.1))
                        )
                } else if !isAvailable && isPrioritized {
                    Label("Unavailable", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color(.windowBackgroundColor).opacity(0.4))
                        )
                }
                
                // Priority controls (only show if prioritized)
                if isPrioritized {
                    HStack(spacing: 2) {
                        Button(action: onMoveUp) {
                            Image(systemName: "chevron.up")
                                .foregroundStyle(canMoveUp ? .blue : .secondary.opacity(0.5))
                        }
                        .disabled(!canMoveUp)
                        
                        Button(action: onMoveDown) {
                            Image(systemName: "chevron.down")
                                .foregroundStyle(canMoveDown ? .blue : .secondary.opacity(0.5))
                        }
                        .disabled(!canMoveDown)
                    }
                }
                
                // Toggle priority button
                Button(action: onTogglePriority) {
                    Image(systemName: isPrioritized ? "minus.circle.fill" : "plus.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isPrioritized ? .red : .blue)
                }
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(CardBackground(isSelected: false))
    }
} 
