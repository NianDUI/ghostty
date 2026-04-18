import Foundation

enum LocalizedString {
    static func text(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    static func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: args)
    }
}
