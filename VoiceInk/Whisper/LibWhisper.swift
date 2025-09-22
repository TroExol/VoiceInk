import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(whisper)
import whisper
#else
#error("Unable to import whisper module. Please check your project configuration.")
#endif
import os

struct WhisperSegmentMetadata {
    let index: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let speakerId: String
    let speakerIndex: Int
    let isSpeakerDerived: Bool
}


// Meet Whisper C++ constraint: Don't access from more than one thread at a time.
actor WhisperContext {
    private var context: OpaquePointer?
    private var languageCString: [CChar]?
    private var prompt: String?
    private var promptCString: [CChar]?
    private var vadModelPath: String?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "WhisperContext")

    private init() {}

    init(context: OpaquePointer) {
        self.context = context
    }

    deinit {
        if let context = context {
            whisper_free(context)
        }
    }

    func fullTranscribe(samples: [Float]) -> Bool {
        guard let context = context else { return false }
        
        let maxThreads = max(1, min(8, cpuCount() - 2))
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        
        // Read language directly from UserDefaults
        let selectedLanguage = UserDefaults.standard.string(forKey: "SelectedLanguage") ?? "auto"
        if selectedLanguage != "auto" {
            languageCString = Array(selectedLanguage.utf8CString)
            params.language = languageCString?.withUnsafeBufferPointer { ptr in
                ptr.baseAddress
            }
        } else {
            languageCString = nil
            params.language = nil
        }
        
        if prompt != nil {
            promptCString = Array(prompt!.utf8CString)
            params.initial_prompt = promptCString?.withUnsafeBufferPointer { ptr in
                ptr.baseAddress
            }
        } else {
            promptCString = nil
            params.initial_prompt = nil
        }
        
        params.print_realtime = true
        params.print_progress = false
        params.print_timestamps = true
        params.print_special = false
        params.translate = false
        params.n_threads = Int32(maxThreads)
        params.offset_ms = 0
        params.no_context = true
        params.single_segment = false
        params.temperature = 0.2

        whisper_reset_timings(context)
        
        // Configure VAD if enabled by user and model is available
        let isVADEnabled = UserDefaults.standard.object(forKey: "IsVADEnabled") as? Bool ?? true
        if isVADEnabled, let vadModelPath = self.vadModelPath {
            params.vad = true
            params.vad_model_path = (vadModelPath as NSString).utf8String
            
            var vadParams = whisper_vad_default_params()
            vadParams.threshold = 0.50
            vadParams.min_speech_duration_ms = 250
            vadParams.min_silence_duration_ms = 100
            vadParams.max_speech_duration_s = Float.greatestFiniteMagnitude
            vadParams.speech_pad_ms = 30
            vadParams.samples_overlap = 0.1
            params.vad_params = vadParams
        } else {
            params.vad = false
        }
        
        var success = true
        samples.withUnsafeBufferPointer { samplesBuffer in
            if whisper_full(context, params, samplesBuffer.baseAddress, Int32(samplesBuffer.count)) != 0 {
                logger.error("Failed to run whisper_full. VAD enabled: \(params.vad)")
                success = false
            }
        }
        
        languageCString = nil
        promptCString = nil
        
        return success
    }

    func getTranscription() -> String {
        guard let context = context else { return "" }
        var transcription = ""
        for i in 0..<whisper_full_n_segments(context) {
            transcription += String(cString: whisper_full_get_segment_text(context, i))
        }
        return transcription
    }

    func getSegments() -> [WhisperSegmentMetadata] {
        guard let context = context else { return [] }
        let totalSegments = Int(whisper_full_n_segments(context))
        guard totalSegments > 0 else { return [] }

        var resolvedSpeakerMapping: [String: Int] = [:]
        var currentDerivedIndex = 0
        var segments: [WhisperSegmentMetadata] = []
        segments.reserveCapacity(totalSegments)

        for rawIndex in 0..<totalSegments {
            let segmentIndex = Int32(rawIndex)

            if rawIndex > 0 && whisper_full_get_segment_speaker_turn_next(context, Int32(rawIndex - 1)) {
                currentDerivedIndex += 1
            }

            let startTicks = whisper_full_get_segment_t0(context, segmentIndex)
            let endTicks = whisper_full_get_segment_t1(context, segmentIndex)
            let startTime = TimeInterval(startTicks) * 0.01
            let endTime = TimeInterval(endTicks) * 0.01
            let rawText = String(cString: whisper_full_get_segment_text(context, segmentIndex))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let resolvedSpeaker = WhisperContext.speakerLabelResolver.speakerLabel(
                for: context,
                segmentIndex: segmentIndex
            )?.trimmingCharacters(in: .whitespacesAndNewlines)

            let speakerId: String
            let speakerIndex: Int
            let isDerived: Bool

            if let resolvedSpeaker, !resolvedSpeaker.isEmpty {
                if let existingIndex = resolvedSpeakerMapping[resolvedSpeaker] {
                    speakerIndex = existingIndex
                } else {
                    let newIndex = resolvedSpeakerMapping.count
                    resolvedSpeakerMapping[resolvedSpeaker] = newIndex
                    speakerIndex = newIndex
                }
                speakerId = resolvedSpeaker
                isDerived = false
            } else {
                let assignedIndex = currentDerivedIndex
                speakerIndex = assignedIndex
                speakerId = WhisperContext.fallbackSpeakerLabel(for: assignedIndex)
                isDerived = true
            }

            let metadata = WhisperSegmentMetadata(
                index: rawIndex,
                startTime: startTime,
                endTime: endTime,
                text: rawText,
                speakerId: speakerId,
                speakerIndex: speakerIndex,
                isSpeakerDerived: isDerived
            )
            segments.append(metadata)
        }

        return segments
    }

    static func createContext(path: String) async throws -> WhisperContext {
        let whisperContext = WhisperContext()
        try await whisperContext.initializeModel(path: path)
        
        // Load VAD model from bundle resources
        let vadModelPath = await VADModelManager.shared.getModelPath()
        await whisperContext.setVADModelPath(vadModelPath)
        
        return whisperContext
    }
    
    private func initializeModel(path: String) throws {
        var params = whisper_context_default_params()
        #if targetEnvironment(simulator)
        params.use_gpu = false
        logger.info("Running on the simulator, using CPU")
        #else
        params.flash_attn = true // Enable flash attention for Metal
        logger.info("Flash attention enabled for Metal")
        #endif
        
        let context = whisper_init_from_file_with_params(path, params)
        if let context {
            self.context = context
        } else {
            logger.error("Couldn't load model at \(path)")
            throw WhisperStateError.modelLoadFailed
        }
    }
    
    private func setVADModelPath(_ path: String?) {
        self.vadModelPath = path
        if path != nil {
            logger.info("VAD model loaded from bundle resources")
        }
    }

    func releaseResources() {
        if let context = context {
            whisper_free(context)
            self.context = nil
        }
        languageCString = nil
    }

    func setPrompt(_ prompt: String?) {
        self.prompt = prompt
    }
}

fileprivate func cpuCount() -> Int {
    ProcessInfo.processInfo.processorCount
}

private extension WhisperContext {
    static func fallbackSpeakerLabel(for index: Int) -> String {
        "speaker_\(index + 1)"
    }

    static let speakerLabelResolver = WhisperSegmentSpeakerResolver()

    struct WhisperSegmentSpeakerResolver {
        private typealias WhisperSpeakerFunction = @convention(c) (OpaquePointer?, Int32) -> UnsafePointer<CChar>?

        private let functionPointer: WhisperSpeakerFunction?

        init() {
            #if canImport(Darwin)
            let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
            #else
            let defaultHandle: UnsafeMutableRawPointer? = nil
            #endif
            if let symbol = dlsym(defaultHandle, "whisper_full_get_segment_speaker") {
                functionPointer = unsafeBitCast(symbol, to: WhisperSpeakerFunction.self)
            } else {
                functionPointer = nil
            }
        }

        func speakerLabel(for context: OpaquePointer?, segmentIndex: Int32) -> String? {
            guard let functionPointer, let pointer = functionPointer(context, segmentIndex) else {
                return nil
            }
            return String(validatingUTF8: pointer)
        }
    }
}
