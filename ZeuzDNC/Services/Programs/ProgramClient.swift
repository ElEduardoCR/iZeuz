import Foundation

/// Fuente intercambiable de programas CNC.
///
/// La interfaz y el editor no saben si los archivos vienen de Zeuz Agent o
/// del SMB legado. Zeuz Agent es la ruta principal; SMB se conserva durante
/// la migracion para no romper instalaciones actuales.
protocol ProgramClient: Sendable {
    func disconnect() async
    func list(path: String) async throws -> DirectoryListing
    func search(query: String, limit: Int) async throws -> [ProgramEntry]
    func read(path: String) async throws -> ProgramDocument
    func write(path: String, content: String) async throws
    func createFile(directory: String, name: String) async throws -> String
    func createDirectory(parent: String, name: String) async throws -> String
    func delete(path: String) async throws
    func fingerprint(path: String) async -> String
}

