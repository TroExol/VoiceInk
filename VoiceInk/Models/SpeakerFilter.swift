import Foundation

enum SpeakerFilter: Equatable, Identifiable {
    case all
    case named(String)
    case unknown

    var id: String {
        switch self {
        case .all:
            return "all"
        case .unknown:
            return "unknown"
        case .named(let value):
            return "named-\(value)"
        }
    }

    func matches(_ segment: TranscriptionSegment) -> Bool {
        switch self {
        case .all:
            return true
        case .unknown:
            return (segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        case .named(let value):
            return segment.speaker?.caseInsensitiveCompare(value) == .orderedSame
        }
    }

    func displayName(unknownLabel: String, allLabel: String) -> String {
        switch self {
        case .all:
            return allLabel
        case .unknown:
            return unknownLabel
        case .named(let value):
            return value
        }
    }
}
