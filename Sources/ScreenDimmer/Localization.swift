import Foundation

/// User-facing text. English is the default (value in code + en.lproj); Polish comes from
/// pl.lproj and is picked by the system when Polish is the preferred macOS language.
func L(_ key: String, _ english: String) -> String {
    NSLocalizedString(key, tableName: nil, bundle: .main, value: english, comment: "")
}

/// Formatting variant (`%ld` for integers, `%@` for strings).
func L(_ key: String, _ english: String, _ args: CVarArg...) -> String {
    String(format: L(key, english), locale: Locale.current, arguments: args)
}
