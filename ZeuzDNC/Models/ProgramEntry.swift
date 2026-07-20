import Foundation

/// Una entrada (archivo o carpeta) dentro de la carpeta compartida por SMB.
struct ProgramEntry: Identifiable, Hashable, Sendable {
    /// La ruta relativa dentro del share es unica, sirve de identidad.
    var id: String { path }
    var name: String
    /// Ruta relativa a la raiz del share, con "/" como separador.
    var path: String
    var isDirectory: Bool
    var size: Int64
    var modified: Date?

    var sizeLabel: String {
        guard !isDirectory else { return "" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

/// Un nivel del breadcrumb de navegacion.
struct Breadcrumb: Identifiable, Hashable, Sendable {
    var id: String { path }
    var name: String
    var path: String
}

/// Resultado de listar una carpeta.
struct DirectoryListing: Sendable {
    var path: String
    var breadcrumb: [Breadcrumb]
    var directories: [ProgramEntry]
    var files: [ProgramEntry]

    static let empty = DirectoryListing(
        path: "",
        breadcrumb: [Breadcrumb(name: "Programas", path: "")],
        directories: [],
        files: []
    )

    var isEmpty: Bool { directories.isEmpty && files.isEmpty }
}

/// Contenido de un programa abierto en el editor.
struct ProgramDocument: Sendable, Equatable {
    var path: String
    var name: String
    var content: String
    /// Se corto por tamano: el editor lo abre en solo lectura.
    var truncated: Bool
}

extension ProgramEntry {
    /// Basura que Windows/macOS dejan al copiar por SMB y que no son programas.
    static let ignoredNames: Set<String> = ["Thumbs.db", "desktop.ini", ".DS_Store"]

    static func isIgnored(_ name: String) -> Bool {
        name.hasPrefix(".") || ignoredNames.contains(name)
    }
}
