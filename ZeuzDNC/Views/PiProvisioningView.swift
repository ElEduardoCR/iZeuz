import SwiftUI

struct PiProvisioningView: View {
    @Environment(AppModel.self) private var model
    @Environment(PiProvisioningManager.self) private var provisioning
    @Environment(EndpointStore.self) private var endpoints
    @Environment(MachineStore.self) private var machines
    @Environment(ZeuzAgentSettingsStore.self) private var agent
    @Environment(ProgramStore.self) private var programs
    @Environment(\.dismiss) private var dismiss

    @State private var ssid = ""
    @State private var wifiPassword = ""
    @State private var machineDraft = Machine(name: "")
    @State private var agentURL = "http://MacBook-Air-de-Marlen.local:47820"
    @State private var pairingCode = ""
    @State private var agentStatus = ""
    @State private var pairingAgent = false
    @State private var savedPiID: UUID?

    var body: some View {
        NavigationStack {
            Form {
                switch provisioning.stage {
                case .idle, .scanning:
                    discoverySection
                case .connecting:
                    progressSection("Conectando por Bluetooth…")
                case .readyForCredentials:
                    wifiSection
                case .joiningWiFi:
                    progressSection("Conectando Zeuz al Wi-Fi…")
                case .completed:
                    completedSection
                    agentSection
                case .failed(let message):
                    failureSection(message)
                }
            }
            .navigationTitle("Configurar Zeuz")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .onAppear {
                if let pi = provisioning.provisionedPi {
                    save(pi)
                } else {
                    provisioning.startScanning()
                }
                if agent.settings.isConfigured { agentURL = agent.settings.normalizedURL }
            }
            .onChange(of: provisioning.provisionedPi) { _, pi in
                guard let pi, savedPiID != pi.id else { return }
                save(pi)
            }
        }
    }

