import SwiftUI
import SwiftData

struct TranscriptionCard: View {
    let transcription: Transcription
    let isExpanded: Bool
    let isSelected: Bool
    let speakerFilter: SpeakerFilter
    let onDelete: () -> Void
    let onToggleSelection: () -> Void
    @State private var isAIRequestExpanded: Bool = false
    private let speakerPalette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .brown]

    var body: some View {
        HStack(spacing: 12) {
            // Selection checkbox in macOS style
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { _ in onToggleSelection() }
            ))
            .toggleStyle(CircularCheckboxStyle())
            .labelsHidden()
            
            VStack(alignment: .leading, spacing: 8) {
                // Header with date and duration
                HStack {
                    Text(transcription.timestamp, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                        .font(.system(size: 14, weight: .medium, design: .default))
                        .foregroundColor(.secondary)
                    Spacer()
                    
                    Text(formatTiming(transcription.duration))
                        .font(.system(size: 14, weight: .medium, design: .default))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.1))
                        .foregroundColor(.blue)
                        .cornerRadius(6)
                }
                
                if shouldUseSegments {
                    segmentListSection
                } else {
                    originalTextSection
                }
                
                // Enhanced text section (only when expanded)
                if isExpanded, let enhancedText = transcription.enhancedText {
                    Divider()
                        .padding(.vertical, 8)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text(enhancedText)
                            .font(.system(size: 15, weight: .regular, design: .default))
                            .lineSpacing(2)
                        
                        HStack {
                            HStack(spacing: 4) {
                                Image(systemName: "sparkles")
                                    .foregroundColor(.blue)
                                Text("Enhanced")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.blue)
                            }
                            Spacer()
                            AnimatedCopyButton(textToCopy: enhancedText)
                        }
                    }
                }
                
                // NEW: AI Request payload (System + User messages) - folded by default
                if isExpanded, (transcription.aiRequestSystemMessage != nil || transcription.aiRequestUserMessage != nil) {
                    Divider()
                        .padding(.vertical, 8)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "paperplane.fill")
                                .foregroundColor(.purple)
                            Text("AI Request")
                                .fontWeight(.semibold)
                                .foregroundColor(.purple)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut) {
                                isAIRequestExpanded.toggle()
                            }
                        }

                        if isAIRequestExpanded {
                            VStack(alignment: .leading, spacing: 12) {
                                if let systemMsg = transcription.aiRequestSystemMessage, !systemMsg.isEmpty {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text("System Prompt")
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundColor(.secondary)
                                            Spacer()
                                            AnimatedCopyButton(textToCopy: systemMsg)
                                        }
                                        Text(systemMsg)
                                            .font(.system(size: 13, weight: .regular, design: .monospaced))
                                            .lineSpacing(2)
                                    }
                                }
                                
                                if let userMsg = transcription.aiRequestUserMessage, !userMsg.isEmpty {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text("User Message")
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundColor(.secondary)
                                            Spacer()
                                            AnimatedCopyButton(textToCopy: userMsg)
                                        }
                                        Text(userMsg)
                                            .font(.system(size: 13, weight: .regular, design: .monospaced))
                                            .lineSpacing(2)
                                    }
                                }
                            }
                        }
                    }
                }
                
                // Audio player (if available)
                if isExpanded, let urlString = transcription.audioFileURL,
                   let url = URL(string: urlString),
                   FileManager.default.fileExists(atPath: url.path) {
                    Divider()
                        .padding(.vertical, 8)
                    AudioPlayerView(url: url)
                }
                
                // Metadata section (when expanded)
                if isExpanded && hasMetadata {
                    Divider()
                        .padding(.vertical, 8)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        metadataRow(icon: "hourglass", labelKey: "Audio Duration", value: formatTiming(transcription.duration))
                        if let modelName = transcription.transcriptionModelName {
                            metadataRow(icon: "cpu.fill", labelKey: "Transcription Model", value: modelName)
                        }
                        if let aiModel = transcription.aiEnhancementModelName {
                            metadataRow(icon: "sparkles", labelKey: "Enhancement Model", value: aiModel)
                        }
                        if let promptName = transcription.promptName {
                            metadataRow(icon: "text.bubble.fill", labelKey: "Prompt Used", value: promptName)
                        }
                        if let duration = transcription.transcriptionDuration {
                            metadataRow(icon: "clock.fill", labelKey: "Transcription Time", value: formatTiming(duration))
                        }
                        if let duration = transcription.enhancementDuration {
                            metadataRow(icon: "clock.fill", labelKey: "Enhancement Time", value: formatTiming(duration))
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(CardBackground(isSelected: false))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 3, x: 0, y: 2)
        .contextMenu {
            if let enhancedText = transcription.enhancedText {
                Button {
                    let _ = ClipboardManager.copyToClipboard(enhancedText)
                } label: {
                    Label("Copy Enhanced", systemImage: "doc.on.doc")
                }
            }
            
            Button {
                let _ = ClipboardManager.copyToClipboard(transcription.text)
            } label: {
                Label("Copy Original", systemImage: "doc.on.doc")
            }
            
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var hasMetadata: Bool {
        transcription.transcriptionModelName != nil ||
        transcription.aiEnhancementModelName != nil ||
        transcription.promptName != nil ||
        transcription.transcriptionDuration != nil ||
        transcription.enhancementDuration != nil
    }

    private var shouldUseSegments: Bool {
        !transcription.segments.isEmpty
    }

    private var sortedSegments: [TranscriptionSegment] {
        transcription.segments.sorted { $0.start < $1.start }
    }

    private var filteredSegments: [TranscriptionSegment] {
        guard !sortedSegments.isEmpty else { return [] }
        switch speakerFilter {
        case .all:
            return sortedSegments
        case .unknown:
            return sortedSegments.filter { segment in
                segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            }
        case .named(let value):
            return sortedSegments.filter { segment in
                segment.speaker?.caseInsensitiveCompare(value) == .orderedSame
            }
        }
    }

    private var displaySegments: [TranscriptionSegment] {
        let segments = filteredSegments
        guard !isExpanded else { return segments }
        return Array(segments.prefix(3))
    }

    private var hasAdditionalSegments: Bool {
        !isExpanded && filteredSegments.count > displaySegments.count
    }

    private var combinedSegmentsText: String {
        filteredSegments.map { $0.text }.joined(separator: "\n")
    }

    private func formatTiming(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return String(format: "%.0fms", duration * 1000)
        }
        if duration < 60 {
            return String(format: "%.1fs", duration)
        }
        let minutes = Int(duration) / 60
        let seconds = duration.truncatingRemainder(dividingBy: 60)
        return String(format: "%dm %.0fs", minutes, seconds)
    }
    
    private func metadataRow(icon: String, labelKey: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 20, alignment: .center)
            
            Text(labelKey)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
        }
    }

    private var originalTextSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(transcription.text)
                .font(.system(size: 15, weight: .regular, design: .default))
                .lineLimit(isExpanded ? nil : 2)
                .lineSpacing(2)

            if isExpanded {
                HStack {
                    Text("Original")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    AnimatedCopyButton(textToCopy: transcription.text)
                }
            }
        }
    }

    @ViewBuilder
    private var segmentListSection: some View {
        if filteredSegments.isEmpty {
            Text(String(localized: "history.filter.speakers.empty", defaultValue: "No utterances for the selected speaker"))
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.vertical, 4)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(displaySegments, id: \.id) { segment in
                    segmentRow(for: segment)
                }

                if hasAdditionalSegments {
                    Text(String(localized: "history.filter.speakers.expand", defaultValue: "Expand to view all segments"))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding(.leading, 4)
                }

                if isExpanded {
                    Divider()
                        .padding(.vertical, 4)
                    HStack {
                        Text(String(localized: "history.segment.copyAll", defaultValue: "Copy combined text"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                        Spacer()
                        AnimatedCopyButton(textToCopy: combinedSegmentsText)
                    }
                }
            }
        }
    }

    private func segmentRow(for segment: TranscriptionSegment) -> some View {
        let baseColor = color(for: segment.speaker)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(speakerDisplayName(for: segment))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(baseColor)
                Spacer()
                Text(formatSegmentRange(start: segment.start, end: segment.end))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                AnimatedCopyButton(textToCopy: segment.text)
            }

            Text(segment.text)
                .font(.system(size: 15, weight: .regular, design: .default))
                .foregroundColor(.primary)
                .lineLimit(isExpanded ? nil : 3)
        }
        .padding(12)
        .background(baseColor.opacity(0.12))
        .cornerRadius(10)
    }

    private func color(for speaker: String?) -> Color {
        guard let name = speaker?.lowercased(), !name.isEmpty else {
            return Color.gray
        }
        let hash = abs(name.hashValue)
        return speakerPalette[hash % speakerPalette.count]
    }

    private func speakerDisplayName(for segment: TranscriptionSegment) -> String {
        let value = segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.isEmpty {
            return String(localized: "history.filter.speakers.unknown", defaultValue: "Unknown speaker")
        }
        return value
    }

    private func formatSegmentRange(start: TimeInterval, end: TimeInterval) -> String {
        "\(formatTimestamp(start)) – \(formatTimestamp(end))"
    }

    private func formatTimestamp(_ value: TimeInterval) -> String {
        let totalSeconds = max(0, Int(value.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
