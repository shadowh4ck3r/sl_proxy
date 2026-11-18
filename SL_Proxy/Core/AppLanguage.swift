import Combine
import SwiftUI

/// One language the app can switch to without leaving the app.
struct AppLanguage: Identifiable, Hashable {
    /// Folder name of the `.lproj` that holds its `Localizable.strings`.
    let code: String
    /// The language's own name, shown in the picker.
    let nativeName: String
    var id: String { code }
    var isRightToLeft: Bool { code == "ar" }

    static let all: [AppLanguage] = [
        AppLanguage(code: "en", nativeName: "English"),
        AppLanguage(code: "pcm", nativeName: "Nigerian Pidgin"),
        AppLanguage(code: "yo", nativeName: "Yorùbá"),
        AppLanguage(code: "ha", nativeName: "Hausa"),
        AppLanguage(code: "ig", nativeName: "Igbo"),
        AppLanguage(code: "fr", nativeName: "Français"),
        AppLanguage(code: "es", nativeName: "Español"),
        AppLanguage(code: "ar", nativeName: "العربية"),
        AppLanguage(code: "zh-Hans", nativeName: "简体中文"),
        AppLanguage(code: "ru", nativeName: "Русский"),
        AppLanguage(code: "pt", nativeName: "Português"),
    ]
}

/// In-app language switcher. The chosen code is kept in `UserDefaults`; the app root injects
/// `locale` and `layoutDirection` into the environment, so every `Text("Home")` /
/// `Label("Settings", ...)` literal re-resolves from the matching `<code>.lproj/Localizable.strings`
/// immediately, with no relaunch. Strings that are plain `String` values (for example the
/// connection status) are shown with `Text(LocalizedStringKey(value))`, or through `tr(_:)`.
@MainActor
final class LanguageStore: ObservableObject {
    static let defaultsKey = "appLanguageCode"

    @Published var code: String {
        didSet {
            guard code != oldValue else { return }
            UserDefaults.standard.set(code, forKey: Self.defaultsKey)
        }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.defaultsKey)
        code = AppLanguage.all.contains { $0.code == saved } ? (saved ?? "en") : "en"
    }

    var locale: Locale { Locale(identifier: code) }

    var layoutDirection: LayoutDirection {
        AppLanguage.all.first { $0.code == code }?.isRightToLeft == true ? .rightToLeft : .leftToRight
    }

    /// Looks `key` up in the selected language's string table; falls back to the key itself
    /// (the English text).
    func tr(_ key: String) -> String {
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}
