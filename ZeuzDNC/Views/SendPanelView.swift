import SwiftUI

/// Barra inferior compacta: maquina, puerto y el boton ENVIAR en una fila.
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

        return Group {
            if transfer.isSending {
                sendingControls
            } else if transfer.state.status != .idle {
                finishedControls
            } else {
                selectionControls
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
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
        HStack(spacing: 8) {
            compactSelector(
                icon: "gearshape.2",
                title: machines.selected?.name ?? "Máquina",
                accessibilityTitle: "Máquina",
                accessibilityValue: machines.selected?.summary ?? "Sin seleccionar",
                isSet: machines.selected != nil
            ) { showsMachinePicker = true }

            compactSelector(
                icon: endpoints.selected?.kind.icon ?? "cable.connector",
                title: endpoints.selected?.name ?? "Raspberry",
                accessibilityTitle: "Puerto o Raspberry",
                accessibilityValue: endpoints.selected?.destination ?? "Sin seleccionar",
                isSet: endpoints.selected != nil
            ) { showsPortPicker = true }

            Button {
                model.showsSendConfirmation = true
            } label: {
                Label("Enviar", systemImage: "paperplane.fill")
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.glassProminent)
            .tint(model.canSend ? ZeuzPalette.ready : .gray)
            .disabled(!model.canSend)
            .accessibilityHint(model.blockers.joined(separator: ". "))
        }
    }

    private var sendingControls: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text(transfer.state.status.label)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if transfer.state.totalBytes > 0 {
                        Text("\(transfer.state.percent)%")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(ZeuzPalette.active)
                    }
                }
                ProgressView(value: transfer.state.fraction)
                    .tint(ZeuzPalette.active)
            }

            Button(role: .destructive) {
                transfer.cancel()
            } label: {
                Label("Cancelar", systemImage: "stop.fill")
                    .font(.subheadline.weight(.bold))
                    .frame(minHeight: 44)
            }
            .buttonStyle(.glassProminent)
            .tint(ZeuzPalette.danger)
        }
    }

    private var finishedControls: some View {
        HStack(spacing: 10) {
            Image(systemName: finishedIcon)
                .foregroundStyle(finishedColor)
            Text(transfer.state.status.label)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Listo") { model.finishTransfer() }
                .buttonStyle(.glassProminent)
                .tint(finishedColor)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private func compactSelector(
        icon: String,
        title: String,
        accessibilityTitle: String,
        accessibilityValue: String,
        isSet: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(isSet ? ZeuzPalette.accent : .secondary)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(
            isSet ? .regular.tint(ZeuzPalette.accent.opacity(0.15)) : .regular,
            in: .rect(cornerRadius: 14)
        )
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(accessibilityValue)
    }

    private var finishedColor: Color {
        switch transfer.state.status {
        case .success: ZeuzPalette.ready
        case .error: ZeuzPalette.danger
        case .cancelled: ZeuzPalette.warning
        default: .secondary
        }
    }

    private var finishedIcon: String {
        switch transfer.state.status {
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle.fill"
        default: "info.circle.fill"
        }
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
