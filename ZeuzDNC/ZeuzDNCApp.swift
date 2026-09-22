import SwiftUI

@main
struct ZeuzDNCApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.programs)
                .environment(model.machines)
                .environment(model.endpoints)
                .environment(model.transfer)
                .environment(model.smbSettings)
                .environment(model.agentSettings)
                .environment(model.piProvisioning)
                .environment(model.workshopStatus)
        }
    }
}

/// Une las piezas de la app y coordina lo que depende de varias a la vez
/// (conectar al arrancar, si se puede enviar, etc.).
@MainActor
@Observable
final class AppModel {
    let programs = ProgramStore()
    let machines = MachineStore()
    let endpoints = EndpointStore()
    let transfer = TransferController()
    let smbSettings = SMBSettingsStore()
    let agentSettings = ZeuzAgentSettingsStore()
    let piProvisioning = PiProvisioningManager()
    let workshopStatus = WorkshopStatusStore()
    private var connectionMonitorTask: Task<Void, Never>?
    private let connectionRetryInterval: Duration = .seconds(15)

    /// Se muestra la hoja de ajustes al abrir si todavia no hay share.
    var showsOnboarding: Bool {
        !agentSettings.isReady
    }

    /// El editor esta abierto encima de la lista.
    var showsEditor = false

    /// Confirmacion de envio. La levanta el boton ENVIAR de la barra o el
    /// deslizamiento a la derecha en la lista; el dialogo vive en un solo
    /// sitio para que los dos caminos pidan confirmacion igual.
    var showsSendConfirmation = false

    /// Todo lo que falta para poder mandar el programa a la maquina.
    var blockers: [String] {
        var reasons: [String] = []
        if !programs.connectionState.isConnected {
            reasons.append(L10n.text("Conecta con el taller ZEUZ"))
        }
        if programs.document == nil {
            reasons.append(L10n.text("Elige un programa"))
        } else if programs.hasUnsavedChanges {
            reasons.append(L10n.text("Guarda los cambios antes de enviar"))
        }
        if machines.selected == nil {
            reasons.append(L10n.text("Selecciona una maquina"))
        }
        // Con Zeuz Agent, la máquina ya incluye su Orange Pi y configuración
        // serial. Los puertos manuales se conservan solo para el modo directo.
        if !agentSettings.isReady && endpoints.selected == nil {
            reasons.append(L10n.text("Selecciona un puerto"))
        }
        return reasons
    }

    var canSend: Bool {
        blockers.isEmpty && !transfer.isSending
    }

    // MARK: - Sincronizacion de maquinas con ZeuzDNC

    /// El iPhone habla solamente con ZeuzAgent. El agente localiza ZeuzDNC y
    /// retransmite estas operaciones sin exponer ni guardar su IP en la app.
    var dncClient: (any ZeuzDNCClient)? {
        guard agentSettings.isReady else { return nil }
        return ZeuzAgentProgramClient(
            settings: agentSettings.settings,
            token: agentSettings.token
        )
    }

