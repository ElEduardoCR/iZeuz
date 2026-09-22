import Foundation

/// Copia local de los perfiles de maquina administrados por ZeuzDNC.
@MainActor
@Observable
final class MachineStore {
    private(set) var machines: [Machine] = []
    var selectedID: String?

    /// Maquinas compartidas entre el iPhone y ZeuzDNC.
    private(set) var zeuzBackedIDs: Set<String> = []

    /// Se activa solo mientras hay una diferencia pendiente de aplicar.
    private(set) var needsResync = false

    /// Cuando se sincronizo por ultima vez con ZeuzDNC.
    private(set) var lastSync: Date?

    private let store = JSONFileStore<[Machine]>(filename: "machines.json")
    private let selectionKey = "zeuzdnc.selectedMachineID"
    private let zeuzBackedKey = "zeuzdnc.zeuzBackedMachineIDs"
    private let legacyBackedKey = "zeuzdnc.piBackedMachineIDs"
    private let lastSyncKey = "zeuzdnc.lastMachineSync"

    func isZeuzBacked(_ machine: Machine) -> Bool { zeuzBackedIDs.contains(machine.id) }

    var selected: Machine? {
        guard let selectedID else { return nil }
        return machines.first { $0.id == selectedID }
    }

    init() {
        // La primera vez sembramos Fanuc y Fadal como referencia. La primera
        // sincronizacion los sustituye por los perfiles reales de ZeuzDNC.
        machines = store.load() ?? Machine.defaults
        selectedID = UserDefaults.standard.string(forKey: selectionKey)
        if selectedID != nil, selected == nil { selectedID = nil }
        let savedIDs = UserDefaults.standard.stringArray(forKey: zeuzBackedKey)
            ?? UserDefaults.standard.stringArray(forKey: legacyBackedKey)
            ?? []
        zeuzBackedIDs = Set(savedIDs)
        let timestamp = UserDefaults.standard.double(forKey: lastSyncKey)
        if timestamp > 0 { lastSync = Date(timeIntervalSince1970: timestamp) }
    }

    func select(_ machine: Machine?) {
        selectedID = machine?.id
        UserDefaults.standard.set(selectedID, forKey: selectionKey)
    }

    /// Crea o actualiza segun exista ya el id. Devuelve el perfil guardado.
    @discardableResult
    func save(_ machine: Machine) throws -> Machine {
        let clean = try machine.validated()
        if let index = machines.firstIndex(where: { $0.id == clean.id }) {
            machines[index] = clean
        } else {
            machines.append(clean)
        }
        machines.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persist()
        return clean
    }

    /// Adopta el perfil que la Orange Pi creó durante el alta inicial y lo
    /// deja seleccionado para el primer envío.
    @discardableResult
    func adoptProvisioned(_ machine: Machine) throws -> Machine {
        let saved = try save(machine)
        zeuzBackedIDs.insert(saved.id)
        select(saved)
        lastSync = .now
        needsResync = false
        persist()
        return saved
    }

    /// Borra una copia local. Para máquinas sincronizadas debe llamarse después
    /// de que ZeuzDNC haya confirmado el borrado remoto.
    func delete(_ machine: Machine) {
        machines.removeAll { $0.id == machine.id }
        zeuzBackedIDs.remove(machine.id)
        // Si borramos la maquina activa, se limpia la seleccion para que no
        // quede un envio apuntando a un perfil que ya no existe.
        if selectedID == machine.id { select(nil) }
        persist()
    }

    func delete(at offsets: IndexSet) {
        let removed = offsets.map { machines[$0] }
        machines.remove(atOffsets: offsets)
        for machine in removed { zeuzBackedIDs.remove(machine.id) }
        if let selectedID, removed.contains(where: { $0.id == selectedID }) { select(nil) }
        persist()
    }

    // MARK: - Sincronizacion bidireccional con ZeuzDNC

