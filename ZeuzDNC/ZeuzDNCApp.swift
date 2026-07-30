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

    /// Se muestra la hoja de ajustes al abrir si todavia no hay share.
    var showsOnboarding: Bool {
        !agentSettings.isReady && !smbSettings.settings.isConfigured
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
            reasons.append("Conecta Zeuz Agent")
        }
        if programs.document == nil {
            reasons.append("Elige un programa")
        } else if programs.hasUnsavedChanges {
            reasons.append("Guarda los cambios antes de enviar")
        }
        if machines.selected == nil {
            reasons.append("Selecciona una maquina")
        }
        if endpoints.selected == nil {
            reasons.append("Selecciona un puerto")
        }
        return reasons
    }

    var canSend: Bool {
        blockers.isEmpty && !transfer.isSending
    }

    // MARK: - Sincronizacion de maquinas con la Pi

    /// Cliente del puente ZeuzDNC con el que sincronizar. Usa el puerto elegido
    /// si es un puente, y si no el primero que haya dado de alta: los perfiles
    /// de maquina son de la Pi aunque en este momento se este apuntando a otro
    /// puerto.
    var bridgeClient: ZeuzBridgeClient? {
        let endpoint = endpoints.selected.flatMap { $0.kind == .zeuzBridge ? $0 : nil }
            ?? endpoints.endpoints.first { $0.kind == .zeuzBridge }
        guard let endpoint, !endpoint.host.isEmpty else { return nil }
        return ZeuzBridgeClient(host: endpoint.host, port: endpoint.port)
    }

    /// Trae los perfiles de la Pi. Devuelve el mensaje de error, o nil si fue bien.
    func syncMachinesFromPi() async -> String? {
        guard let bridgeClient else {
            return "Da de alta un puerto \"Puente ZeuzDNC\" con la IP de la Raspberry Pi para sincronizar."
        }
        do {
            try await machines.syncFromPi(bridgeClient)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func connectIfPossible() async {
        if agentSettings.isReady {
            await programs.connect(
                agent: agentSettings.settings,
                token: agentSettings.token
            )
        } else if smbSettings.settings.isConfigured {
            await programs.connect(
                settings: smbSettings.settings,
                password: smbSettings.password
            )
        } else {
            return
        }
        // Al arrancar, dejamos los perfiles iguales a los de la Pi sin que haya
        // que acordarse de sincronizar a mano. Si la Pi no responde, se ignora:
        // no es motivo para bloquear la app.
        _ = await syncMachinesFromPi()
    }

    func reconnect() async {
        await programs.disconnect()
        await connectIfPossible()
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

    /// Manda el programa abierto a la maquina y puerto elegidos.
    func send() {
        guard canSend,
              let document = programs.sendableDocument,
              let machine = machines.selected,
              let endpoint = endpoints.selected
        else { return }

        // Mientras se transmite no queremos que el sondeo recargue la carpeta
        // ni compita por la red con el envio.
        programs.stopAutoRefresh()
        transfer.send(document: document, machine: machine, endpoint: endpoint)
    }

    func finishTransfer() {
        transfer.reset()
        programs.startAutoRefresh()
    }
}
