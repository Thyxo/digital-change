import Foundation

/// Sprog i appens egne tekster (hemmelig menu, log). Kameraets tekster (FOTO/VIDEO, slet …) følger iPhonens sprog.
enum AppLanguage: String, CaseIterable, Identifiable {
    case en, da
    var id: String { rawValue }
    var name: String { self == .en ? "English" : "Dansk" }
}

enum L10n {
    /// Sættes af `AppSettings`.
    static var lang: AppLanguage = .en
}

/// Engelsk først, dansk bagefter.
func tr(_ en: String, _ da: String) -> String { L10n.lang == .da ? da : en }
