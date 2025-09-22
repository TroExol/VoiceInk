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
    private var previousVolumeLevel: Int?
    private let capturePreferences = SystemAudioCapturePreferences.shared
    
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

        if capturePreferences.isEnabled {
            let task = Task<Bool, Never> { [weak self] in
                guard let self = self else { return false }
                let currentVolume = self.getSystemVolume() ?? self.capturePreferences.captureVolumePercentage
                self.previousVolumeLevel = currentVolume
                self.wasAudioMutedBeforeRecording = false
                let targetVolume = self.capturePreferences.captureVolumePercentage
                if currentVolume == targetVolume {
                    self.didMuteAudio = true
                    return true
                }
                await self.fadeSystemVolume(from: currentVolume, to: targetVolume, duration: self.capturePreferences.fadeDuration)
                self.didMuteAudio = true
                return true
            }
            currentMuteTask = task
            return await task.value
        } else {
            let task = Task<Bool, Never> { [weak self] in
                guard let self = self else { return false }
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
    }

    /// Restores system audio after recording
    func unmuteSystemAudio() async {
        guard isSystemMuteEnabled else { return }

        // Wait for any pending mute operation to complete first
        if let muteTask = currentMuteTask {
            _ = await muteTask.value
        }

        if capturePreferences.isEnabled {
            if didMuteAudio, let previousVolume = previousVolumeLevel {
                let currentVolume = getSystemVolume() ?? previousVolume
                await fadeSystemVolume(from: currentVolume, to: previousVolume, duration: capturePreferences.fadeDuration)
            }
            previousVolumeLevel = nil
            didMuteAudio = false
            currentMuteTask = nil
            wasAudioMutedBeforeRecording = false
        } else {
            // Only unmute if we actually muted it (and it wasn't already muted)
            if didMuteAudio && !wasAudioMutedBeforeRecording {
                _ = executeAppleScript(command: "set volume without output muted")
            }

            didMuteAudio = false
            currentMuteTask = nil
        }
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

    private func fadeSystemVolume(from start: Int, to end: Int, duration: Double) async {
        let clampedStart = max(0, min(100, start))
        let clampedEnd = max(0, min(100, end))
        let duration = max(0.05, duration)
        let steps = max(1, Int(duration / 0.05))
        let stepDuration = duration / Double(steps)

        for step in 0...steps {
            if Task.isCancelled { return }
            let progress = Double(step) / Double(steps)
            let value = Int(round(Double(clampedStart) + (Double(clampedEnd - clampedStart) * progress)))
            _ = executeAppleScript(command: "set volume output volume \(value)")
            if step < steps {
                try? await Task.sleep(nanoseconds: UInt64(stepDuration * 1_000_000_000))
            }
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
