import Foundation

/// Estado de la carpeta de programas: navegacion, editor y refresco.
///
/// Reemplaza al watchdog de la Raspberry Pi con un sondeo ligero: cada pocos
/// segundos compara una huella de la carpeta que estas viendo y solo recarga
/// si cambio. Asi, cuando alguien guarda un programa desde Windows o Mac,
/// aparece solo en el iPhone sin tener que refrescar a mano.
@MainActor
@Observable
final class ProgramStore {
    // MARK: Conexion
    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var listing: DirectoryListing = .empty
    private(set) var isLoading = false

    // MARK: Editor
    private(set) var document: ProgramDocument?
    /// Texto en el editor. Puede diferir del guardado mientras se edita.
    var draft: String = ""
    private(set) var isSaving = false

    // MARK: Busqueda
    var searchQuery: String = ""
    private(set) var searchResults: [ProgramEntry] = []
    private(set) var isSearching = false

    var errorMessage: String?

    private let client = SMBClient()
    private var refreshTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var lastFingerprint = ""

    /// Cada cuanto se comprueba si la carpeta cambio. 4 s es suficiente para
    /// que se sienta inmediato sin castigar la bateria ni el NAS.
    private let refreshInterval: Duration = .seconds(4)

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)

        var isConnected: Bool { self == .connected }
    }

    /// Hay cambios sin guardar: no se puede enviar hasta guardar.
    var hasUnsavedChanges: Bool {
        guard let document else { return false }
        return draft != document.content
    }

    var canEdit: Bool {
        guard let document else { return false }
        return !document.truncated
    }

    /// Documento tal como se enviaria: el guardado, no el borrador.
    var sendableDocument: ProgramDocument? {
        guard let document, !hasUnsavedChanges else { return nil }
        return document
    }

    // MARK: - Conexion

    func connect(settings: SMBSettings, password: String) async {
        guard settings.isConfigured else {
            connectionState = .failed(SMBError.notConfigured.localizedDescription)
            return
        }
        stopAutoRefresh()
        connectionState = .connecting
        do {
            try await client.connect(settings: settings, password: password)
            connectionState = .connected
            await navigate(to: "")
            startAutoRefresh()
        } catch {
            connectionState = .failed(error.localizedDescription)
        }
    }

    func disconnect() async {
        stopAutoRefresh()
        await client.disconnect()
        connectionState = .disconnected
        listing = .empty
        closeDocument()
    }

    // MARK: - Navegacion

    func navigate(to path: String) async {
        guard connectionState.isConnected else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            listing = try await client.list(path: path)
            lastFingerprint = await client.fingerprint(path: path)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func navigateUp() async {
        await navigate(to: SMBPath.parent(of: listing.path))
    }

    func refresh() async {
        await navigate(to: listing.path)
    }

    // MARK: - Refresco automatico

    func startAutoRefresh() {
        stopAutoRefresh()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.refreshInterval ?? .seconds(4))
                guard !Task.isCancelled, let self else { return }
                await self.refreshIfChanged()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func refreshIfChanged() async {
        guard connectionState.isConnected, !isLoading else { return }
        let current = await client.fingerprint(path: listing.path)
        // Huella vacia = fallo de red momentaneo; no borramos lo que ya se ve.
        guard !current.isEmpty, current != lastFingerprint else { return }
        await navigate(to: listing.path)
    }

    // MARK: - Editor

    func open(_ entry: ProgramEntry) async {
        guard !entry.isDirectory else {
            await navigate(to: entry.path)
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await client.read(path: entry.path)
            document = loaded
            draft = loaded.content
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func closeDocument() {
        document = nil
        draft = ""
    }

    func save() async {
        guard let document, hasUnsavedChanges else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await client.write(path: document.path, content: draft)
            self.document = ProgramDocument(
                path: document.path,
                name: document.name,
                content: draft,
                truncated: document.truncated
            )
            lastFingerprint = await client.fingerprint(path: listing.path)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createProgram(named name: String) async {
        do {
            let path = try await client.createFile(directory: listing.path, name: name)
            await refresh()
            await open(ProgramEntry(
                name: SMBPath.basename(path),
                path: path,
                isDirectory: false,
                size: 0,
                modified: Date()
            ))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createFolder(named name: String) async {
        do {
            _ = try await client.createDirectory(parent: listing.path, name: name)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ entry: ProgramEntry) async {
        do {
            try await client.delete(path: entry.path)
            if document?.path == entry.path { closeDocument() }
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Busqueda

    func runSearch() {
        searchTask?.cancel()
        let query = searchQuery
        guard query.trimmingCharacters(in: .whitespaces).count >= 2 else {
            searchResults = []
            isSearching = false
            return
        }
        searchTask = Task { [weak self] in
            // Pequena espera para no lanzar una busqueda por cada tecla.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            self.isSearching = true
            defer { self.isSearching = false }
            do {
                let results = try await self.client.search(query: query)
                guard !Task.isCancelled else { return }
                self.searchResults = results
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        searchQuery = ""
        searchResults = []
        isSearching = false
    }
}
