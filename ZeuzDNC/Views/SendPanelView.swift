import SwiftUI

/// Barra inferior de envio: maquina, puerto y el boton ENVIAR.
///
/// Como en la version de la Pi, enviar es siempre una accion manual y
/// explicita con confirmacion — la app nunca transmite sola porque apareciera
/// un archivo en la carpeta.
struct SendBar: View {
    @Environment(AppModel.self) private var model
    @Environment(MachineStore.self) private var machines
    @Environment(EndpointStore.self) private var endpoints
    @Environment(TransferController.self) private var transfer

    @State private var showsMachinePicker = false
    @State private var showsPortPicker = false

    var body: some View {
        @Bindable var model = model

        return VStack(spacing: 12) {
            if transfer.state.status != .idle {
                TransferProgressView(state: transfer.state)
            }

            if transfer.isSending {
                sendingControls
            } else {
                selectionControls
            }

            if !model.blockers.isEmpty, !transfer.isSending {
                Text(model.blockers.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .sheet(isPresented: $showsMachinePicker) { MachineListView() }
        .sheet(isPresented: $showsPortPicker) { EndpointListView() }
        .confirmationDialog(
            confirmationTitle,
            isPresented: $model.showsSendConfirmation,
            titleVisibility: .visible
        ) {
            Button("Enviar ahora") { model.send() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    // MARK: - Controles

    private var selectionControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                chip(
                    icon: "gearshape.2",
                    title: machines.selected?.name ?? "Elegir maquina",
                    subtitle: machines.selected?.summary ?? "sin seleccionar",
                    isSet: machines.selected != nil
                ) { showsMachinePicker = true }

                chip(
                    icon: endpoints.selected?.kind.icon ?? "cable.connector",
                    title: endpoints.selected?.name ?? "Elegir puerto",
                    subtitle: endpoints.selected?.destination ?? "sin seleccionar",
                    isSet: endpoints.selected != nil
                ) { showsPortPicker = true }
            }

            Button {
                model.showsSendConfirmation = true
            } label: {
                Label("ENVIAR", systemImage: "paperplane.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.glassProminent)
            .tint(model.canSend ? ZeuzPalette.ready : .gray)
            .disabled(!model.canSend)

            if transfer.state.status == .success || transfer.state.status == .error
                || transfer.state.status == .cancelled {
                Button("Listo") { model.finishTransfer() }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var sendingControls: some View {
        Button(role: .destructive) {
            transfer.cancel()
        } label: {
            Label("CANCELAR ENVIO", systemImage: "stop.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.glassProminent)
        .tint(ZeuzPalette.danger)
    }

    private func chip(
        icon: String,
        title: String,
        subtitle: String,
        isSet: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(isSet ? ZeuzPalette.accent : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(
            isSet ? .regular.tint(ZeuzPalette.accent.opacity(0.15)) : .regular,
            in: .rect(cornerRadius: 16)
        )
    }

    // MARK: - Confirmacion

    private var confirmationTitle: String {
        guard let machine = machines.selected, let endpoint = endpoints.selected else {
            return "Confirmar envio"
        }
        return "¿Enviar a \(machine.name) por \(endpoint.name)?"
    }

    private var confirmationMessage: String {
        guard let machine = machines.selected else { return "" }
        var lines = [machine.summary]
        if machine.dripFeed {
            lines.append("Modo goteo: la maquina ejecuta mientras recibe. Solo se detiene con CANCELAR.")
        } else {
            lines.append("Asegurate de que la maquina este en modo recepcion antes de continuar.")
        }
        return lines.joined(separator: "\n\n")
    }
}
