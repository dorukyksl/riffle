import SwiftUI

extension View {
    /// Lays the view out for `language`: right to left for Arabic and Hebrew, numbers and dates in its own style.
    func localized(_ language: AppLanguage) -> some View {
        environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
            .environment(\.locale, language.locale)
    }
}
