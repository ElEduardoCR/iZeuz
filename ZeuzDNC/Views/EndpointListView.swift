import SwiftUI

/// Lista de puertos: seleccionar, editar, eliminar y dar de alta.
///
/// Un puente con hub de varios USB se representa como varios puertos con el
/// mismo host y distinto puerto TCP, cada uno con su nombre.
struct EndpointListView: View {
    @Environment(EndpointStore.self) private var endpoints
    @Environment(\.dismiss) private var dismiss

    @State private var editing: SerialEndpoint?
    @State private var isCreating = false
    @State private var showsHubWizard = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(endpoints.endpoints) { endpoint in
                        row(endpoint)
                    }
                    .onDelete { endpoints.delete(at: $0) }
                    .onMove { endpoints.move(from: $0, to: $1) }
                } header: {
                    Text("Puertos dados de alta")
                } footer: {
                    Text(
                        "iOS no reconoce adaptadores USB-serial genericos, asi que los puertos se "
                            + "dan de alta a mano. A cambio, cada uno lleva el nombre que quieras."
                    )
                }

                if !endpoints.connectedAccessories.isEmpty {
                    Section("Cables detectados ahora") {
                        ForEach(endpoints.connectedAccessories) { accessory in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(accessory.name)
                                    .font(.subheadline.weight(.medium))
                                Text(accessory.protocolStrings.joined(separator: ", "))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Puertos")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if endpoints.endpoints.isEmpty {
                    EmptyStateView(
                        icon: "cable.connector",
                        title: "Sin puertos",
                        message: "Da de alta el puente de red o el cable por donde sale el G-code.",
                        actionTitle: "Agregar puerto",
                        action: { isCreating = true }
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Listo") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            isCreating = true
                        } label: {
                            Label("Puerto nuevo", systemImage: "plus")
                        }
                        Button {
                            showsHubWizard = true
                        } label: {
                            Label("Puente con hub (varios puertos)", systemImage: "square.stack.3d.up")
                        }
                        Divider()
                        Button {
                            endpoints.refreshAccessories()
                        } label: {
                            Label("Buscar cables conectados", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $editing) { endpoint in
                EndpointEditorView(endpoint: endpoint)
            }
            .sheet(isPresented: $isCreating) {
                EndpointEditorView(endpoint: nil)
            }
            .sheet(isPresented: $showsHubWizard) {
                HubWizardView()
            }
            .task { endpoints.refreshAccessories() }
        }
    }

    private func row(_ endpoint: SerialEndpoint) -> some View {
        let availability = endpoints.availability(of: endpoint)

        return HStack(spacing: 12) {
            Button {
                endpoints.select(endpoint)
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: endpoints.selectedID == endpoint.id
                        ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(endpoints.selectedID == endpoint.id ? ZeuzPalette.ready : .secondary)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(endpoint.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        HStack(spacing: 6) {
                            Image(systemName: endpoint.kind.icon)
                                .font(.caption2)
                            Text(endpoint.destination)
                                .font(.caption.monospaced())
                        }
                        .foregroundStyle(.secondary)
                        Text(availability.label)
                            .font(.caption2)
                            .foregroundStyle(color(for: availability))
                    }
                    Spacer()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Button {
                editing = endpoint
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(ZeuzPalette.accent)
            }
            .buttonStyle(.plain)
        }
    }

    private func color(for availability: EndpointStore.Availability) -> Color {
        switch availability {
        case .ready: ZeuzPalette.ready
        case .unknown: .secondary
        case .disconnected: ZeuzPalette.danger
        case .notConfigured: ZeuzPalette.warning
        }
    }
}

// MARK: - Editor de puerto

struct EndpointEditorView: View {
    @Environment(EndpointStore.self) private var endpoints
    @Environment(\.dismiss) private var dismiss

    let endpoint: SerialEndpoint?

    @State private var draft: SerialEndpoint
    @State private var errorMessage: String?

    init(endpoint: SerialEndpoint?) {
        self.endpoint = endpoint
        _draft = State(initialValue: endpoint ?? SerialEndpoint(name: ""))
    }

    private var isNew: Bool { endpoint == nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nombre (p. ej. Torno chico)", text: $draft.name)
                        .autocorrectionDisabled()
                } header: {
                    Text("Nombre")
                } footer: {
                    Text("Es lo unico que ve el operador al elegir a donde enviar.")
                }

                Section("Tipo de conexion") {
                    Picker("Tipo", selection: $draft.kind) {
                        ForEach(SerialEndpoint.Kind.allCases, id: \.self) { kind in
                            Label(kind.label, systemImage: kind.icon).tag(kind)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                switch draft.kind {
                case .networkBridge: networkSection
                case .mfiCable: cableSection
                case .simulator: simulatorSection
                }

                if !isNew {
                    Section {
                        Button("Eliminar puerto", role: .destructive) {
                            if let endpoint { endpoints.delete(endpoint) }
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Nuevo puerto" : draft.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") { save() }
                        .fontWeight(.semibold)
                }
            }
            .alert("Revisa el puerto", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("Entendido", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private var networkSection: some View {
        Section {
            TextField("IP o nombre (192.168.1.50)", text: $draft.host)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            LabeledContent("Puerto TCP") {
                TextField("4196", value: $draft.port, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }

            TextField("Puerto fisico (/dev/ttyUSB0)", text: $draft.bridgePort)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Puente en la red WiFi")
        } footer: {
            Text(
                "El puente es el equipo que tiene el adaptador USB-RS232: una Raspberry Pi, "
                    + "un ESP32 o un servidor serial. El campo del puerto fisico es solo una nota "
                    + "para acordarte de cual es cual cuando hay un hub."
            )
        }

        Section {
            Toggle("Negociar RFC 2217", isOn: $draft.useRFC2217)
        } footer: {
            Text(
                draft.useRFC2217
                    ? "La app le dice al puente el baudrate, paridad y bits del perfil de maquina en "
                        + "cada envio. Solo funciona si el puente soporta RFC 2217."
                    : "El puente usa la configuracion que tenga cargada. Tienes que dejarlo puesto al "
                        + "baudrate de la maquina antes de enviar."
            )
        }
    }

    @ViewBuilder
    private var cableSection: some View {
        Section {
            TextField("Protocolo MFi", text: $draft.accessoryProtocol)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            TextField(
                "Numero de serie (opcional)",
                text: Binding(
                    get: { draft.accessorySerialNumber ?? "" },
                    set: { draft.accessorySerialNumber = $0.isEmpty ? nil : $0 }
                )
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        } header: {
            Text("Cable certificado MFi")
        } footer: {
            Text(
                "Solo funciona con cables certificados (Redpark L2-DB9V3 o C4-DB9V). "
                    + "Un adaptador USB-RS232 comun no sirve: iOS no lo reconoce. "
                    + "El protocolo debe coincidir con el declarado en Info.plist. "
                    + "Usa el numero de serie solo si hay varios cables conectados."
            )
        }

        if !endpoints.connectedAccessories.isEmpty {
            Section("Cables detectados") {
                ForEach(endpoints.connectedAccessories) { accessory in
                    Button {
                        draft.accessorySerialNumber = accessory.serialNumber
                        if let first = accessory.protocolStrings.first {
                            draft.accessoryProtocol = first
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(accessory.name)
                            Text(accessory.protocolStrings.joined(separator: ", "))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var simulatorSection: some View {
        Section {
            Label("No se manda nada a ningun lado", systemImage: "info.circle")
                .font(.subheadline)
        } footer: {
            Text(
                "Reproduce el envio completo respetando el tiempo real que tardaria a ese baudrate. "
                    + "Sirve para probar la app sin el puente ni el cable."
            )
        }
    }

    private func save() {
        do {
            let saved = try endpoints.save(draft)
            if isNew { endpoints.select(saved) }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Alta rapida de un hub

/// Da de alta de golpe los puertos de un puente con varios USB conectados.
struct HubWizardView: View {
    @Environment(EndpointStore.self) private var endpoints
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var basePort = 4196
    @State private var count = 4
    @State private var namePrefix = "Maquina"
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Puente") {
                    TextField("IP del puente", text: $host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    LabeledContent("Primer puerto TCP") {
                        TextField("4196", value: $basePort, format: .number.grouping(.never))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section {
                    Stepper("Puertos a crear: \(count)", value: $count, in: 1...16)
                    TextField("Prefijo del nombre", text: $namePrefix)
                        .autocorrectionDisabled()
                } header: {
                    Text("Puertos")
                } footer: {
                    Text(
                        "Se crearan \(count) puertos, de \(basePort) a \(basePort + count - 1), "
                            + "llamados \"\(namePrefix) 1\" … \"\(namePrefix) \(count)\". "
                            + "Puedes renombrarlos despues uno por uno."
                    )
                }
            }
            .navigationTitle("Puente con hub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Crear") { create() }
                        .fontWeight(.semibold)
                        .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .alert("No se pudo crear", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("Entendido", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func create() {
        do {
            try endpoints.addBridgePorts(
                host: host,
                basePort: basePort,
                count: count,
                namePrefix: namePrefix.trimmingCharacters(in: .whitespaces)
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
