import Foundation
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

    func localizedString(
        for key: String,
        defaultValue: String? = nil,
        table: String? = nil,
        arguments: CVarArg...
    ) -> String {
        let format = localizedString(for: key, defaultValue: defaultValue, table: table)
        guard !arguments.isEmpty else {
            return format
        }

        return formattedString(
            format: format,
            key: key,
            defaultValue: defaultValue,
            table: table,
            arguments: arguments
        )
    }

    private func formattedString(
        format: String,
        key: String,
        defaultValue: String?,
        table: String?,
        arguments: [CVarArg]
    ) -> String {
        if format.contains("%#@") {
            if let localized = localizedStringFromStringsdict(
                key: key,
                table: table,
                arguments: arguments
            ) {
                return localized
            }

            let fallbackFormat = defaultValue ?? format
            return String(format: fallbackFormat, locale: locale, arguments: arguments)
        }

        return String(format: format, locale: locale, arguments: arguments)
    }

    private func localizedStringFromStringsdict(
        key: String,
        table: String?,
        arguments: [CVarArg]
    ) -> String? {
        let tableName = table ?? "Localizable"
        let bundle = activeBundle ?? Bundle.main

        guard
            let url = bundle.url(forResource: tableName, withExtension: "stringsdict"),
            let dictionary = NSDictionary(contentsOf: url) as? [String: Any],
            let entry = dictionary[key] as? [String: Any],
            let formatKey = entry["NSStringLocalizedFormatKey"] as? String
        else {
            return nil
        }

        let placeholders = extractPlaceholderNames(from: formatKey)
        guard placeholders.count == arguments.count else {
            return nil
        }

        var result = formatKey
        for (index, placeholder) in placeholders.enumerated() {
            guard
                let spec = entry[placeholder] as? [String: Any],
                let replacement = formattedReplacement(
                    for: arguments[index],
                    spec: spec
                )
            else {
                return nil
            }

            result = result.replacingOccurrences(
                of: "%#@\(placeholder)@",
                with: replacement
            )
        }

        return result
    }

    private func formattedReplacement(for argument: CVarArg, spec: [String: Any]) -> String? {
        guard let specType = spec["NSStringFormatSpecTypeKey"] as? String else {
            return nil
        }

        switch specType {
        case "NSStringPluralRuleType":
            guard let count = integerValue(from: argument) else {
                return nil
            }

            let category = pluralCategory(for: count)
            let format = (spec[category] as? String) ?? (spec["other"] as? String)
            guard let resolvedFormat = format else {
                return nil
            }

            return String(format: resolvedFormat, locale: locale, arguments: [count])
        default:
            if let valueFormat = spec["NSStringFormatValueTypeKey"] as? String {
                return String(format: valueFormat, locale: locale, arguments: [argument])
            }
            return nil
        }
    }

    private func integerValue(from argument: CVarArg) -> Int? {
        if let value = argument as? Int {
            return value
        }
        if let value = argument as? Int8 {
            return Int(value)
        }
        if let value = argument as? Int16 {
            return Int(value)
        }
        if let value = argument as? Int32 {
            return Int(value)
        }
        if let value = argument as? Int64 {
            return Int(value)
        }
        if let value = argument as? UInt {
            return Int(value)
        }
        if let value = argument as? UInt8 {
            return Int(value)
        }
        if let value = argument as? UInt16 {
            return Int(value)
        }
        if let value = argument as? UInt32 {
            return Int(value)
        }
        if let value = argument as? UInt64 {
            return Int(value)
        }
        if let number = argument as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private func pluralCategory(for count: Int) -> String {
        let normalized = abs(count)

        switch selectedLanguage {
        case .english:
            return normalized == 1 ? "one" : "other"
        case .russian:
            let mod10 = normalized % 10
            let mod100 = normalized % 100

            if mod10 == 1 && mod100 != 11 {
                return "one"
            }

            if (2...4).contains(mod10) && !(12...14).contains(mod100) {
                return "few"
            }

            if mod10 == 0 || (5...9).contains(mod10) || (11...14).contains(mod100) {
                return "many"
            }

            return "other"
        }
    }

    private func extractPlaceholderNames(from format: String) -> [String] {
        guard
            let regex = try? NSRegularExpression(pattern: "%#@([A-Za-z0-9_]+)@", options: [])
        else {
            return []
        }

        let range = NSRange(format.startIndex..<format.endIndex, in: format)
        return regex.matches(in: format, options: [], range: range).compactMap { match -> String? in
            guard let nameRange = Range(match.range(at: 1), in: format) else {
                return nil
            }
            return String(format[nameRange])
        }
    }
}
