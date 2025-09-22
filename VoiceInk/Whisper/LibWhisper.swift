import Foundation
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
import Darwin
#endif
#if canImport(whisper)
import whisper
#else
#error("Unable to import whisper module. Please check your project configuration.")
#endif
import os


struct WhisperTranscriptionSegment: Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let speakerIdentifier: String?
    let hasSpeakerTurnNext: Bool
}


// Meet Whisper C++ constraint: Don't access from more than one thread at a time.
actor WhisperContext {
    private var context: OpaquePointer?
    private var languageCString: [CChar]?
    private var prompt: String?
    private var promptCString: [CChar]?
    private var vadModelPathCString: [CChar]?
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
        let shouldEnableTinydiarize = UserDefaults.standard.bool(forKey: SpeakerDiarizationDefaults.tinydiarizeEnabledKey)
        params.tdrz_enable = shouldEnableTinydiarize

        whisper_reset_timings(context)
        
        // Configure VAD if enabled by user and model is available
        let isVADEnabled = UserDefaults.standard.object(forKey: "IsVADEnabled") as? Bool ?? true
        if isVADEnabled, let vadModelPath = self.vadModelPath {
            params.vad = true
            vadModelPathCString = Array(vadModelPath.utf8CString)
            if let pointer: UnsafePointer<CChar> = vadModelPathCString?.withUnsafeBufferPointer({ $0.baseAddress }) {
                params.vad_model_path = pointer

                var vadParams = whisper_vad_default_params()
                vadParams.threshold = 0.50
                vadParams.min_speech_duration_ms = 250
                vadParams.min_silence_duration_ms = 100
                vadParams.max_speech_duration_s = Float.greatestFiniteMagnitude
                vadParams.speech_pad_ms = 30
                vadParams.samples_overlap = 0.1
                params.vad_params = vadParams
            } else {
                logger.error("Unable to prepare VAD model pointer for path \(vadModelPath). Disabling VAD for this session.")
                params.vad = false
                params.vad_model_path = nil
                vadModelPathCString = nil
            }
        } else {
            params.vad = false
            vadModelPathCString = nil
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

    func getSegments() -> [WhisperTranscriptionSegment] {
        guard let context = context else { return [] }

        let segmentCount = Int(whisper_full_n_segments(context))
        guard segmentCount > 0 else { return [] }

        var segments: [WhisperTranscriptionSegment] = []
        segments.reserveCapacity(segmentCount)

        for index in 0..<segmentCount {
            let rawText = whisper_full_get_segment_text(context, Int32(index))
            let text = String(cString: rawText).trimmingCharacters(in: .whitespacesAndNewlines)
            let startValue = whisper_full_get_segment_t0(context, Int32(index))
            let endValue = whisper_full_get_segment_t1(context, Int32(index))
            let start = TimeInterval(Double(startValue) / 100.0)
            let end = TimeInterval(Double(endValue) / 100.0)

            var speakerIdentifier: String?
            if let speakerFunction = WhisperContext.segmentSpeakerFunction,
               let pointer = speakerFunction(context, Int32(index)) {
                let value = String(cString: pointer)
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   value.lowercased() != "unknown" {
                    speakerIdentifier = value
                }
            }

            let hasTurn = whisper_full_get_segment_speaker_turn_next(context, Int32(index))

            let segment = WhisperTranscriptionSegment(
                text: text,
                start: start,
                end: end,
                speakerIdentifier: speakerIdentifier,
                hasSpeakerTurnNext: hasTurn
            )
            segments.append(segment)
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

private extension WhisperContext {
    typealias WhisperSegmentSpeakerFunction = @convention(c) (OpaquePointer?, Int32) -> UnsafePointer<CChar>?

    static let segmentSpeakerFunction: WhisperSegmentSpeakerFunction? = {
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
        guard let symbol = dlsym(handle, "whisper_full_get_segment_speaker") else { return nil }
        return unsafeBitCast(symbol, to: WhisperSegmentSpeakerFunction.self)
        #else
        return nil
        #endif
    }()
}

fileprivate func cpuCount() -> Int {
    ProcessInfo.processInfo.processorCount
}
