import SwiftUI

struct DictionaryItem: Identifiable, Hashable, Codable {
    let id: UUID
    var word: String
    var dateAdded: Date
    
    init(id: UUID = UUID(), word: String, dateAdded: Date = Date()) {
        self.id = id
        self.word = word
        self.dateAdded = dateAdded
    }
    
    // Legacy support for decoding old data with isEnabled property
    private enum CodingKeys: String, CodingKey {
        case id, word, dateAdded, isEnabled
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        word = try container.decode(String.self, forKey: .word)
        dateAdded = try container.decode(Date.self, forKey: .dateAdded)
        // Ignore isEnabled during decoding - all items are enabled by default now
        _ = try? container.decodeIfPresent(Bool.self, forKey: .isEnabled)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(word, forKey: .word)
        try container.encode(dateAdded, forKey: .dateAdded)
        // Don't encode isEnabled anymore
    }
}

class DictionaryManager: ObservableObject {
    @Published var items: [DictionaryItem] = []
    private let saveKey = "CustomDictionaryItems"
    private let whisperPrompt: WhisperPrompt

    enum UpdateError: Error {
        case empty
        case duplicate
    }

    init(whisperPrompt: WhisperPrompt) {
        self.whisperPrompt = whisperPrompt
        loadItems()
    }
    
    private func loadItems() {
        guard let data = UserDefaults.standard.data(forKey: saveKey) else { return }
        
        if let savedItems = try? JSONDecoder().decode([DictionaryItem].self, from: data) {
            items = savedItems.sorted(by: { $0.dateAdded > $1.dateAdded })
        }
    }
    
    private func saveItems() {
        if let encoded = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(encoded, forKey: saveKey)
        }
    }
    
    func addWord(_ word: String) {
        let normalizedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !items.contains(where: { $0.word.lowercased() == normalizedWord.lowercased() }) else {
            return
        }
        
        let newItem = DictionaryItem(word: normalizedWord)
        items.insert(newItem, at: 0)
        saveItems()
    }
    
    func removeWord(_ word: String) {
        items.removeAll(where: { $0.word == word })
        saveItems()
    }

    func updateWord(_ item: DictionaryItem, with newWord: String) throws {
        let normalizedWord = newWord.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedWord.isEmpty else {
            throw UpdateError.empty
        }

        let lowercasedWord = normalizedWord.lowercased()

        guard !items.contains(where: { $0.id != item.id && $0.word.lowercased() == lowercasedWord }) else {
            throw UpdateError.duplicate
        }

        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }

        if items[index].word == normalizedWord {
            return
        }

        items[index].word = normalizedWord
        saveItems()
    }

    var allWords: [String] {
        items.map { $0.word }
    }
}

struct DictionaryView: View {
    @StateObject private var dictionaryManager: DictionaryManager
    @ObservedObject var whisperPrompt: WhisperPrompt
    @State private var newWord = ""
    @State private var showAlert = false
    @State private var alertMessage = ""
    @EnvironmentObject private var languageManager: LanguageManager
    
