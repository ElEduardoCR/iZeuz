import Foundation
import AMSMB2

/// Cliente SMB2/3 contra la carpeta compartida de la red.
///
/// Es el equivalente de `folder_monitor.py` de la Raspberry Pi: navegar
/// subcarpetas, leer, guardar, crear, borrar y buscar — pero hablando SMB
/// directo desde el iPhone en vez de leer un disco local.
actor SMBClient: ProgramClient {
    private var manager: SMB2Manager?
    private var settings: SMBSettings?
    private var descriptorCache: [String: DescriptorCacheEntry] = [:]

    /// Tope de lectura para el editor. Un programa de mas de 2 MB se abre en
    /// solo lectura: es casi seguro un volcado, no algo que se edite a mano.
    static let maxPreviewBytes = 2 * 1024 * 1024
    /// El numero O y su descripcion viven al principio de los programas. Solo
    /// traemos este encabezado para no descargar cada archivo al mostrar la lista.
    static let maxHeaderBytes: UInt64 = 4 * 1024

    private struct DescriptorCacheEntry {
        var size: Int64
        var modified: Date?
        var descriptor: String?
    }

    var isConnected: Bool { manager != nil }

    // MARK: - Conexion

    func connect(settings: SMBSettings, password: String) async throws {
        disconnectLocal()

        let host = settings.host.trimmingCharacters(in: .whitespaces)
        let share = settings.share.trimmingCharacters(in: .whitespaces)

        guard !host.isEmpty, !share.isEmpty else {
            throw SMBError.notConfigured
        }
        guard let url = URL(string: "smb://\(host)") else {
            throw SMBError.invalidHost(host)
        }

        let credential = URLCredential(
            user: settings.username,
            password: password,
            persistence: .forSession
        )
        guard let manager = SMB2Manager(url: url, domain: settings.domain, credential: credential) else {
            throw SMBError.invalidHost(host)
        }

        do {
            try await manager.connectShare(name: share)
        } catch {
            throw SMBError.connectionFailed(error.localizedDescription)
        }

        self.manager = manager
        self.settings = settings
    }

    func disconnect() async {
        if let manager {
            try? await manager.disconnectShare(gracefully: true)
        }
        disconnectLocal()
    }

    private func disconnectLocal() {
        manager = nil
        settings = nil
        descriptorCache.removeAll()
    }

    // MARK: - Navegacion

    func list(path: String) async throws -> DirectoryListing {
        let manager = try requireManager()
        let full = absolute(path)

        let raw: [[URLResourceKey: Any]]
        do {
            raw = try await manager.contentsOfDirectory(atPath: full)
        } catch {
            throw SMBError.listFailed(path, error.localizedDescription)
        }

        var directories: [ProgramEntry] = []
        var files: [ProgramEntry] = []

        for item in raw {
            guard let name = item[.nameKey] as? String else { continue }
            // "." y ".." no son programas ni carpetas navegables aqui.
            if name == "." || name == ".." { continue }
            if ProgramEntry.isIgnored(name) { continue }

            let isDirectory = (item[.fileResourceTypeKey] as? URLFileResourceType) == .directory
            var entry = ProgramEntry(
                name: name,
                path: join(path, name),
                isDirectory: isDirectory,
                size: (item[.fileSizeKey] as? NSNumber)?.int64Value ?? 0,
                modified: item[.contentModificationDateKey] as? Date
            )
            if !isDirectory {
                entry.programDescriptor = await descriptor(for: entry, manager: manager)
            }
            if isDirectory { directories.append(entry) } else { files.append(entry) }
        }

        directories.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        files.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        return DirectoryListing(
            path: path,
            breadcrumb: SMBPath.breadcrumb(for: path),
            directories: directories,
            files: files
        )
    }

    /// Busca por nombre de forma recursiva. Pensado para miles de archivos:
    /// case-insensitive por subcadena y se corta al llegar al limite.
    func search(query: String, limit: Int = 300) async throws -> [ProgramEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        let manager = try requireManager()

        let raw = try await manager.contentsOfDirectory(atPath: absolute(""), recursive: true)

        var results: [ProgramEntry] = []
        for item in raw {
            guard let name = item[.nameKey] as? String,
                  !ProgramEntry.isIgnored(name),
                  name.lowercased().contains(needle)
            else { continue }
            guard (item[.fileResourceTypeKey] as? URLFileResourceType) != .directory else { continue }

            let fullPath = (item[.pathKey] as? String) ?? name
            var entry = ProgramEntry(
                name: name,
                path: relative(fullPath),
                isDirectory: false,
                size: (item[.fileSizeKey] as? NSNumber)?.int64Value ?? 0,
                modified: item[.contentModificationDateKey] as? Date
            )
            entry.programDescriptor = await descriptor(for: entry, manager: manager)
            results.append(entry)
            if results.count >= limit { break }
        }
        results.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return results
    }

    // MARK: - Archivos

    func read(path: String) async throws -> ProgramDocument {
        let manager = try requireManager()

        let data: Data
        do {
            data = try await manager.contents(atPath: absolute(path))
        } catch {
            throw SMBError.readFailed(path, error.localizedDescription)
        }

        let truncated = data.count > Self.maxPreviewBytes
        let slice = truncated ? data.prefix(Self.maxPreviewBytes) : data

        guard !SMBPath.looksBinary(slice) else {
            throw SMBError.binaryFile(SMBPath.basename(path))
        }

        // latin-1 mapea 1 a 1 cada byte: no falla con G-code/ISO.
        let content = String(data: slice, encoding: .isoLatin1) ?? ""
        return ProgramDocument(
            path: path,
            name: SMBPath.basename(path),
            content: content,
            truncated: truncated
        )
    }

    /// Guarda el programa, creandolo o reemplazandolo segun corresponda.
    ///
    /// El `write` de AMSMB2 abre el archivo con `O_RDWR | O_CREAT | O_EXCL`,
    /// asi que sobre un programa que ya existe falla siempre con EEXIST (17,
    /// "Open failed"): solo sirve para crear. Para reemplazar hay que pasar
    /// por `append` con offset 0, que trunca el archivo primero y lo abre sin
    /// `O_EXCL`. Es la unica sobrescritura que expone la libreria.
    func write(path: String, content: String) async throws {
        let manager = try requireManager()
        let data = content.data(using: .isoLatin1, allowLossyConversion: true) ?? Data()
        let full = absolute(path)
        let isReplacing = await exists(path: path)

        do {
            if isReplacing {
                try await manager.append(data: data, toPath: full, offset: 0, progress: nil)
            } else {
                try await manager.write(data: data, toPath: full, progress: nil)
            }
            descriptorCache.removeValue(forKey: path)
        } catch {
            throw SMBError.writeFailed(path, error.localizedDescription)
        }
    }

    func createFile(directory: String, name: String) async throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SMBPath.isValidFilename(clean) else { throw SMBError.invalidFilename }

        let path = join(directory, clean)
        // No pisamos un programa existente sin avisar.
        if await exists(path: path) { throw SMBError.alreadyExists(clean) }

        try await write(path: path, content: "")
        return path
    }

    func delete(path: String) async throws {
        let manager = try requireManager()
        do {
            try await manager.removeFile(atPath: absolute(path))
            descriptorCache.removeValue(forKey: path)
        } catch {
            throw SMBError.deleteFailed(path, error.localizedDescription)
        }
    }

    func createDirectory(parent: String, name: String) async throws -> String {
        let manager = try requireManager()
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SMBPath.isValidFilename(clean) else { throw SMBError.invalidFilename }

        let path = join(parent, clean)
        do {
            try await manager.createDirectory(atPath: absolute(path))
        } catch {
            throw SMBError.writeFailed(path, error.localizedDescription)
        }
        return path
    }

    func exists(path: String) async -> Bool {
        guard let manager else { return false }
        return (try? await manager.attributesOfItem(atPath: absolute(path))) != nil
    }

    /// Huella barata del contenido de una carpeta, para detectar cambios sin
    /// traerse los archivos. Reemplaza al contador de version del watchdog.
    func fingerprint(path: String) async throws -> String {
        let listing = try await list(path: path)
        let parts = (listing.directories + listing.files).map {
            "\($0.name):\($0.size):\($0.modified?.timeIntervalSince1970 ?? 0)"
        }
        return parts.joined(separator: "|")
    }

    /// Lee y memoriza solo el encabezado. La fecha y el tamano invalidan la
    /// cache cuando otro equipo modifica el programa en la carpeta compartida.
    private func descriptor(for entry: ProgramEntry, manager: SMB2Manager) async -> String? {
        if let cached = descriptorCache[entry.path],
           cached.size == entry.size,
           cached.modified == entry.modified {
            return cached.descriptor
        }

        let descriptor: String?
        do {
            let data = try await manager.contents(
                atPath: absolute(entry.path),
                range: UInt64(0)..<Self.maxHeaderBytes
            )
            let header = String(data: data, encoding: .isoLatin1) ?? ""
            descriptor = ProgramEntry.descriptor(in: header)
        } catch {
            // El nombre, peso y fecha siguen siendo utiles aunque un archivo
            // concreto no permita leer su encabezado.
            descriptor = nil
        }

        descriptorCache[entry.path] = DescriptorCacheEntry(
            size: entry.size,
            modified: entry.modified,
            descriptor: descriptor
        )
        return descriptor
    }

    // MARK: - Rutas

    private func requireManager() throws -> SMB2Manager {
        guard let manager else { throw SMBError.notConnected }
        return manager
    }

    /// Convierte una ruta relativa de la interfaz en la ruta real del share,
    /// anteponiendo la subcarpeta raiz configurada.
    private func absolute(_ path: String) -> String {
        let root = settings?.rootPath.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) ?? ""
        let clean = SMBPath.sanitize(path)
        if root.isEmpty { return clean }
        return clean.isEmpty ? root : "\(root)/\(clean)"
    }

    private func relative(_ absolutePath: String) -> String {
        let root = settings?.rootPath.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) ?? ""
        var path = absolutePath.replacingOccurrences(of: "\\", with: "/")
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !root.isEmpty, path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
    }

    private func join(_ directory: String, _ name: String) -> String {
        SMBPath.join(directory, name)
    }
}