    private var discoverySection: some View {
        Section {
            if provisioning.nearby.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Buscando equipos Zeuz DNC cercanos…")
                }
            } else {
                ForEach(provisioning.nearby) { pi in
                    Button {
                        provisioning.connect(to: pi.id)
                    } label: {
                        HStack {
                            Image(systemName: "externaldrive.connected.to.line.below")
                            VStack(alignment: .leading) {
                                Text(pi.name).fontWeight(.semibold)
                                Text("Zeuz sin configurar")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: signalIcon(pi.rssi))
                        }
                    }
                }
            }
        } header: {
            Text("Equipos encontrados")
        } footer: {
            Text("Enciende Zeuz y mantenlo cerca del iPhone.")
        }
    }

    private var wifiSection: some View {
        Group {
            Section {
                TextField("Nombre de la red (SSID)", text: $ssid)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Contraseña del Wi-Fi", text: $wifiPassword)
            } header: {
                Text("Red del taller")
            }

            Section {
                TextField("Nombre de la máquina", text: $machineDraft.name)
                    .autocorrectionDisabled()

                Picker("Baudrate", selection: $machineDraft.baudRate) {
                    ForEach(Machine.baudRateOptions, id: \.self) { rate in
                        Text("\(rate)").tag(rate)
                    }
                }
                Picker("Bits de datos", selection: $machineDraft.dataBits) {
                    ForEach([5, 6, 7, 8], id: \.self) { bits in
                        Text("\(bits)").tag(bits)
                    }
                }
                Picker("Paridad", selection: $machineDraft.parity) {
                    ForEach(Machine.Parity.allCases, id: \.self) { parity in
                        Text(parity.label).tag(parity)
                    }
                }
                Picker("Bits de stop", selection: $machineDraft.stopBits) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                }
                Picker("Control de flujo", selection: $machineDraft.flowControl) {
                    ForEach(Machine.FlowControl.allCases, id: \.self) { flow in
                        Text(flow.label).tag(flow)
                    }
                }
                Picker("Fin de línea", selection: $machineDraft.lineTerminator) {
                    ForEach(Machine.LineTerminator.allCases, id: \.self) { terminator in
                        Text(terminator.label).tag(terminator)
                    }
                }
                Toggle("DTR encendido", isOn: $machineDraft.dtr)
                Toggle("RTS encendido", isOn: $machineDraft.rts)
                    .disabled(machineDraft.flowControl == .rtsCts)
                Toggle("Modo goteo (drip-feed)", isOn: $machineDraft.dripFeed)
            } header: {
                Text("Configuración inicial de la máquina")
            } footer: {
                Text("Actual: \(machineDraft.summary)")
                    .font(.caption.monospaced())
            }

            Section {
                Button("Guardar máquina y conectar Wi-Fi") {
                    provisioning.configureWiFi(
                        ssid: ssid,
                        password: wifiPassword,
                        machine: machineDraft
                    )
                }
                .fontWeight(.semibold)
                .disabled(
                    ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || machineDraft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            } footer: {
                Text("El iPhone envía la red y el perfil serial a zeuz mediante Bluetooth cifrado.")
            }
        }
    }

    private var completedSection: some View {
        Section {
            Label("Zeuz conectado", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if let pi = provisioning.provisionedPi {
                LabeledContent("Equipo", value: pi.name)
                LabeledContent("Dirección", value: "\(pi.host):\(pi.port)")
                if !pi.ip.isEmpty {
                    LabeledContent("IP actual", value: pi.ip)
                }
            }
        }
    }

    private var agentSection: some View {
        Section {
            HStack {
                TextField("Dirección de Zeuz Agent", text: $agentURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !agentURL.isEmpty {
                    Button {
                        agentURL = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Borrar dirección")
                }
            }
            TextField("Código de 6 dígitos", text: $pairingCode)
                .keyboardType(.numberPad)
            if !agentStatus.isEmpty {
                Text(agentStatus)
                    .font(.caption)
                    .foregroundStyle(agentStatus.hasPrefix("Listo") ? .green : .red)
            }
            Button {
                pairEverything()
            } label: {
                if pairingAgent {
                    ProgressView()
                } else {
                    Label("Conectar todo con Zeuz Agent", systemImage: "link")
                }
            }
            .disabled(pairingAgent)
            Button("Terminar por ahora") { dismiss() }
        } header: {
            Text("Zeuz Agent")
        } footer: {
            Text("El mismo código conecta al iPhone y a Zeuz con la biblioteca de programas de la computadora.")
        }
    }

    private func progressSection(_ title: String) -> some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                Text(title)
            }
        }
    }

    private func failureSection(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Button("Intentar de nuevo") { provisioning.reset() }
        }
    }

    private func save(_ pi: ProvisionedZeuzPi) {
        do {
            _ = try endpoints.upsertZeuzBridge(name: pi.name, host: pi.host, port: pi.port)
            try machines.adoptProvisioned(pi.machine)
            provisioning.markConfigurationSaved()
            savedPiID = pi.id
        } catch {
            agentStatus = error.localizedDescription
        }
    }

    private func pairEverything() {
        guard let pi = provisioning.provisionedPi else {
            agentStatus = "Zeuz todavía no está listo"
            return
        }
        agentStatus = ""
        let normalized = ZeuzAgentSettings(baseURL: agentURL).normalizedURL
        let code = pairingCode.filter(\.isNumber)
        guard ZeuzAgentSettings(baseURL: normalized).isConfigured else {
            agentStatus = "Escribe una dirección válida, por ejemplo http://192.168.1.183:47820"
            return
        }
        guard code.count == 6 else {
            agentStatus = "Escribe el código de emparejamiento de 6 dígitos"
            return
        }
        pairingAgent = true
        Task {
            do {
                let result = try await ZeuzAgentProgramClient.pair(baseURL: normalized, code: code)
                try await ZeuzBridgeClient(host: pi.host, port: pi.port)
                    .pairAgent(url: normalized, code: code)
                let agentClient = ZeuzAgentProgramClient(
                    settings: ZeuzAgentSettings(baseURL: normalized),
                    token: result.token
                )
                let savedMachine = try await agentClient.saveProvisionedMachine(
                    pi.machine,
                    dncHost: pi.host,
                    dncPort: pi.port
                )
                try machines.adoptProvisioned(savedMachine)
                agent.settings = ZeuzAgentSettings(baseURL: normalized, agentName: result.agentName)
                agent.token = result.token
                await model.reconnect()
                guard programs.connectionState.isConnected else {
                    throw ZeuzAgentError.unreachable("La biblioteca no respondió después del emparejamiento")
                }
                agentStatus = "Listo: iPhone, Zeuz y Zeuz Agent conectados"
            } catch {
                agentStatus = error.localizedDescription
            }
            pairingAgent = false
        }
    }

    private func signalIcon(_ rssi: Int) -> String {
        switch rssi {
        case let value where value >= -55: "wifi"
        case let value where value >= -70: "wifi"
        default: "wifi.exclamationmark"
        }
    }
}
