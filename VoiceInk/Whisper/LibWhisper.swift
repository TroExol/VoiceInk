import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(whisper)
import whisper
#else
#error("Unable to import whisper module. Please check your project configuration.")
#endif
import os

struct WhisperSegment {
    let index: Int
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let speaker: String?

    init(index: Int, text: String, start: TimeInterval, end: TimeInterval, speaker: String?) {
        self.index = index
        self.text = text
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

private typealias WhisperSegmentSpeakerFunction = @convention(c) (OpaquePointer?, Int32) -> UnsafePointer<CChar>?

#if canImport(Darwin)
private let whisperSegmentSpeakerFunction: WhisperSegmentSpeakerFunction? = {
    guard let symbol = dlsym(RTLD_DEFAULT, "whisper_full_get_segment_speaker") else {
        return nil
    }
    return unsafeBitCast(symbol, to: WhisperSegmentSpeakerFunction.self)
}()
#else
private let whisperSegmentSpeakerFunction: WhisperSegmentSpeakerFunction? = nil
#endif

private func convertWhisperTimestamp(_ value: Int64) -> TimeInterval {
    Double(value) / 100.0
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

    func getSegments() -> [WhisperSegment] {
        guard let context = context else { return [] }

        let numberOfSegments = Int(whisper_full_n_segments(context))
        var segments: [WhisperSegment] = []
        segments.reserveCapacity(numberOfSegments)

        for i in 0..<numberOfSegments {
            let index = Int32(i)
            let rawText = String(cString: whisper_full_get_segment_text(context, index))
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            let start = convertWhisperTimestamp(whisper_full_get_segment_t0(context, index))
            let end = convertWhisperTimestamp(whisper_full_get_segment_t1(context, index))
            let speaker = fetchSpeakerLabel(context: context, segmentIndex: index)

            guard !text.isEmpty else { continue }

            let segment = WhisperSegment(
                index: i,
                text: text,
                start: start,
                end: end,
                speaker: speaker
            )
            segments.append(segment)
        }

        return segments
    }

    private func fetchSpeakerLabel(context: OpaquePointer, segmentIndex: Int32) -> String? {
        guard let speakerFunction = whisperSegmentSpeakerFunction else {
            return nil
        }

        guard let pointer = speakerFunction(context, segmentIndex) else {
            return nil
        }

        guard let label = String(validatingUTF8: pointer), !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return label
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
