import SwiftUI

extension View {
    /// Small, quiet explanatory text (V2Box style). Every guide, footer and hint in the app uses
    /// this one size so it can be tuned in one place. Pass `hidden: true` to drop all guide text.
    func guideText() -> some View {
        modifier(GuideTextStyle())
    }
}

struct GuideTextStyle: ViewModifier {
    /// Flip to true to remove every guide line that uses `.guideText()` or `.guideFooter(_:)`.
    static let hideAll = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if Self.hideAll {
            EmptyView()
        } else {
            content
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

extension Text {
    /// Section footer text at guide size, for `Section { } footer: { Text("...").guideFooter() }`.
    func guideFooter() -> some View {
        self.font(.system(size: 10.5)).foregroundStyle(.secondary)
    }
}
