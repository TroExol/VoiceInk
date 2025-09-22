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
    private var captureVolumeTask: Task<Void, Never>?
    private var originalVolumeLevel: Int?
    private let captureFadeDuration: TimeInterval = 0.6

    @Published var isSystemMuteEnabled: Bool = UserDefaults.standard.bool(forKey: "isSystemMuteEnabled") {
        didSet {
            UserDefaults.standard.set(isSystemMuteEnabled, forKey: "isSystemMuteEnabled")
        }
    }

    @Published var captureVolumeLevel: Double = 0.5 {
        didSet {
            let clamped = min(max(captureVolumeLevel, 0), 1)
            if captureVolumeLevel != clamped {
                captureVolumeLevel = clamped
                return
            }
            UserDefaults.standard.systemCaptureVolume = clamped
        }
    }

    private init() {
        // Set default if not already set
        if !UserDefaults.standard.contains(key: "isSystemMuteEnabled") {
            UserDefaults.standard.set(true, forKey: "isSystemMuteEnabled")
        }

        if !UserDefaults.standard.contains(key: UserDefaults.Keys.systemCaptureVolume) {
            UserDefaults.standard.systemCaptureVolume = 0.5
        }
        captureVolumeLevel = UserDefaults.standard.systemCaptureVolume
    }

    /// Checks if the system audio is currently muted using AppleScript
    private func isSystemAudioMuted() -> Bool {
        guard let result = runAppleScript(command: "output muted of (get volume settings)") else { return false }
        return result.output?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// Mutes system audio during recording
    func muteSystemAudio() async -> Bool {
        guard isSystemMuteEnabled else { return false }

        // Cancel any existing mute task and create a new one
        currentMuteTask?.cancel()
        captureVolumeTask?.cancel()

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

        // Wait for any pending mute operation to complete first
        if let muteTask = currentMuteTask {
            _ = await muteTask.value
        }
        captureVolumeTask?.cancel()

        // Only unmute if we actually muted it (and it wasn't already muted)
        if didMuteAudio && !wasAudioMutedBeforeRecording {
            _ = executeAppleScript(command: "set volume without output muted")
        }

        didMuteAudio = false
        currentMuteTask = nil
    }

    func reduceVolumeForCapture() async {
        guard isSystemMuteEnabled else { return }

        captureVolumeTask?.cancel()
        let task = Task {
            let targetLevel = Int(round(captureVolumeLevel * 100))
            let clampedTarget = max(0, min(100, targetLevel))
            let currentLevel = getSystemVolumeLevel() ?? 100
            if originalVolumeLevel == nil {
                originalVolumeLevel = currentLevel
            }
            await fadeVolume(from: currentLevel, to: clampedTarget)
        }
        captureVolumeTask = task
        await task.value
        captureVolumeTask = nil
    }

    func restoreVolumeAfterCapture() async {
        guard isSystemMuteEnabled else { return }

        captureVolumeTask?.cancel()
        let task = Task {
            guard let originalVolumeLevel else { return }
            let currentLevel = getSystemVolumeLevel() ?? originalVolumeLevel
            await fadeVolume(from: currentLevel, to: originalVolumeLevel)
            self.originalVolumeLevel = nil
        }
        captureVolumeTask = task
        await task.value
        captureVolumeTask = nil
    }

    /// Executes an AppleScript command
    private func executeAppleScript(command: String) -> Bool {
        guard let result = runAppleScript(command: command) else { return false }
        return result.status == 0
    }

    private func runAppleScript(command: String) -> (output: String?, status: Int32)? {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", command]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (output, task.terminationStatus)
        } catch {
            return nil
        }
    }

    private func getSystemVolumeLevel() -> Int? {
        guard let result = runAppleScript(command: "output volume of (get volume settings)"), result.status == 0 else {
            return nil
        }
        guard let output = result.output, let level = Int(output) else { return nil }
        return level
    }

    private func setSystemVolume(level: Int) {
        let clamped = max(0, min(level, 100))
        _ = executeAppleScript(command: "set volume output volume \(clamped)")
    }

    private func fadeVolume(from start: Int, to end: Int) async {
        if start == end {
            setSystemVolume(level: end)
            return
        }

        let steps = max(1, Int(captureFadeDuration / 0.05))
        let interval = captureFadeDuration / Double(steps)

        for step in 1...steps {
            if Task.isCancelled { return }
            let progress = Double(step) / Double(steps)
            let level = Int(round(Double(start) + (Double(end - start) * progress)))
            setSystemVolume(level: level)
            if step < steps {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }

        setSystemVolume(level: end)
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
