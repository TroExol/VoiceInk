import AppKit
import Combine
import Foundation
import SwiftUI
import CoreAudio

/// Controls system audio management during recording
class MediaController: ObservableObject {
    static let shared = MediaController()
    private var didMuteAudio = false
    private var wasAudioMutedBeforeRecording = false
    private var currentMuteTask: Task<Bool, Never>?
    private var systemVolumeBeforeRecording: Int?
    private var didAdjustVolumeForCapture = false
    private let systemAudioService = SystemAudioCaptureService.shared
    
    @Published var isSystemMuteEnabled: Bool = UserDefaults.standard.bool(forKey: "isSystemMuteEnabled") {
        didSet {
            UserDefaults.standard.set(isSystemMuteEnabled, forKey: "isSystemMuteEnabled")
        }
    }
    
    private init() {
        // Set default if not already set
        if !UserDefaults.standard.contains(key: "isSystemMuteEnabled") {
            UserDefaults.standard.set(true, forKey: "isSystemMuteEnabled")
        }
    }
    
    /// Checks if the system audio is currently muted using AppleScript
    private func isSystemAudioMuted() -> Bool {
        let pipe = Pipe()
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", "output muted of (get volume settings)"]
        task.standardOutput = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                return output == "true"
            }
        } catch {
            // Silently fail
        }
        
        return false
    }
    
    /// Mutes system audio during recording
    func muteSystemAudio() async -> Bool {
        guard isSystemMuteEnabled else { return false }

        // Cancel any existing mute task and create a new one
        currentMuteTask?.cancel()

        let task = Task<Bool, Never> {
            if self.systemAudioService.isCaptureEnabled {
                return await self.reduceSystemVolumeForCapture()
            }

            // First check if audio is already muted
            self.wasAudioMutedBeforeRecording = self.isSystemAudioMuted()

            // If already muted, no need to mute it again
            if self.wasAudioMutedBeforeRecording {
                return true
            }

            // Otherwise mute the audio
            let success = self.executeAppleScript(command: "set volume with output muted")
            self.didMuteAudio = success
            return success
        }

        currentMuteTask = task
        return await task.value
    }

    /// Restores system audio after recording
    func unmuteSystemAudio() async {
        guard isSystemMuteEnabled else { return }
        
        // Wait for any pending mute operation to complete first
        if let muteTask = currentMuteTask {
            _ = await muteTask.value
        }

        if systemAudioService.isCaptureEnabled {
            await restoreSystemVolumeAfterCapture()
            currentMuteTask = nil
            return
        }

        // Only unmute if we actually muted it (and it wasn't already muted)
        if didMuteAudio && !wasAudioMutedBeforeRecording {
            _ = executeAppleScript(command: "set volume without output muted")
        }

        didMuteAudio = false
        currentMuteTask = nil
    }

    private func reduceSystemVolumeForCapture() async -> Bool {
        guard let currentVolume = getSystemVolume() else { return false }

        systemVolumeBeforeRecording = currentVolume
        let targetVolume = systemAudioService.playbackVolumeValue

        if targetVolume >= currentVolume {
            didAdjustVolumeForCapture = false
            return true
        }

        await fadeSystemVolume(from: currentVolume, to: targetVolume)
        didAdjustVolumeForCapture = true
        return true
    }

    private func restoreSystemVolumeAfterCapture() async {
        guard let originalVolume = systemVolumeBeforeRecording else {
            didAdjustVolumeForCapture = false
            return
        }

        let currentVolume = getSystemVolume() ?? originalVolume

        if didAdjustVolumeForCapture {
            await fadeSystemVolume(from: currentVolume, to: originalVolume)
        }

        didAdjustVolumeForCapture = false
        systemVolumeBeforeRecording = nil
    }

    private func fadeSystemVolume(from start: Int, to end: Int, duration: TimeInterval = 0.35) async {
        guard start != end else { return }

        let steps = max(1, Int(duration / 0.05))
        let stepDuration = duration / Double(steps)

        for step in 1...steps {
            if Task.isCancelled { return }

            let progress = Double(step) / Double(steps)
            let value = Int(round(Double(start) + (Double(end - start) * progress)))
            _ = setSystemVolume(value)

            if stepDuration > 0 {
                try? await Task.sleep(nanoseconds: UInt64(stepDuration * 1_000_000_000))
            }
        }

        _ = setSystemVolume(end)
    }

    private func getSystemVolume() -> Int? {
        let pipe = Pipe()
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", "output volume of (get volume settings)"]
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let value = Int(output) {
                return value
            }
        } catch {
            return nil
        }

        return nil
    }

    private func setSystemVolume(_ value: Int) -> Bool {
        let clamped = max(0, min(100, value))
        return executeAppleScript(command: "set volume output volume \(clamped)")
    }

    /// Executes an AppleScript command
    private func executeAppleScript(command: String) -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", command]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
}

extension UserDefaults {
    func contains(key: String) -> Bool {
        return object(forKey: key) != nil
    }
    
    var isSystemMuteEnabled: Bool {
        get { bool(forKey: "isSystemMuteEnabled") }
        set { set(newValue, forKey: "isSystemMuteEnabled") }
    }
}
