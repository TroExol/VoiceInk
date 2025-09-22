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
    private var volumeFadeTask: Task<Void, Never>?
    private var previousVolumeLevel: Int?
    private var didDuckAudioForCapture = false

    @Published var isSystemMuteEnabled: Bool = UserDefaults.standard.bool(forKey: "isSystemMuteEnabled") {
        didSet {
            UserDefaults.standard.set(isSystemMuteEnabled, forKey: "isSystemMuteEnabled")
        }
    }

    @Published var systemCaptureVolume: Double = UserDefaults.standard.systemCaptureVolume {
        didSet {
            UserDefaults.standard.systemCaptureVolume = systemCaptureVolume
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
            // First check if audio is already muted
            wasAudioMutedBeforeRecording = isSystemAudioMuted()
            
            // If already muted, no need to mute it again
            if wasAudioMutedBeforeRecording {
                return true
            }
            
            // Otherwise mute the audio
            let success = executeAppleScript(command: "set volume with output muted")
            didMuteAudio = success
            return success
        }
        
        currentMuteTask = task
        return await task.value
    }
    
    /// Restores system audio after recording
    func unmuteSystemAudio() async {
        guard isSystemMuteEnabled else { return }

        volumeFadeTask?.cancel()
        volumeFadeTask = nil
        didDuckAudioForCapture = false
        previousVolumeLevel = nil

        // Wait for any pending mute operation to complete first
        if let muteTask = currentMuteTask {
            _ = await muteTask.value
        }

        // Only unmute if we actually muted it (and it wasn't already muted)
        if didMuteAudio && !wasAudioMutedBeforeRecording {
            _ = executeAppleScript(command: "set volume without output muted")
        }

        didMuteAudio = false
        currentMuteTask = nil
    }

    func reduceSystemAudioForCapture(duration: TimeInterval = 0.4) async {
        guard isSystemMuteEnabled else { return }

        volumeFadeTask?.cancel()

        let targetVolume = clampVolume(Int(systemCaptureVolume.rounded()))
        guard let currentVolume = currentSystemOutputVolume() else { return }

        previousVolumeLevel = currentVolume

        if currentVolume <= targetVolume {
            didDuckAudioForCapture = false
            return
        }

        let steps = max(1, Int(duration / 0.05))
        let volumeDelta = Double(currentVolume - targetVolume)

        let task = Task { [weak self] in
            guard let self = self else { return }
            self.didDuckAudioForCapture = true
            for step in 1...steps {
                if Task.isCancelled { return }
                let value = Int(round(Double(currentVolume) - (Double(step) * volumeDelta / Double(steps))))
                self.setSystemVolume(value)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            self.setSystemVolume(targetVolume)
        }

        volumeFadeTask = task
        await task.value
        volumeFadeTask = nil
    }

    func restoreSystemAudioAfterCapture(duration: TimeInterval = 0.4) async {
        guard isSystemMuteEnabled else { return }

        volumeFadeTask?.cancel()

        guard didDuckAudioForCapture, let targetVolume = previousVolumeLevel else {
            didDuckAudioForCapture = false
            previousVolumeLevel = nil
            return
        }

        let clampedTarget = clampVolume(targetVolume)
        let currentVolume = currentSystemOutputVolume() ?? clampedTarget

        if currentVolume >= clampedTarget {
            setSystemVolume(clampedTarget)
            didDuckAudioForCapture = false
            previousVolumeLevel = nil
            return
        }

        let steps = max(1, Int(duration / 0.05))
        let volumeDelta = Double(clampedTarget - currentVolume)

        let task = Task { [weak self] in
            guard let self = self else { return }
            for step in 1...steps {
                if Task.isCancelled { return }
                let value = Int(round(Double(currentVolume) + (Double(step) * volumeDelta / Double(steps))))
                self.setSystemVolume(value)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            self.setSystemVolume(clampedTarget)
            self.didDuckAudioForCapture = false
        }

        volumeFadeTask = task
        await task.value
        previousVolumeLevel = nil
        volumeFadeTask = nil
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

    private func runAppleScript(_ command: String) -> String? {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", command]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private func currentSystemOutputVolume() -> Int? {
        guard let value = runAppleScript("output volume of (get volume settings)"),
              let volume = Int(value) else {
            return nil
        }
        return volume
    }

    private func setSystemVolume(_ volume: Int) {
        let clamped = clampVolume(volume)
        _ = executeAppleScript(command: "set volume output volume \(clamped)")
    }

    private func clampVolume(_ value: Int) -> Int {
        min(max(value, 0), 100)
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
