import Foundation
import SwiftData

@Model
final class TranscriptionSegment {
    @Attribute(.unique) var id: UUID
    var speaker: String?
    var start: TimeInterval
    var end: TimeInterval
    var text: String

    @Relationship var transcription: Transcription?

    init(speaker: String?, start: TimeInterval, end: TimeInterval, text: String, transcription: Transcription? = nil) {
        self.id = UUID()
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
        self.transcription = transcription
    }
}
