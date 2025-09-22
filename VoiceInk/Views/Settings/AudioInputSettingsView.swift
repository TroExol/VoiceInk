import SwiftUI

struct AudioInputSettingsView: View {
    @ObservedObject var audioDeviceManager = AudioDeviceManager.shared
    @ObservedObject private var systemCaptureService = SystemAudioCaptureService.shared
    @ObservedObject private var mediaController = MediaController.shared
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(UserDefaults.Keys.systemAudioCaptureEnabled) private var isSystemAudioCaptureEnabled: Bool = UserDefaults.standard.isSystemAudioCaptureEnabled
    @AppStorage(UserDefaults.Keys.systemAudioLoopbackUID) private var selectedLoopbackUID: String = UserDefaults.standard.systemAudioLoopbackDeviceUID ?? ""
    @AppStorage(UserDefaults.Keys.systemAudioSystemLevel) private var systemAudioLevel: Double = UserDefaults.standard.systemAudioSystemLevel
    @AppStorage(UserDefaults.Keys.systemAudioMicrophoneLevel) private var microphoneAudioLevel: Double = UserDefaults.standard.systemAudioMicrophoneLevel
    @AppStorage(UserDefaults.Keys.systemAudioOutputFormat) private var systemOutputFormatRaw: String = UserDefaults.standard.systemAudioOutputFormat
    @AppStorage(UserDefaults.Keys.systemAudioChannelCount) private var systemChannelCount: Int = UserDefaults.standard.systemAudioChannelCount

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                heroSection
                mainContent
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear {
            systemCaptureService.refreshAvailableDevices()
        }
        .onChange(of: systemAudioLevel) { _, newValue in
            systemCaptureService.updateLevels(systemLevel: Float(newValue), microphoneLevel: Float(microphoneAudioLevel))
        }
        .onChange(of: microphoneAudioLevel) { _, newValue in
            systemCaptureService.updateLevels(systemLevel: Float(systemAudioLevel), microphoneLevel: Float(newValue))
        }
        .onChange(of: systemCaptureService.availableLoopbackDevices) { _, devices in
            if !devices.contains(where: { $0.uid == selectedLoopbackUID }) {
                selectedLoopbackUID = ""
            }
        }
    }

    private var systemOutputFormat: SystemAudioCaptureConfiguration.OutputFormat {
        get { SystemAudioCaptureConfiguration.OutputFormat(rawValue: systemOutputFormatRaw) ?? .stereo }
        set { systemOutputFormatRaw = newValue.rawValue }
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

    private var systemAudioCaptureSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("settings.systemAudio.title")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("settings.systemAudio.description")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Toggle(isOn: $isSystemAudioCaptureEnabled) {
                Text("settings.systemAudio.toggle")
            }
            .toggleStyle(.switch)

            if isSystemAudioCaptureEnabled {
                Divider()

                deviceSelectionSection
                levelsSection
                volumeSection
                formatSection
                instructionsSection
            }
        }
        .padding(24)
        .background(CardBackground(isSelected: false))
        .animation(.default, value: isSystemAudioCaptureEnabled)
    }

    private var deviceSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("settings.systemAudio.device")
                    .font(.headline)
                Spacer()
                Button(action: { systemCaptureService.refreshAvailableDevices() }) {
                    Label("settings.systemAudio.refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(systemCaptureService.isCapturing)
            }

            Picker("settings.systemAudio.devicePlaceholder", selection: $selectedLoopbackUID) {
                Text("settings.systemAudio.deviceNone").tag("")
                ForEach(systemCaptureService.availableLoopbackDevices) { device in
                    let label = "\(device.name) — \(device.channelCount)ch"
                    Text(label).tag(device.uid)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 320)
            .disabled(systemCaptureService.availableLoopbackDevices.isEmpty || systemCaptureService.isCapturing)

            if systemCaptureService.availableLoopbackDevices.isEmpty {
                Text("settings.systemAudio.noDevice")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("settings.systemAudio.deviceHint")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if systemCaptureService.isCapturing {
                Text("settings.systemAudio.deviceLocked")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var levelsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("settings.systemAudio.balanceTitle")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("settings.systemAudio.systemLevel")
                    Spacer()
                    Text(String(format: "%.0f%%", systemAudioLevel * 100))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Slider(value: $systemAudioLevel, in: 0...1, step: 0.05)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("settings.systemAudio.microphoneLevel")
                    Spacer()
                    Text(String(format: "%.0f%%", microphoneAudioLevel * 100))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Slider(value: $microphoneAudioLevel, in: 0...1, step: 0.05)
            }

            Text("settings.systemAudio.balanceHelp")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("settings.systemAudio.volumeDuckTitle")
                    .font(.headline)
                Spacer()
                Text(String(format: "%.0f%%", mediaController.systemCaptureVolume))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Slider(value: $mediaController.systemCaptureVolume, in: 0...100, step: 1)
            Text("settings.systemAudio.volumeDuckHelp")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("settings.systemAudio.formatTitle")
                .font(.headline)

            Picker("settings.systemAudio.formatTitle", selection: Binding(
                get: { systemOutputFormat },
                set: { systemOutputFormat = $0 }
            )) {
                ForEach(SystemAudioCaptureConfiguration.OutputFormat.allCases) { format in
                    Text(format.localizedName).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .disabled(systemCaptureService.isCapturing)

            Stepper(value: $systemChannelCount, in: 1...16) {
                Text(String(format: String(localized: "settings.systemAudio.channelCount"), systemChannelCount))
            }
            .disabled(systemCaptureService.isCapturing)

            Text("settings.systemAudio.formatHelp")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("settings.systemAudio.instructionsTitle")
                .font(.headline)

            Text("settings.systemAudio.instructionsDescription")
                .font(.footnote)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Label("settings.systemAudio.stepInstall", systemImage: "1.circle")
                HStack(spacing: 16) {
                    Link("Loopback", destination: URL(string: "https://rogueamoeba.com/loopback/")!)
                    Link("BlackHole", destination: URL(string: "https://existential.audio/blackhole/")!)
                }
                .font(.footnote)

                Label("settings.systemAudio.stepCreateDevice", systemImage: "2.circle")
                Label("settings.systemAudio.stepRoute", systemImage: "3.circle")
                Label("settings.systemAudio.stepSelect", systemImage: "4.circle")
            }
            .font(.footnote)

            Text("settings.systemAudio.instructionsFooter")
                .font(.footnote)
                .foregroundStyle(.secondary)
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