// MARK: - Errores

enum SMBError: LocalizedError, Sendable {
    case notConfigured
    case notConnected
    case invalidHost(String)
    case connectionFailed(String)
    case listFailed(String, String)
    case readFailed(String, String)
    case writeFailed(String, String)
    case deleteFailed(String, String)
    case binaryFile(String)
    case invalidFilename
    case alreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Falta configurar la carpeta compartida en Ajustes"
        case .notConnected:
            "Sin conexion con la carpeta compartida"
        case .invalidHost(let host):
            "Direccion invalida: \(host)"
        case .connectionFailed(let detail):
            "No se pudo conectar al share: \(detail)"
        case .listFailed(let path, let detail):
            "No se pudo abrir la carpeta \(path.isEmpty ? "raiz" : path): \(detail)"
        case .readFailed(let path, let detail):
            "No se pudo leer \(path): \(detail)"
        case .writeFailed(let path, let detail):
            "No se pudo guardar \(path): \(detail)"
        case .deleteFailed(let path, let detail):
            "No se pudo eliminar \(path): \(detail)"
        case .binaryFile(let name):
            "\(name) no es un archivo de texto: no se puede abrir en el editor"
        case .invalidFilename:
            "Nombre de archivo invalido"
        case .alreadyExists(let name):
            "Ya existe un archivo llamado \(name)"
        }
    }
}
