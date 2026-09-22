import SwiftUI

/// Conexión al taller y perfiles de máquinas.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ProgramStore.self) private var programs
    @Environment(ZeuzAgentSettingsStore.self) private var agent
    @Environment(MachineStore.self) private var machines
    @Environment(EndpointStore.self) private var endpoints
    @Environment(\.dismiss) private var dismiss

    @State private var agentURL = ""
    @State private var pairingCode = ""
    @State private var pairingError = ""
    @State private var isPairing = false
    @State private var showsMachines = false
    @State private var showsEndpoints = false

    var body: some View {
        NavigationStack {
            Form {
                connectionStatusSection
                agentSection
                catalogSection
                aboutSection
                appVersionSection
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }

            }
            .sheet(isPresented: $showsMachines) { MachineListView() }
            .sheet(isPresented: $showsEndpoints) { EndpointListView() }
            .onAppear {
                let savedURL = agent.settings.normalizedURL
                agentURL = savedURL
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
                    text: L10n.format(
                        "Conectado a %@",
                        agent.settings.displayName
                    )
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
            HStack {
                TextField("Dirección del taller", text: $agentURL)
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
            // El botón debe poder explicar qué dato falta. Si se deshabilita
            // por validación, el operador sólo ve un control gris sin motivo.
            .disabled(isPairing)

            if agent.isReady {
                Button("Olvidar conexión", role: .destructive) {
                    agent.forget()
                    pairingCode = ""
                    Task { await model.reconnect() }
                }
            }
        } header: {
            Text("Conectar con ZEUZ")
        } footer: {
            Text(
                "Copia la dirección y el código que muestra Zeuz Agent. Cuando el servidor del taller esté listo, iZeuz podrá seguir trabajando aunque la computadora salga del sitio."
            )
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


        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent(
                "Maquina activa",
                value: machines.selected?.name ?? L10n.text("ninguna")
            )

        } header: {
            Text("Seleccion actual")
        } footer: {
            Text(L10n.text(
                "Los parámetros de cada máquina se comparten entre iPhone, Zeuz Agent y su pantalla táctil. Las ediciones sin conexión se concilian al volver a conectar."
            ))
        }
    }

    private var appVersionSection: some View {
        Section {
            HStack(spacing: 10) {
                Image("ZEUZMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                Text(verbatim: "ZEUZ DNC")
                    .font(.headline)
            }
            LabeledContent("Versión instalada", value: installedAppVersion)
        } header: {
            Text("ZeuzDNC para iOS")
        }
    }

    private var installedAppVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    // MARK: - Acciones

    private func pairAgent() {
        pairingError = ""
        let normalized = ZeuzAgentSettings(baseURL: agentURL).normalizedURL
        let code = pairingCode.filter(\.isNumber)
        guard ZeuzAgentSettings(baseURL: normalized).isConfigured else {
            pairingError = "Escribe una dirección válida, por ejemplo http://192.168.1.183:47820"
            return
        }
        guard code.count == 6 else {
            pairingError = "Escribe el código de emparejamiento de 6 dígitos"
            return
        }
        isPairing = true
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
