import Foundation

enum L10n {
    static var isChinese: Bool { Locale.preferredLanguages.first?.hasPrefix("zh") == true }
    static func text(_ english: String, _ chinese: String) -> String { isChinese ? chinese : english }
}
