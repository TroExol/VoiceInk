import SwiftUI

/// A reusable info tip component that displays helpful information in a popover
struct InfoTip: View {
    @EnvironmentObject private var languageManager: LanguageManager

    // Content configuration
    var titleKey: String
    var messageKey: String
    var learnMoreLink: URL?
    var learnMoreTextKey: String = "Learn More"
    
    // Appearance customization
    var iconName: String = "info.circle.fill"
    var iconSize: Image.Scale = .medium
    var iconColor: Color = .primary
    var width: CGFloat = 300
    
    // State
    @State private var isShowingTip: Bool = false
    
    var body: some View {
        Image(systemName: iconName)
            .imageScale(iconSize)
            .foregroundColor(iconColor)
            .fontWeight(.semibold)
            .padding(5)
            .contentShape(Rectangle())
            .popover(isPresented: $isShowingTip) {
                let title = languageManager.localizedString(for: titleKey)
                let message = languageManager.localizedString(for: messageKey)
                let learnMoreText = languageManager.localizedString(for: learnMoreTextKey)

                VStack(alignment: .leading, spacing: 10) {
                    Text(title)
                        .font(.headline)

                    Text(message)
                        .frame(width: width, alignment: .leading)
                        .padding(.bottom, learnMoreLink != nil ? 5 : 0)

                    if let url = learnMoreLink {
                        Button(action: {
                            NSWorkspace.shared.open(url)
                        }) {
                            Text(learnMoreText)
                        }
                        .foregroundColor(.blue)
                    }
                }
                .padding()
                .environmentObject(languageManager)
                .environment(\.locale, languageManager.locale)
            }
            .onTapGesture {
                isShowingTip.toggle()
            }
    }
}

// MARK: - Convenience initializers

extension InfoTip {
    /// Creates an InfoTip with just title and message
    init(title: String, message: String) {
        self.titleKey = title
        self.messageKey = message
        self.learnMoreLink = nil
    }

    /// Creates an InfoTip with a learn more link
    init(title: String, message: String, learnMoreURL: String, learnMoreText: String = "Learn More") {
        self.titleKey = title
        self.messageKey = message
        self.learnMoreLink = URL(string: learnMoreURL)
        self.learnMoreTextKey = learnMoreText
    }
}

private struct LocalizedHelpModifier: ViewModifier {
    @EnvironmentObject private var languageManager: LanguageManager
    let key: String
    let defaultValue: String?

    func body(content: Content) -> some View {
        let text = languageManager.localizedString(for: key, defaultValue: defaultValue)
        return content.help(text)
    }
}

extension View {
    func localizedHelp(_ key: String, defaultValue: String? = nil) -> some View {
        modifier(LocalizedHelpModifier(key: key, defaultValue: defaultValue))
    }
}
