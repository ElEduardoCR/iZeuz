import SwiftUI

/// Columna izquierda: explorador de la carpeta compartida, con subcarpetas,
/// busqueda recursiva y alta/baja de programas.
struct ProgramBrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(ProgramStore.self) private var programs

    @Binding var showsSettings: Bool
    @Binding var showsZeuzStatus: Bool
    let bottomClearance: CGFloat

    @State private var showsNewProgram = false
    @State private var showsNewFolder = false
    @State private var newName = ""
    @State private var pendingDeletion: ProgramEntry?

    private var isSearchActive: Bool {
        programs.searchQuery.trimmingCharacters(in: .whitespaces).count >= 2
    }

    var body: some View {
        @Bindable var programs = programs

        Group {
            switch programs.connectionState {
            case .disconnected, .connecting:
                connectingState
            case .failed(let message):
                failureState(message)
            case .connected:
                content
            }
        }
        .navigationTitle("Programas")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $programs.searchQuery,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Buscar programa"
        )
        .onChange(of: programs.searchQuery) { _, _ in
            programs.runSearch()
        }
        .toolbar { toolbarContent }
        .refreshable { await programs.refresh() }
        .alert("Nuevo programa", isPresented: $showsNewProgram) {
            TextField("Nombre (p. ej. O1234.NC)", text: $newName)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Crear") {
                let name = newName
                newName = ""
                Task { await programs.createProgram(named: name) }
            }
            Button("Cancelar", role: .cancel) { newName = "" }
        } message: {
            Text(L10n.format(
                "Se creara vacio en %@",
                programs.listing.path.isEmpty
                    ? L10n.text("la carpeta raiz")
                    : programs.listing.path
            ))
        }
        .alert("Nueva carpeta", isPresented: $showsNewFolder) {
            TextField("Nombre de la carpeta", text: $newName)
                .autocorrectionDisabled()
            Button("Crear") {
                let name = newName
                newName = ""
                Task { await programs.createFolder(named: name) }
            }
            Button("Cancelar", role: .cancel) { newName = "" }
        }
        .confirmationDialog(
            L10n.format("¿Eliminar %@?", pendingDeletion?.name ?? ""),
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Eliminar", role: .destructive) {
                if let entry = pendingDeletion {
                    Task { await programs.delete(entry) }
                }
                pendingDeletion = nil
            }
            Button("Cancelar", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("Se borra del share, no solo del iPhone. No se puede deshacer.")
        }
    }

    // MARK: - Estados de conexion

    private var connectingState: some View {
        VStack(spacing: 18) {
            if programs.connectionState == .connecting {
                ProgressView()
                Text("Conectando con el taller…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                EmptyStateView(
                    icon: "externaldrive.badge.wifi",
                    title: "Conecta con ZEUZ",
                    message: "Conecta con el taller usando la dirección y el código de Zeuz Agent. Tus programas permanecen en su ubicación actual.",
                    actionTitle: "Configurar",
                    action: { showsSettings = true }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureState(_ message: String) -> some View {
        VStack(spacing: 20) {
            EmptyStateView(
                icon: "wifi.exclamationmark",
                title: "No se pudo conectar",
                message: message,
                actionTitle: "Reintentar",
                action: { Task { await model.reconnect() } }
            )
            Button("Revisar ajustes") { showsSettings = true }
                .buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Contenido

    private var content: some View {
        List {
            if isSearchActive {
                searchSection
            } else {
                if programs.listing.breadcrumb.count > 1 {
                    breadcrumbSection
                }
                directoriesSection
                filesSection
            }
        }
        .listStyle(.insetGrouped)
        // La barra de envio flota sobre la pantalla. Este margen solo se
        // agrega al contenido desplazable para que el ultimo programa pueda
        // subir completamente por encima de ella.
        .contentMargins(.bottom, bottomClearance, for: .scrollContent)
        .overlay {
            if !isSearchActive, programs.listing.isEmpty, !programs.isLoading {
                EmptyStateView(
                    icon: "folder",
                    title: "Carpeta vacia",
                    message: "Copia programas a esta carpeta desde Windows o Mac y apareceran solos."
                )
            }
        }
    }

    private var breadcrumbSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(programs.listing.breadcrumb.enumerated()), id: \.element.id) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Button(crumb.name) {
                            Task { await programs.navigate(to: crumb.path) }
                        }
                        .font(.subheadline.weight(index == programs.listing.breadcrumb.count - 1 ? .semibold : .regular))
                        .foregroundStyle(index == programs.listing.breadcrumb.count - 1 ? .primary : Color.accentColor)
                        .disabled(index == programs.listing.breadcrumb.count - 1)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var directoriesSection: some View {
        Section {
            ForEach(programs.listing.directories) { entry in
                Button {
                    Task { await programs.navigate(to: entry.path) }
                } label: {
                    Label {
                        Text(entry.name).foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(ZeuzPalette.accent)
                    }
                }
            }
        } header: {
            if !programs.listing.directories.isEmpty {
                Text("Carpetas")
            }
        }
    }

    private var filesSection: some View {
        Section {
            ForEach(programs.listing.files) { entry in
                fileRow(entry)
            }
        } header: {
            if !programs.listing.files.isEmpty {
                Text("Programas · \(programs.listing.files.count)")
            }
        }
    }

    private var searchSection: some View {
        Section {
            if programs.isSearching {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Buscando en todas las subcarpetas…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if programs.searchResults.isEmpty {
                Text("Sin resultados para “\(programs.searchQuery)”")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(programs.searchResults) { entry in
                    fileRow(entry, showsPath: true)
                }
            }
        } header: {
            Text(
                programs.isSearching
                    ? L10n.text("Buscando")
                    : L10n.format("Resultados · %lld", programs.searchResults.count)
            )
        }
    }

    private func fileRow(_ entry: ProgramEntry, showsPath: Bool = false) -> some View {
        let parent = SMBPath.parent(of: entry.path)
        let detail = showsPath && !parent.isEmpty
            ? "\(parent) · \(entry.metadataLabel)"
            : entry.metadataLabel

        return Button {
            Task { await programs.open(entry) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.plaintext")
                    .foregroundStyle(programs.document?.path == entry.path ? ZeuzPalette.accent : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if programs.document?.path == entry.path {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ZeuzPalette.accent)
                }
            }
        }
        // Deslizar a la derecha: enviar. Nunca transmite solo — abre la
        // confirmacion, igual que el boton ENVIAR de la barra.
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Task { await model.requestSend(entry) }
            } label: {
                Label("Enviar", systemImage: "paperplane.fill")
            }
            .tint(ZeuzPalette.ready)
        }
        // Deslizar a la izquierda: editar. Eliminar queda en segundo lugar a
        // proposito, para que el deslizamiento completo nunca borre nada.
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                Task { await model.requestEdit(entry) }
            } label: {
                Label("Editar", systemImage: "pencil")
            }
            .tint(ZeuzPalette.accent)

            Button(role: .destructive) {
                pendingDeletion = entry
            } label: {
                Label("Eliminar", systemImage: "trash")
            }
        }
    }

    // MARK: - Barra de herramientas

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showsSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showsZeuzStatus = true
            } label: {
                Image(systemName: "server.rack")
                    .overlay(alignment: .topTrailing) {
                        if model.workshopStatus.hasActiveTransfers {
                            Circle()
                                .fill(ZeuzPalette.active)
                                .frame(width: 7, height: 7)
                                .offset(x: 3, y: -3)
                        }
                    }
            }
            .accessibilityLabel("Estado de los Zeuz")
            .accessibilityValue(
                model.workshopStatus.hasActiveTransfers
                    ? L10n.format(
                        "%lld enviando",
                        model.workshopStatus.activeTransferCount
                    )
                    : L10n.text("Ningún envío en curso")
            )

            Menu {
                Button {
                    newName = ""
                    showsNewProgram = true
                } label: {
                    Label("Nuevo programa", systemImage: "doc.badge.plus")
                }
                Button {
                    newName = ""
                    showsNewFolder = true
                } label: {
                    Label("Nueva carpeta", systemImage: "folder.badge.plus")
                }
                Divider()
                Button {
                    Task { await programs.refresh() }
                } label: {
                    Label("Actualizar", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "plus")
            }
            .disabled(!programs.connectionState.isConnected)
        }
    }
}
