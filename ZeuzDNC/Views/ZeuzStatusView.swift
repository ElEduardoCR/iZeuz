import SwiftUI

/// Vista de taller: una tarjeta por Zeuz fisico, incluso cuando varios perfiles
/// de maquina apuntan a la misma Raspberry.
struct ZeuzStatusView: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkshopStatusStore.self) private var workshop
    @Environment(ZeuzAgentSettingsStore.self) private var agentSettings
    @Environment(\.dismiss) private var dismiss

    @State private var updateConfirmation: ZeuzWorkshopStatus?

    var body: some View {
        NavigationStack {
            Group {
                if !agentSettings.isReady {
                    EmptyStateView(
                        icon: "server.rack",
                        title: "Zeuz Agent no está conectado",
                        message: "Conecta el iPhone con Zeuz Agent para consultar todos los Zeuz del taller."
                    )
                } else if workshop.zeuz.isEmpty, workshop.isRefreshing {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("Buscando Zeuz…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if workshop.zeuz.isEmpty, let error = workshop.discoveryError {
                    EmptyStateView(
                        icon: "wifi.exclamationmark",
                        title: "No se pudo consultar el taller",
                        message: error,
                        actionTitle: "Reintentar",
                        action: { Task { await model.refreshWorkshopStatus() } }
                    )
                } else if workshop.zeuz.isEmpty {
                    EmptyStateView(
                        icon: "server.rack",
                        title: "No hay Zeuz configurados",
                        message: "Las máquinas asociadas con Zeuz Agent aparecerán aquí."
                    )
                } else {
                    statusList
                }
            }
            .navigationTitle("Estado de Zeuz")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cerrar") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.refreshWorkshopStatus() }
                    } label: {
                        if workshop.isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(workshop.isRefreshing)
                    .accessibilityLabel("Actualizar estado")
                }
            }
            .task { await model.refreshWorkshopStatus() }
            .confirmationDialog("Instalar actualización", isPresented: Binding(get: { updateConfirmation != nil }, set: { if !$0 { updateConfirmation = nil } }), presenting: updateConfirmation) { item in
                Button("Instalar versión \(item.update?.latest_version ?? "disponible")") { runUpdate(item, action: "install") }
            } message: { _ in
                Text("El equipo esperará a que termine cualquier envío y se reconectará automáticamente. Se conservan programas, perfiles y configuración.")
            }
        }
    }

    private var statusList: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                summaryCard

                if let error = workshop.discoveryError {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(ZeuzPalette.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }

                ForEach(workshop.zeuz) { item in
                    zeuzCard(item)
                }
            }
            .padding(16)
        }
        .refreshable { await model.refreshWorkshopStatus() }
        .background(Color(.systemGroupedBackground))
    }

    private var summaryCard: some View {
        GlassCard(tint: workshop.hasActiveTransfers ? ZeuzPalette.active : ZeuzPalette.ready) {
            HStack(spacing: 14) {
                Image(systemName: "server.rack")
                    .font(.title2)
                    .foregroundStyle(workshop.hasActiveTransfers ? ZeuzPalette.active : ZeuzPalette.ready)

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(workshop.zeuz.count) Zeuz detectado\(workshop.zeuz.count == 1 ? "" : "s")")
                        .font(.headline)
                    Text(summaryText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private var summaryText: String {
        if workshop.activeTransferCount == 0 {
            return L10n.text("Ningún envío en curso")
        }
        if workshop.activeTransferCount == 1 {
            return L10n.text("1 Zeuz enviando ahora")
        }
        return L10n.format("%lld Zeuz enviando al mismo tiempo", workshop.activeTransferCount)
    }

    private func zeuzCard(_ item: ZeuzWorkshopStatus) -> some View {
        GlassCard(tint: cardTint(item)) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.group.displayName)
                            .font(.title3.weight(.bold))
                        if let address = item.group.address {
                            Text(address)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    statusPill(item)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Máquinas configuradas")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(item.group.machineNames.joined(separator: " · "))
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let transfer = item.transfer, transfer.status != "idle" {
                    Divider()
                    transferDetails(transfer, hasConnectionError: item.errorMessage != nil)
                } else if item.errorMessage == nil {
                    Label("Listo para recibir órdenes", systemImage: "checkmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let error = item.errorMessage {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.transfer == nil ? "Sin conexión" : "Reconectando; se muestra el último avance conocido")
                                .font(.caption.weight(.semibold))
                            Text(error)
                                .font(.caption2)
                                .lineLimit(2)
                        }
                    } icon: {
                        Image(systemName: "wifi.exclamationmark")
                    }
                    .foregroundStyle(item.transfer == nil ? ZeuzPalette.danger : ZeuzPalette.warning)
                }

                Divider()
                updateControls(item)

                if let updated = item.lastUpdated {
                    Text("Actualizado \(updated.formatted(date: .omitted, time: .standard))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder
    private func updateControls(_ item: ZeuzWorkshopStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let update = item.update {
                HStack {
                    if update.isBusy { ProgressView().controlSize(.small) }
                    Label(update.label, systemImage: "arrow.down.circle")
                        .font(.subheadline.weight(.semibold))
                }
                if update.phase == "downloading", let bytes = update.downloaded_bytes, bytes > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) + " descargados")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let current = update.current_version {
                    Text("Versión \(current)" + (update.available == true ? " → \(update.latest_version ?? "")" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = update.error, !error.isEmpty {
                    Text(error).font(.caption).foregroundStyle(ZeuzPalette.warning)
                }
                if update.supported == true {
                    HStack {
                        Button("Comprobar") { runUpdate(item, action: "check") }
                        Spacer()
                        if update.available == true {
                            Button("Actualizar") { updateConfirmation = item }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .disabled(update.isBusy || workshop.updateActions.contains(item.id))
                    Toggle("Instalar automáticamente cuando esté libre", isOn: Binding(
                        get: { update.auto_install == true },
                        set: { runUpdate(item, action: "policy", autoInstall: $0) }
                    ))
                    .font(.caption)
                    .disabled(workshop.updateActions.contains(item.id))
                }
            }
            if let error = item.updateError {
                Text(error).font(.caption).foregroundStyle(ZeuzPalette.warning)
            }
        }
    }

    private func runUpdate(_ item: ZeuzWorkshopStatus, action: String, autoInstall: Bool? = nil) {
        guard let client = model.dncClient else { return }
        Task { await workshop.updateDevice(item, client: client, action: action, autoInstall: autoInstall) }
    }

    @ViewBuilder
    private func statusPill(_ item: ZeuzWorkshopStatus) -> some View {
        if item.errorMessage != nil, item.transfer == nil {
            StatusPill(level: .danger, text: "Sin conexión", icon: "wifi.slash")
        } else if item.errorMessage != nil {
            StatusPill(level: .warning, text: "Reconectando", icon: "arrow.clockwise")
        } else {
            switch item.transfer?.status {
            case "sending":
                StatusPill(level: .warning, text: "Enviando", icon: "paperplane.fill")
            case "success":
                StatusPill(level: .ready, text: "Completado", icon: "checkmark.circle.fill")
            case "error":
                StatusPill(level: .danger, text: "Error", icon: "exclamationmark.triangle.fill")
            case "cancelled":
                StatusPill(level: .warning, text: "Cancelado", icon: "xmark.circle.fill")
            default:
                StatusPill(level: .ready, text: "Disponible", icon: "checkmark.circle.fill")
            }
        }
    }

    private func transferDetails(
        _ transfer: ZeuzBridgeClient.PiTransfer,
        hasConnectionError: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let machine = transfer.machine, !machine.isEmpty {
                Label(machine, systemImage: "gearshape.2")
                    .font(.subheadline.weight(.semibold))
            }
            if let filename = transfer.filename, !filename.isEmpty {
                Label(filename, systemImage: "doc.plaintext")
                    .font(.subheadline.monospaced())
                    .lineLimit(1)
            }

            if transfer.status == "sending" || transfer.totalBytes > 0 {
                HStack {
                    Text(transfer.status == "sending" ? "Avance" : statusLabel(transfer.status))
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(transfer.percent)%")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(progressColor(transfer.status))
                }
                ProgressView(value: Double(transfer.percent), total: 100)
                    .tint(progressColor(transfer.status))

                if transfer.totalBytes > 0 {
                    Text(byteProgress(transfer))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if !transfer.message.isEmpty {
                Text(transfer.message)
                    .font(.caption)
                    .foregroundStyle(transfer.status == "error" ? ZeuzPalette.danger : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if hasConnectionError {
                Text("El envío de la máquina no fue modificado.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func cardTint(_ item: ZeuzWorkshopStatus) -> Color? {
        if item.errorMessage != nil { return ZeuzPalette.warning }
        switch item.transfer?.status {
        case "sending": return ZeuzPalette.active
        case "success": return ZeuzPalette.ready
        case "error": return ZeuzPalette.danger
        case "cancelled": return ZeuzPalette.warning
        default: return nil
        }
    }

    private func progressColor(_ status: String) -> Color {
        switch status {
        case "success": ZeuzPalette.ready
        case "error": ZeuzPalette.danger
        case "cancelled": ZeuzPalette.warning
        default: ZeuzPalette.active
        }
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "success": L10n.text("Completado")
        case "error": L10n.text("Error")
        case "cancelled": L10n.text("Cancelado")
        default: L10n.text("Avance")
        }
    }

    private func byteProgress(_ transfer: ZeuzBridgeClient.PiTransfer) -> String {
        let sent = ByteCountFormatter.string(
            fromByteCount: Int64(transfer.bytesSent),
            countStyle: .file
        )
        let total = ByteCountFormatter.string(
            fromByteCount: Int64(transfer.totalBytes),
            countStyle: .file
        )
        return "\(sent) de \(total)"
    }
}