    init(whisperPrompt: WhisperPrompt) {
        self.whisperPrompt = whisperPrompt
        _dictionaryManager = StateObject(wrappedValue: DictionaryManager(whisperPrompt: whisperPrompt))
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Information Section
            GroupBox {
                Label {
                    Text("Add words so AI enhancement understands them correctly. (Requires AI enhancement)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.blue)
                }
            }
            
            // Input Section
            HStack(spacing: 8) {
                TextField("Add word to dictionary", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .onSubmit { addWords() }
                
                Button(action: addWords) {
                    Image(systemName: "plus.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.blue)
                        .font(.system(size: 16, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .disabled(newWord.isEmpty)
                .localizedHelp("Add word")
            }
            
            // Words List
            if !dictionaryManager.items.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    let countText = languageManager.localizedString(
                        for: "Dictionary Items Count Format",
                        defaultValue: "Dictionary Items (%d)",
                        arguments: dictionaryManager.items.count
                    )
                    Text(countText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    ScrollView {
                        let columns = [
                            GridItem(.adaptive(minimum: 240, maximum: .infinity), spacing: 12)
                        ]
                        
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                            ForEach(dictionaryManager.items) { item in
                                DictionaryItemView(
                                    item: item,
                                    onDelete: {
                                        dictionaryManager.removeWord(item.word)
                                    },
                                    onUpdate: { updatedWord in
                                        do {
                                            try dictionaryManager.updateWord(item, with: updatedWord)
                                            return true
                                        } catch let error as DictionaryManager.UpdateError {
                                            handleUpdateError(error, attemptedWord: updatedWord)
                                            return false
                                        } catch {
                                            return false
                                        }
                                    }
                                )
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 200)
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .alert("Dictionary", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }
    
    private func addWords() {
        let input = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        let parts = input
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        guard !parts.isEmpty else { return }
        
        if parts.count == 1, let word = parts.first {
            if dictionaryManager.items.contains(where: { $0.word.lowercased() == word.lowercased() }) {
                alertMessage = languageManager.localizedString(
                    for: "Dictionary duplicate word message",
                    defaultValue: "'%@' is already in the dictionary",
                    arguments: word
                )
                showAlert = true
                return
            }
            dictionaryManager.addWord(word)
            newWord = ""
            return
        }

        for word in parts {
            let lower = word.lowercased()
            if !dictionaryManager.items.contains(where: { $0.word.lowercased() == lower }) {
                dictionaryManager.addWord(word)
            }
        }
        newWord = ""
    }

    private func handleUpdateError(_ error: DictionaryManager.UpdateError, attemptedWord: String) {
        switch error {
        case .duplicate:
            let format = languageManager.localizedString(
                for: "Dictionary duplicate word message",
                defaultValue: "'%@' is already in the dictionary"
            )
            alertMessage = String(format: format, locale: languageManager.locale, attemptedWord)
        case .empty:
            alertMessage = languageManager.localizedString(
                for: "Dictionary empty word message",
                defaultValue: "Word can't be empty"
            )
        }
        showAlert = true
    }
}

struct DictionaryItemView: View {
    let item: DictionaryItem
    let onDelete: () -> Void
    let onUpdate: (String) -> Bool

    @State private var isDeleteHovered = false
    @State private var isEditHovered = false
    @State private var isConfirmHovered = false
    @State private var isCancelHovered = false
    @State private var isEditing = false
    @State private var editedWord: String
    @FocusState private var isTextFieldFocused: Bool

    init(item: DictionaryItem, onDelete: @escaping () -> Void, onUpdate: @escaping (String) -> Bool) {
        self.item = item
        self.onDelete = onDelete
        self.onUpdate = onUpdate
        _editedWord = State(initialValue: item.word)
    }

    var body: some View {
        HStack(spacing: 6) {
            if isEditing {
                TextField("", text: $editedWord)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity)
                    .focused($isTextFieldFocused)
                    .onSubmit(commitEdit)
                    .onExitCommand(perform: cancelEditing)
            } else {
                Text(item.word)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture(count: 2, perform: startEditing)
            }

            Spacer(minLength: 8)

            if isEditing {
                Button(action: commitEdit) {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isConfirmHovered ? .green : .blue)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
                .localizedHelp("Save word")
                .onHover { hover in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isConfirmHovered = hover
                    }
                }

                Button(action: cancelEditing) {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isCancelHovered ? .orange : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
                .localizedHelp("Cancel editing")
                .onHover { hover in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isCancelHovered = hover
                    }
                }
            } else {
                Button(action: startEditing) {
                    Image(systemName: "pencil.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isEditHovered ? .blue : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
                .localizedHelp("Edit word")
                .onHover { hover in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isEditHovered = hover
                    }
                }

                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isDeleteHovered ? .red : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
                .localizedHelp("Remove word")
                .onHover { hover in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isDeleteHovered = hover
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(.windowBackgroundColor).opacity(0.4))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.05), radius: 2, y: 1)
        .onChange(of: item.word) { newValue in
            if !isEditing {
                editedWord = newValue
            }
        }
    }

    private func startEditing() {
        guard !isEditing else { return }
        editedWord = item.word
        withAnimation(.easeInOut(duration: 0.2)) {
            isEditing = true
        }
        DispatchQueue.main.async {
            isTextFieldFocused = true
        }
    }

    private func commitEdit() {
        let trimmedWord = editedWord.trimmingCharacters(in: .whitespacesAndNewlines)
        let success = onUpdate(trimmedWord)

        if success {
            withAnimation(.easeInOut(duration: 0.2)) {
                isEditing = false
            }
            editedWord = trimmedWord.isEmpty ? item.word : trimmedWord
            isTextFieldFocused = false
        } else {
            DispatchQueue.main.async {
                isTextFieldFocused = true
            }
        }
    }

    private func cancelEditing() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isEditing = false
        }
        editedWord = item.word
        isTextFieldFocused = false
    }
}
