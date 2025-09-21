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
    static let shared = LanguageManager()

    private enum Constants {
        static let storageKey = "SelectedAppLanguage"
    }

    @Published var selectedLanguage: AppLanguage {
        didSet {
            persistLanguageSelection()
            Bundle.setLanguage(selectedLanguage.rawValue)
            NotificationCenter.default.post(name: .languageDidChange, object: selectedLanguage)
        }
    }

    private init() {
        if let storedValue = UserDefaults.standard.string(forKey: Constants.storageKey),
           let language = AppLanguage(rawValue: storedValue) {
            selectedLanguage = language
        } else {
            selectedLanguage = .russian
        }

        Bundle.setLanguage(selectedLanguage.rawValue)
        NotificationCenter.default.post(name: .languageDidChange, object: selectedLanguage)
    }

    var locale: Locale {
        selectedLanguage.locale
    }

    private func persistLanguageSelection() {
        UserDefaults.standard.set(selectedLanguage.rawValue, forKey: Constants.storageKey)
    }

    private func bundle(for language: AppLanguage) -> Bundle? {
        guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj") else {
            return nil
        }
        return Bundle(path: path)
    }

    private var activeBundle: Bundle? {
        bundle(for: selectedLanguage)
    }

    func localizedString(for key: String, defaultValue: String? = nil, table: String? = nil) -> String {
        let fallback = defaultValue ?? key
        if let bundle = activeBundle {
            return bundle.localizedString(forKey: key, value: fallback, table: table)
        }
        return Bundle.main.localizedString(forKey: key, value: fallback, table: table)
    }
}