    /// Sustituye la copia del iPhone por los perfiles actuales de ZeuzDNC.
    func syncMachinesFromZeuzDNC() async -> String? {
        guard let dncClient else {
            return L10n.text("Conecta Zeuz Agent antes de sincronizar con ZeuzDNC.")
        }
        do {
            try await machines.syncFromZeuzDNC(dncClient)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Aplica automáticamente los cambios hechos en la pantalla de ZeuzDNC.
    func checkMachineSynchronization() async {
        guard let dncClient else { return }
        _ = try? await machines.syncFromZeuzDNCIfChanged(dncClient)
    }

    func connectIfPossible() async {
        guard programs.connectionState != .connecting else { return }
        if agentSettings.isReady {
            await programs.connect(
                agent: agentSettings.settings,
                token: agentSettings.token
            )

        } else {
            return
        }
        guard !Task.isCancelled, programs.connectionState.isConnected else { return }
        if machines.lastSync == nil {
            _ = await syncMachinesFromZeuzDNC()
        } else {
            await checkMachineSynchronization()
        }
    }

    func reconnect() async {
        await programs.disconnect()
        await connectIfPossible()
    }

    // MARK: - Ciclo de vida de la conexión al taller

    /// Al abrir o volver a la app comprueba la sesion inmediatamente. Mientras
    /// la app siga activa vuelve a intentarlo cada minuto si la red o el servidor
    /// dejaron de responder.
    func startConnectionMonitoring() {
        stopConnectionMonitoring()
        if let dncClient {
            workshopStatus.start(client: dncClient)
        }
        connectionMonitorTask = Task { [weak self] in
            guard let self else { return }
            await self.maintainConnection()

            while !Task.isCancelled {
                try? await Task.sleep(for: self.connectionRetryInterval)
                guard !Task.isCancelled else { return }
                await self.maintainConnection()
            }
        }
    }

    func stopConnectionMonitoring() {
        connectionMonitorTask?.cancel()
        connectionMonitorTask = nil
        workshopStatus.stop()
        programs.stopAutoRefresh()
    }

    /// Consulta todos los destinos configurados sin mandar ninguna orden a las
    /// Raspberry. La pantalla de taller tambien usa esto para pull-to-refresh.
    func refreshWorkshopStatus() async {
        guard let dncClient else { return }
        await workshopStatus.refresh(client: dncClient)
    }

    private func maintainConnection() async {
        if machines.lastSync == nil {
            _ = await syncMachinesFromZeuzDNC()
        } else {
            await checkMachineSynchronization()
        }

        guard agentSettings.isReady,
              !transfer.isSending,
              !programs.isLoading
        else { return }

        if programs.connectionState.isConnected {
            // Tambien valida que una sesion que iOS dejo en memoria siga viva.
            if await programs.refresh(), !Task.isCancelled {
                programs.startAutoRefresh()
            } else if !Task.isCancelled {
                // La sesion guardada ya no servia: se crea otra en el mismo
                // momento, sin esperar al siguiente intento de un minuto.
                await connectIfPossible()
            }
        } else if programs.connectionState != .connecting {
            await connectIfPossible()
        }
    }

    // MARK: - Atajos de la lista

    /// Deslizar a la izquierda: abre el programa en el editor.
    func requestEdit(_ entry: ProgramEntry) async {
        await programs.open(entry)
        guard programs.document != nil else { return }
        showsEditor = true
    }

    /// Deslizar a la derecha: prepara el envio del programa deslizado.
    ///
    /// Carga el programa si no era el abierto y pide confirmacion. Si falta
    /// algo (maquina, puerto, cambios sin guardar) no se abre el dialogo: la
    /// barra de abajo ya dice exactamente que falta, y no tiene sentido
    /// confirmar un envio que no puede salir.
    func requestSend(_ entry: ProgramEntry) async {
        if programs.document?.path != entry.path {
            await programs.open(entry)
        }
        guard programs.document?.path == entry.path else { return }
        if canSend {
            showsSendConfirmation = true
        }
    }

    /// Manda el programa a la máquina elegida. En el flujo normal Zeuz Agent
    /// resuelve automáticamente la Orange Pi y su adaptador RS232.
    func send() {
        guard canSend,
              let document = programs.sendableDocument,
              let machine = machines.selected
        else { return }

        let endpoint: SerialEndpoint
        if agentSettings.isReady {
            endpoint = SerialEndpoint(name: agentSettings.settings.displayName, kind: .zeuzBridge)
        } else if let selected = endpoints.selected {
            endpoint = selected
        } else {
            return
        }

        // Mientras se transmite no queremos que el sondeo recargue la carpeta
        // ni compita por la red con el envio.
        programs.stopAutoRefresh()
        transfer.send(
            document: document,
            machine: machine,
            endpoint: endpoint,
            dncClient: dncClient
        )
    }

    func finishTransfer() {
        transfer.reset()
        programs.startAutoRefresh()
    }
}
