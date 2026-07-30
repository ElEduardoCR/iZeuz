import SwiftUI

/// Ajustes: carpeta compartida, maquinas y puertos.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ProgramStore.self) private var programs
    @Environment(SMBSettingsStore.self) private var smb
    @Environment(ZeuzAgentSettingsStore.self) private var agent
    @Environment(MachineStore.self) private var machines
    @Environment(EndpointStore.self) private var endpoints
    @Environment(\.dismiss) private var dismiss

    @State private var draft = SMBSettings()
    @State private var password = ""
    @State private var agentURL = ""
    @State private var pairingCode = ""
    @State private var pairingError = ""
    @State private var isPairing = false
    @State private var isTesting = false
    @State private var showsMachines = false
    @State private var showsEndpoints = false

    var body: some View {
        NavigationStack {
            Form {
                connectionStatusSection
                agentSection
                shareSection
                credentialsSection
                catalogSection
                aboutSection
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar SMB") { saveAndConnect() }
                        .fontWeight(.semibold)
                        .disabled(!draft.isConfigured || isTesting)
                }
            }
            .sheet(isPresented: $showsMachines) { MachineListView() }
            .sheet(isPresented: $showsEndpoints) { EndpointListView() }
            .onAppear {
                draft = smb.settings
                password = smb.password
                agentURL = agent.settings.normalizedURL
            }
        }
    }

    // MARK: - Secciones

    private var connectionStatusSection: some View {
        Section {
            switch programs.connectionState {
            case .connected:
                StatusPill(
                    level: .ready,
                    text: agent.isReady
                        ? "Conectado a \(agent.settings.displayName)"
                        : "Conectado a \(smb.settings.displayPath)"
                )
            case .connecting:
                StatusPill(level: .neutral, text: "Conectando…")
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    StatusPill(level: .danger, text: "Sin conexion")
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .disconnected:
                StatusPill(level: .warning, text: "Sin configurar")
            }
        }
        .listRowBackground(Color.clear)
    }

    private var agentSection: some View {
        Section {
            TextField("http://zeuz-agent.local:47820", text: $agentURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            TextField("Codigo de 6 digitos", text: $pairingCode)
                .keyboardType(.numberPad)

            if !pairingError.isEmpty {
                Text(pairingError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button {
                pairAgent()
            } label: {
                if isPairing {
                    ProgressView()
                } else {
                    Label(
                        agent.isReady ? "Volver a emparejar" : "Emparejar y conectar",
                        systemImage: "link"
                    )
                }
            }
            .disabled(
                agentURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || pairingCode.filter(\.isNumber).count != 6
                    || isPairing
            )

            if agent.isReady {
                Button("Olvidar Zeuz Agent", role: .destructive) {
                    agent.forget()
                    pairingCode = ""
                    Task { await model.reconnect() }
                }
            }
        } header: {
            Text("Zeuz Agent (recomendado)")
        } footer: {
            Text(
                "Instala Zeuz Agent en la PC o Mac donde guardas los programas. "
                    + "No requiere configurar SMB, usuarios ni carpetas compartidas."
            )
        }
    }

    private var shareSection: some View {
        Section {
            TextField("Servidor (192.168.1.10)", text: $draft.host)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            TextField("Recurso compartido (cnc-programs)", text: $draft.share)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            TextField("Subcarpeta (opcional)", text: $draft.rootPath)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("SMB legado")
        } footer: {
            Text(
                "La misma carpeta que ves desde Windows o Mac. Al guardar un programa ahi, "
                    + "aparece solo en el iPhone en unos segundos."
            )
        }
    }

    private var credentialsSection: some View {
        Section {
            TextField("Usuario", text: $draft.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField("Contrasena", text: $password)

            TextField("Dominio (opcional)", text: $draft.domain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Credenciales")
        } footer: {
            Text("La contrasena se guarda en el llavero del iPhone, cifrada por el sistema.")
        }
    }

    private var catalogSection: some View {
        Section("Catalogo") {
            Button {
                showsMachines = true
            } label: {
                LabeledContent {
                    Text("\(machines.machines.count)")
                        .foregroundStyle(.secondary)
                } label: {
                    Label("Maquinas", systemImage: "gearshape.2")
                }
            }

            Button {
                showsEndpoints = true
            } label: {
                LabeledContent {
                    Text("\(endpoints.endpoints.count)")
                        .foregroundStyle(.secondary)
                } label: {
                    Label("Puertos", systemImage: "cable.connector")
                }
            }
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Maquina activa", value: machines.selected?.name ?? "ninguna")
            LabeledContent("Puerto activo", value: endpoints.selected?.name ?? "ninguno")
        } header: {
            Text("Seleccion actual")
        } footer: {
            Text(
                "ZeuzDNC para iOS. El envio por serial sale por un puente en la red WiFi o por un "
                    + "cable certificado MFi: iOS no reconoce adaptadores USB-RS232 genericos."
            )
        }
    }

    // MARK: - Acciones

    private func saveAndConnect() {
        isTesting = true
        // El llavero indexa por usuario+host+share, asi que la contrasena se
        // guarda despues de fijar los datos nuevos o quedaria en otra cuenta.
        smb.settings = draft
        smb.password = password

        Task {
            await model.reconnect()
            isTesting = false
            if programs.connectionState.isConnected {
                dismiss()
            }
        }
    }

    private func pairAgent() {
        isPairing = true
        pairingError = ""
        let normalized = ZeuzAgentSettings(baseURL: agentURL).normalizedURL
        let code = pairingCode.filter(\.isNumber)
        Task {
            do {
                let result = try await ZeuzAgentProgramClient.pair(
                    baseURL: normalized,
                    code: code
                )
                agent.settings = ZeuzAgentSettings(
                    baseURL: normalized,
                    agentName: result.agentName
                )
                agent.token = result.token
                await model.reconnect()
                if programs.connectionState.isConnected {
                    dismiss()
                }
            } catch {
                pairingError = error.localizedDescription
            }
            isPairing = false
        }
    }
}
