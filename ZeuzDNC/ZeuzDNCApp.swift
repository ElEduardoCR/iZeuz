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

    /// Se muestra la hoja de ajustes al abrir si todavia no hay share.
    var showsOnboarding: Bool { !smbSettings.settings.isConfigured }

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
            reasons.append("Conecta la carpeta compartida")
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

    func connectIfPossible() async {
        guard smbSettings.settings.isConfigured else { return }
        await programs.connect(
            settings: smbSettings.settings,
            password: smbSettings.password
        )
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
