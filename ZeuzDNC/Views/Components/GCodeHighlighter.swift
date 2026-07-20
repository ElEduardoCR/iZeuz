import UIKit

/// Coloreado de G-code al estilo CIMCO Edit.
///
/// Trabaja sobre un `NSMutableAttributedString` por rangos: al abrir el
/// programa se pinta todo, y al escribir solo se repinta el parrafo tocado.
/// Repintar un archivo de 2 MB en cada tecla congelaria el editor.
enum GCodeHighlighter {

    // MARK: - Paleta

    /// Colores dinamicos: la app se usa en modo claro junto a la ventana y en
    /// oscuro junto a la maquina, y tiene que leerse en los dos.
    private static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        }
    }

    static let plain   = dynamic(light: 0x1C1C1E, dark: 0xE8E8EA)
    static let gCode   = dynamic(light: 0x0B5FD0, dark: 0x6FB2FF)   // G  movimiento
    static let mCode   = dynamic(light: 0xC2185B, dark: 0xFF7FB0)   // M  maquina
    static let axis    = dynamic(light: 0x1B7F3B, dark: 0x6FDC8C)   // X Y Z A B C U V W
    static let arc     = dynamic(light: 0x00796B, dark: 0x4DD0C4)   // I J K R Q
    static let feed    = dynamic(light: 0xC25E00, dark: 0xFFAE57)   // F  avance
    static let spindle = dynamic(light: 0x6A3AB2, dark: 0xC4A2FF)   // S  husillo
    static let tool    = dynamic(light: 0x8A6100, dark: 0xE8C15C)   // T D H  herramienta
    static let lineNo  = dynamic(light: 0x9A9AA0, dark: 0x76767C)   // N  numero de linea
    static let progNo  = dynamic(light: 0x1C1C1E, dark: 0xFFFFFF)   // O  numero de programa
    static let comment = dynamic(light: 0x6E7B72, dark: 0x8FA396)   // ( ) y ;
    static let marker  = dynamic(light: 0xD32F2F, dark: 0xFF6B6B)   // %  inicio/fin de cinta

    /// Color de cada direccion. Agrupado por lo que significa en la maquina,
    /// no por orden alfabetico: al revisar un programa te interesa distinguir
    /// de un vistazo movimiento, herramienta y avance.
    static func color(for letter: Character) -> UIColor {
        switch letter {
        case "G":                               gCode
        case "M":                               mCode
        case "X", "Y", "Z", "A", "B", "C",
             "U", "V", "W":                     axis
        case "I", "J", "K", "R", "Q":           arc
        case "F", "E":                          feed
        case "S":                               spindle
        case "T", "D", "H":                     tool
        case "N":                               lineNo
        case "O":                               progNo
        default:                                plain
        }
    }

    // MARK: - Patrones

    // `NSRegularExpression` es inmutable y thread-safe una vez construida, por
    // eso se compila una sola vez y se comparte.

    /// Una palabra de G-code: una letra de direccion y su valor opcional
    /// (`G01`, `X-12.5`, `Z.5`, `M30`).
    private static let words = try! NSRegularExpression(
        pattern: "[A-Za-z][+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)?"
    )

    /// Comentarios: parentesis al estilo ISO, o `;` hasta el fin de linea.
    private static let comments = try! NSRegularExpression(
        pattern: "\\([^)\\n]*\\)?|;[^\\n]*"
    )

    /// `%` de inicio y fin de cinta.
    private static let markers = try! NSRegularExpression(
        pattern: "^\\s*%.*$",
        options: [.anchorsMatchLines]
    )

    // MARK: - Aplicacion

    /// Pinta `range` completo. El orden importa: primero las palabras y al
    /// final los comentarios, para que un `(G01 RAPIDO)` salga todo gris y no
    /// con la G azul en medio del texto.
    static func apply(to storage: NSMutableAttributedString, range: NSRange, font: UIFont) {
        let source = storage.string
        let ns = source as NSString

        storage.setAttributes([.font: font, .foregroundColor: plain], range: range)

        words.enumerateMatches(in: source, range: range) { match, _, _ in
            guard let match, match.range.length > 0 else { return }
            let letter = Character(ns.substring(with: NSRange(location: match.range.location, length: 1)).uppercased())

            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color(for: letter)]
            // El numero de programa es el encabezado del archivo: en negrita se
            // encuentra al vuelo cuando hay varios programas en un mismo archivo.
            if letter == "O" {
                attributes[.font] = font.withTraits(.traitBold)
            }
            storage.addAttributes(attributes, range: match.range)
        }

        comments.enumerateMatches(in: source, range: range) { match, _, _ in
            guard let match, match.range.length > 0 else { return }
            storage.addAttributes(
                [.foregroundColor: comment, .font: font.withTraits(.traitItalic)],
                range: match.range
            )
        }

        markers.enumerateMatches(in: source, range: range) { match, _, _ in
            guard let match, match.range.length > 0 else { return }
            storage.addAttributes(
                [.foregroundColor: marker, .font: font.withTraits(.traitBold)],
                range: match.range
            )
        }
    }

    /// Version para mostrar texto ya coloreado fuera del editor.
    static func attributedString(_ text: String, font: UIFont) -> NSAttributedString {
        let storage = NSMutableAttributedString(string: text)
        apply(to: storage, range: NSRange(location: 0, length: (text as NSString).length), font: font)
        return storage
    }
}

// MARK: - Utilidades

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension UIFont {
    /// Mantiene el tamano y la familia monoespaciada al añadir negrita o cursiva.
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(
            fontDescriptor.symbolicTraits.union(traits)
        ) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