    /// Sustituye la copia del iPhone por la lista completa de ZeuzDNC.
    @discardableResult
    func syncFromZeuzDNC(_ client: any ZeuzDNCClient) async throws -> Int {
        let remote = try await client.machines()
        machines = sorted(remote.map(\.asMachine))
        zeuzBackedIDs = Set(machines.map(\.id))
        if let selectedID, !zeuzBackedIDs.contains(selectedID) { select(nil) }
        lastSync = .now
        needsResync = false
        persist()
        return machines.count
    }

    /// Trae automáticamente los cambios hechos desde la pantalla de ZeuzDNC.
    @discardableResult
    func syncFromZeuzDNCIfChanged(_ client: any ZeuzDNCClient) async throws -> Bool {
        let fetched = try await client.machines()
        let remote = sorted(fetched.map(\.asMachine))
        guard remote != sorted(machines) else {
            needsResync = false
            return false
        }
        needsResync = true
        machines = remote
        zeuzBackedIDs = Set(remote.map(\.id))
        if let selectedID, !zeuzBackedIDs.contains(selectedID) { select(nil) }
        lastSync = .now
        needsResync = false
        persist()
        return true
    }

    /// Compatibilidad para altas administradas: guarda primero en ZeuzDNC.
    @discardableResult
    func saveToZeuzDNC(_ machine: Machine, using client: any ZeuzDNCClient) async throws -> Machine {
        let clean = try machine.validated()
        let isNew = !zeuzBackedIDs.contains(clean.id)
        let saved = try await client.saveMachine(clean, isNew: isNew)

        if isNew {
            // ZeuzDNC asigno su slug: quitamos el registro con el id viejo
            // para no quedarnos con la maquina duplicada.
            machines.removeAll { $0.id == clean.id }
            if selectedID == clean.id { select(nil) }
        }
        try save(saved)
        zeuzBackedIDs.insert(saved.id)
        lastSync = .now
        needsResync = false
        persist()
        return saved
    }

    /// Elimina primero en ZeuzDNC y sólo después quita la copia del iPhone.
    func deleteFromZeuzDNC(_ machine: Machine, using client: any ZeuzDNCClient) async throws {
        try await client.deleteMachine(id: machine.id)
        delete(machine)
        lastSync = .now
        needsResync = false
        persist()
    }

    /// Importa perfiles exportados por ZeuzDNC tal cual.
    func importFromZeuzDNC(json data: Data) throws -> Int {
        struct ZeuzFile: Decodable {
            struct ZeuzMachine: Decodable {
                let id: String
                let name: String
                let baudrate: Int
                let bytesize: Int
                let parity: String
                let stopbits: Int
                let flow_control: String
                let line_terminator: String
                let dtr: Bool?
                let rts: Bool?
                let dripfeed: Bool?
            }
            let machines: [ZeuzMachine]
        }

        let file = try JSONDecoder().decode(ZeuzFile.self, from: data)
        var imported = 0
        for zeuzMachine in file.machines {
            let machine = Machine(
                id: zeuzMachine.id,
                name: zeuzMachine.name,
                baudRate: zeuzMachine.baudrate,
                dataBits: zeuzMachine.bytesize,
                parity: Machine.Parity(rawValue: zeuzMachine.parity.uppercased()) ?? .none,
                stopBits: zeuzMachine.stopbits,
                flowControl: Machine.FlowControl(rawValue: zeuzMachine.flow_control.lowercased()) ?? .xonXoff,
                lineTerminator: Machine.LineTerminator(rawValue: zeuzMachine.line_terminator.uppercased()) ?? .crlf,
                dtr: zeuzMachine.dtr ?? false,
                rts: zeuzMachine.rts ?? false,
                dripFeed: zeuzMachine.dripfeed ?? false
            )
            if (try? save(machine)) != nil { imported += 1 }
        }
        return imported
    }

    private func persist() {
        store.save(machines)
        UserDefaults.standard.set(Array(zeuzBackedIDs), forKey: zeuzBackedKey)
        if let lastSync {
            UserDefaults.standard.set(lastSync.timeIntervalSince1970, forKey: lastSyncKey)
        }
    }

    private func sorted(_ values: [Machine]) -> [Machine] {
        values.sorted {
            let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
            return nameOrder == .orderedSame ? $0.id < $1.id : nameOrder == .orderedAscending
        }
    }
}
