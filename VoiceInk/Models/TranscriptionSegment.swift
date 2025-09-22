import Foundation
import SwiftData

@Model
final class TranscriptionSegment {
    var id: UUID
    var speaker: String?
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    @Relationship(inverse: \Transcription.segments)
    var transcription: Transcription?

    init(text: String, start: TimeInterval, end: TimeInterval, speaker: String? = nil, transcription: Transcription? = nil) {
        self.id = UUID()
        self.text = text
        self.start = start
        self.end = end
        self.speaker = speaker
        self.transcription = transcription
    }
}

extension TranscriptionSegment {
    var hasSpeaker: Bool {
        guard let speaker = speaker?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !speaker.isEmpty
    }
}
