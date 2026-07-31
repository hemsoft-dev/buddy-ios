import SwiftUI

enum BuddyTheme {
    static let accent = Color.orange
    static let background = Color(uiColor: .systemGroupedBackground)

    enum Spacing {
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 16
        static let large: CGFloat = 24
    }
}

private struct BuddyCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(BuddyTheme.Spacing.medium)
            .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

extension View {
    func buddyCard() -> some View {
        modifier(BuddyCardModifier())
    }
}
