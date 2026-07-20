import Foundation

/// Manejo de rutas dentro de la carpeta compartida.
///
/// Son funciones puras, sin red: viven aparte del cliente SMB para poder
/// probarlas solas. La regla importante es que una ruta pedida por la interfaz
/// NUNCA pueda salirse del share con "..", igual que `resolve_path` en la
/// version de la Raspberry Pi.
enum SMBPath {
    /// Normaliza y bloquea el path traversal.
    static func sanitize(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .filter { $0 != "." && $0 != ".." && !$0.isEmpty }
            .joined(separator: "/")
    }

    static func basename(_ path: String) -> String {
        sanitize(path).split(separator: "/").last.map(String.init) ?? path
    }

    static func parent(of path: String) -> String {
        var parts = sanitize(path).split(separator: "/")
        guard !parts.isEmpty else { return "" }
        parts.removeLast()
        return parts.joined(separator: "/")
    }

    static func join(_ directory: String, _ name: String) -> String {
        let dir = sanitize(directory)
        return dir.isEmpty ? name : "\(dir)/\(name)"
    }

    static func breadcrumb(for path: String) -> [Breadcrumb] {
        var crumbs = [Breadcrumb(name: "Programas", path: "")]
        var accumulated = ""
        for part in sanitize(path).split(separator: "/") {
            accumulated = accumulated.isEmpty ? String(part) : "\(accumulated)/\(part)"
            crumbs.append(Breadcrumb(name: String(part), path: accumulated))
        }
        return crumbs
    }

    static func isValidFilename(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        guard !name.hasPrefix(".") else { return false }
        return !name.contains("/") && !name.contains("\\")
    }

    /// Heuristica para no abrir un binario en el editor: un ZIP o un PDF
    /// "pasa" por latin-1 pero llena la pantalla de caracteres de control.
    static func looksBinary<D: DataProtocol>(_ data: D) -> Bool {
        let sample = Array(data.prefix(4096))
        guard !sample.isEmpty else { return false }

        // Byte NUL: latin-1/utf-8/cp1252 nunca lo tienen en texto.
        if sample.contains(0) { return true }

        // BOM de UTF-16/UTF-32: es texto, pero rompe el editor por columnas.
        if sample.count >= 2 {
            let head2 = Array(sample[0..<2])
            if head2 == [0xFF, 0xFE] || head2 == [0xFE, 0xFF] { return true }
        }

        // Firmas de formatos sin NUL al inicio pero que no son texto plano.
        let signatures: [[UInt8]] = [
            Array("%PDF-".utf8),
            [0x50, 0x4B, 0x03, 0x04],                    // ZIP/DOCX/XLSX
            [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07],        // RAR
            [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C],        // 7-Zip
            [0xFF, 0xD8, 0xFF],                          // JPEG
            Array("GIF87a".utf8),
            Array("GIF89a".utf8),
        ]
        for signature in signatures where sample.count >= signature.count {
            if Array(sample[0..<signature.count]) == signature { return true }
        }
        return false
    }
}
