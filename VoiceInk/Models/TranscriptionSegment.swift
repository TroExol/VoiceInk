import Foundation
import SwiftData

@Model
final class TranscriptionSegment {
    var id: UUID
    var speaker: String
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var speakerIndex: Int
    var isSpeakerDerived: Bool
    @Relationship(inverse: \Transcription.segments) var transcription: Transcription?

    init(speaker: String, start: TimeInterval, end: TimeInterval, text: String, speakerIndex: Int, isSpeakerDerived: Bool, transcription: Transcription? = nil) {
        self.id = UUID()
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
        self.speakerIndex = speakerIndex
        self.isSpeakerDerived = isSpeakerDerived
        self.transcription = transcription
    }
}
