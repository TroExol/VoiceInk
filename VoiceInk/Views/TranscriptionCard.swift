import SwiftUI
import SwiftData

struct TranscriptionCard: View {
    let transcription: Transcription
    let isExpanded: Bool
    let isSelected: Bool
    let onDelete: () -> Void
    let onToggleSelection: () -> Void
    @State private var isAIRequestExpanded: Bool = false
    @State private var selectedSpeakerKey: String? = nil
    @State private var speakerSearch: String = ""
    
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
                
                if hasSegments {
                    segmentContent
                } else {
                    originalTextContent
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
            .onChange(of: transcription.segments.count) { _, _ in
                if let selected = selectedSpeakerKey, !speakerOrder.contains(selected) {
                    selectedSpeakerKey = nil
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
    
    private static let unknownSpeakerKey = "__unknown__"

    private var hasSegments: Bool {
        !transcription.segments.isEmpty
    }

    private var sortedSegments: [TranscriptionSegment] {
        transcription.segments.sorted { $0.start < $1.start }
    }

    private var speakerOrder: [String] {
        var order: [String] = []
        for segment in sortedSegments {
            let key = speakerKey(for: segment)
            if !order.contains(key) {
                order.append(key)
            }
        }
        return order
    }

    private var speakerPalette: [Color] {
        [
            Color(red: 0.24, green: 0.48, blue: 0.87),
            Color(red: 0.85, green: 0.33, blue: 0.31),
            Color(red: 0.37, green: 0.74, blue: 0.37),
            Color(red: 0.87, green: 0.59, blue: 0.14),
            Color(red: 0.55, green: 0.36, blue: 0.74),
            Color(red: 0.19, green: 0.62, blue: 0.74)
        ]
    }

    private var filteredSegments: [TranscriptionSegment] {
        let query = speakerSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return sortedSegments.filter { segment in
            let key = speakerKey(for: segment)
            let matchesSpeaker = selectedSpeakerKey == nil || selectedSpeakerKey == key
            let matchesSearch = query.isEmpty || segment.text.localizedCaseInsensitiveContains(query)
            return matchesSpeaker && matchesSearch
        }
    }

    private var segmentsForDisplay: [TranscriptionSegment] {
        if isExpanded {
            return filteredSegments
        }
        return Array(filteredSegments.prefix(2))
    }

    private var hasAdditionalSegments: Bool {
        !isExpanded && filteredSegments.count > segmentsForDisplay.count
    }

    private var segmentContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isExpanded {
                speakerFilterControls
            }

            if segmentsForDisplay.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "speakerDiarization.noSegmentsForFilter"))
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Button(String(localized: "speakerDiarization.resetFilter")) {
                        selectedSpeakerKey = nil
                        speakerSearch = ""
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 13, weight: .medium))
                }
            } else {
                ForEach(segmentsForDisplay) { segment in
                    segmentRow(for: segment)
                }
            }

            if hasAdditionalSegments {
                Text(String(localized: "speakerDiarization.moreSegments"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }

            if isExpanded {
                Divider()
                    .padding(.vertical, 6)
                originalTextCopyRow
            }
        }
    }

    private var originalTextContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(transcription.text)
                .font(.system(size: 15, weight: .regular, design: .default))
                .lineLimit(isExpanded ? nil : 2)
                .lineSpacing(2)

            if isExpanded {
                originalTextCopyRow
            }
        }
    }

    private var originalTextCopyRow: some View {
        HStack {
            Text(String(localized: "Original"))
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
            Spacer()
            AnimatedCopyButton(textToCopy: transcription.text)
        }
    }

    private var speakerFilterControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Picker(String(localized: "speakerDiarization.filterLabel"), selection: $selectedSpeakerKey) {
                    Text(String(localized: "speakerDiarization.allSpeakers")).tag(String?.none)
                    ForEach(speakerOrder, id: \.self) { key in
                        Text(displayName(forKey: key)).tag(Optional(key))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                TextField(String(localized: "speakerDiarization.searchPlaceholder"), text: $speakerSearch)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(maxWidth: 220)

                Spacer()
            }
        }
    }

    private func segmentRow(for segment: TranscriptionSegment) -> some View {
        let key = speakerKey(for: segment)
        return HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(color(forKey: key).opacity(0.85))
                .frame(width: 10, height: 10)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(displayName(forKey: key))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(color(forKey: key))
                    Text(formatTimestampRange(start: segment.start, end: segment.end))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                    AnimatedCopyButton(textToCopy: segment.text)
                }

                Text(segment.text)
                    .font(.system(size: 15, weight: .regular, design: .default))
                    .lineSpacing(2)
                    .lineLimit(isExpanded ? nil : 2)
            }
        }
    }

    private func speakerKey(for segment: TranscriptionSegment) -> String {
        segment.speaker ?? Self.unknownSpeakerKey
    }

    private func displayName(forKey key: String) -> String {
        if key == Self.unknownSpeakerKey {
            return String(localized: "speakerDiarization.unknownSpeaker")
        }
        if let index = speakerOrder.firstIndex(of: key) {
            let template = String(localized: "speakerDiarization.speakerFormat")
            return String(format: template, index + 1)
        }
        return key
    }

    private func color(forKey key: String) -> Color {
        if let index = speakerOrder.firstIndex(of: key) {
            return speakerPalette[index % speakerPalette.count]
        }
        return speakerPalette.first ?? .accentColor
    }

    private func formatTimestampRange(start: TimeInterval, end: TimeInterval) -> String {
        "\(formatTimestamp(start)) – \(formatTimestamp(end))"
    }

    private func formatTimestamp(_ time: TimeInterval) -> String {
        let totalSeconds = max(0, Int(time.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var hasMetadata: Bool {
        transcription.transcriptionModelName != nil ||
        transcription.aiEnhancementModelName != nil ||
        transcription.promptName != nil ||
        transcription.transcriptionDuration != nil ||
        transcription.enhancementDuration != nil
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
}
