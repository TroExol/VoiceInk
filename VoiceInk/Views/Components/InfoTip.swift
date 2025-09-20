import SwiftUI

/// A reusable info tip component that displays helpful information in a popover
struct InfoTip: View {
    // Content configuration
    var title: LocalizedStringKey
    var message: LocalizedStringKey
    var learnMoreLink: URL?
    var learnMoreText: LocalizedStringKey = "Learn More"
    
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
            }
            .onTapGesture {
                isShowingTip.toggle()
            }
    }
}

// MARK: - Convenience initializers

extension InfoTip {
    /// Creates an InfoTip with just title and message
    init(title: LocalizedStringKey, message: LocalizedStringKey) {
        self.title = title
        self.message = message
        self.learnMoreLink = nil
    }
    
    /// Creates an InfoTip with a learn more link
    init(title: LocalizedStringKey, message: LocalizedStringKey, learnMoreURL: String, learnMoreText: LocalizedStringKey = "Learn More") {
        self.title = title
        self.message = message
        self.learnMoreLink = URL(string: learnMoreURL)
        self.learnMoreText = learnMoreText
    }
}
