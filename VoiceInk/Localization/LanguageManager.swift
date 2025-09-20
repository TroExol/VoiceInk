import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case russian = "ru"

    var id: String { rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .english:
            return LocalizedStringKey("Language.English")
        case .russian:
            return LocalizedStringKey("Language.Russian")
        }
    }

    var locale: Locale {
        Locale(identifier: rawValue)
    }
}

final class LanguageManager: ObservableObject {
    private enum Constants {
        static let storageKey = "SelectedAppLanguage"
    }

    @Published var selectedLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(selectedLanguage.rawValue, forKey: Constants.storageKey)
            NotificationCenter.default.post(name: .languageDidChange, object: selectedLanguage)
        }
    }

    init() {
        if let storedValue = UserDefaults.standard.string(forKey: Constants.storageKey),
           let language = AppLanguage(rawValue: storedValue) {
            selectedLanguage = language
        } else {
            selectedLanguage = .english
        }
        NotificationCenter.default.post(name: .languageDidChange, object: selectedLanguage)
    }

    var locale: Locale {
        selectedLanguage.locale
    }
}
