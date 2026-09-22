import Foundation

/// Localiza textos que se construyen fuera de los inicializadores de SwiftUI.
///
/// Los literales que recibe directamente `Text`, `Button`, `Label`, etc. se
/// localizan solos. Los estados, errores y mensajes con valores dinámicos
/// necesitan pasar por este puente para respetar el idioma del dispositivo.
enum L10n {
    static func text(_ spanish: String) -> String {
        NSLocalizedString(
            spanish,
            tableName: nil,
            bundle: .main,
            value: spanish,
            comment: ""
        )
    }

    static func text(_ key: String, fallback spanish: String) -> String {
        NSLocalizedString(
            key,
            tableName: nil,
            bundle: .main,
            value: spanish,
            comment: ""
        )
    }

    static func format(_ spanish: String, _ arguments: CVarArg...) -> String {
        String(
            format: text(spanish),
            locale: Locale.current,
            arguments: arguments
        )
    }
}
