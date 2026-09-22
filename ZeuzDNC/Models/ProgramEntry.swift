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
    /// Texto entre parentesis que acompana al numero O en el encabezado.
    /// Por ejemplo, para `O0200 (16-312-2)` contiene `(16-312-2)`.
    var programDescriptor: String? = nil

    var sizeLabel: String {
        guard !isDirectory else { return "" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var metadataLabel: String {
        guard !isDirectory else { return "" }
        guard let modified else { return sizeLabel }
        let date = modified.formatted(date: .numeric, time: .shortened)
        return "\(sizeLabel) · \(date)"
    }

    var displayName: String {
        guard let programDescriptor else { return name }
        return "\(name) \(programDescriptor)"
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
        breadcrumb: [Breadcrumb(name: L10n.text("Programas"), path: "")],
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

    /// Busca la primera linea que contiene un numero de programa OXXXX. Solo
    /// devuelve el parentesis si esta inmediatamente despues de ese numero.
    /// Asi `O0050` se queda sin subtitulo y `O0200 (16-312-2)` lo muestra.
    static func descriptor(in header: String) -> String? {
        let programNumber = /(?i)\bO\d{4}\b/
        let numberAndDescriptor = /(?i)\bO\d{4}\b\s*(\([^)\r\n]+\))/

        for line in header.split(whereSeparator: \.isNewline) {
            guard line.firstMatch(of: programNumber) != nil else { continue }
            guard let match = line.firstMatch(of: numberAndDescriptor) else { return nil }
            return String(match.output.1)
        }
        return nil
    }
}

/// Orden de presentación compartido por la carpeta actual y la búsqueda.
/// `modified` siempre procede del repositorio; ordenar no modifica metadatos.
enum ProgramSortOrder: String, CaseIterable {
    case latestUpdated
    case name

    var title: String {
        switch self {
        case .latestUpdated: L10n.text("Última actualización")
        case .name: L10n.text("Nombre")
        }
    }

    func sorted(_ entries: [ProgramEntry]) -> [ProgramEntry] {
        entries.sorted { lhs, rhs in
            if self == .latestUpdated, lhs.modified != rhs.modified {
                switch (lhs.modified, rhs.modified) {
                case let (left?, right?): return left > right
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): break
                }
            }
            let names = lhs.name.localizedStandardCompare(rhs.name)
            if names != .orderedSame { return names == .orderedAscending }
            let paths = lhs.path.localizedStandardCompare(rhs.path)
            if paths != .orderedSame { return paths == .orderedAscending }
            // Desempate independiente del orden de llegada para nombres/rutas
            // que la comparación natural considera equivalentes.
            return lhs.path < rhs.path
        }
    }
}
