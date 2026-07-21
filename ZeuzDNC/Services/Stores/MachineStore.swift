import Foundation

/// Alta, edicion y borrado de perfiles de maquina. Equivale a `machines.py`
/// y `config/machines.json` del proyecto de la Raspberry Pi.
@MainActor
@Observable
final class MachineStore {
    private(set) var machines: [Machine] = []
    var selectedID: String?

    /// Maquinas que vienen del `machines.json` de la Raspberry Pi. Para esas, la
    /// **Pi manda**: al enviar por el puente es su perfil el que abre el puerto,
    /// asi que la app las espeja y empuja las ediciones de vuelta en vez de
    /// guardar una copia distinta que engañaria al operador.
    private(set) var piBackedIDs: Set<String> = []

    /// Cuando se sincronizo por ultima vez con la Pi.
    private(set) var lastSync: Date?

    private let store = JSONFileStore<[Machine]>(filename: "machines.json")
    private let selectionKey = "zeuzdnc.selectedMachineID"
    private let piBackedKey = "zeuzdnc.piBackedMachineIDs"

    func isPiBacked(_ machine: Machine) -> Bool { piBackedIDs.contains(machine.id) }

    var selected: Machine? {
        guard let selectedID else { return nil }
        return machines.first { $0.id == selectedID }
    }

    init() {
        // La primera vez sembramos Fanuc y Fadal como referencia. En cuanto se
        // sincroniza con una Pi, sus maquinas reales sustituyen a estas.
        machines = store.load() ?? Machine.defaults
        selectedID = UserDefaults.standard.string(forKey: selectionKey)
        if selectedID != nil, selected == nil { selectedID = nil }
        piBackedIDs = Set(UserDefaults.standard.stringArray(forKey: piBackedKey) ?? [])
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

    /// Borra el perfil **solo del telefono**. Si la maquina vive en la Pi, la
    /// siguiente sincronizacion la vuelve a traer: alla es donde se da de baja.
    func delete(_ machine: Machine) {
        machines.removeAll { $0.id == machine.id }
        piBackedIDs.remove(machine.id)
        // Si borramos la maquina activa, se limpia la seleccion para que no
        // quede un envio apuntando a un perfil que ya no existe.
        if selectedID == machine.id { select(nil) }
        persist()
    }

    func delete(at offsets: IndexSet) {
        let removed = offsets.map { machines[$0] }
        machines.remove(atOffsets: offsets)
        for machine in removed { piBackedIDs.remove(machine.id) }
        if let selectedID, removed.contains(where: { $0.id == selectedID }) { select(nil) }
        persist()
    }

    // MARK: - Sincronizacion con la Raspberry Pi

    /// Trae los perfiles de la Pi y deja los de la app identicos a los de ella.
    ///
    /// Fusiona por `id`: las maquinas de la Pi crean o pisan la copia local, y
    /// las que solo existen en el telefono (para un cable MFi o un ser2net, que
    /// si usan el perfil del iPhone) se respetan. Devuelve cuantas llegaron.
    ///
    /// Es lo que evita el enredo de tener 38400 7E1 en la Pi y 9600 8N1 en el
    /// telefono: al enviar por el puente manda la Pi, asi que mostrar otra cosa
    /// solo confunde.
    @discardableResult
    func syncFromPi(_ client: ZeuzBridgeClient) async throws -> Int {
        let piMachines = try await client.machines()

        for piMachine in piMachines {
            let machine = piMachine.asMachine
            if let index = machines.firstIndex(where: { $0.id == machine.id }) {
                machines[index] = machine
            } else {
                machines.append(machine)
            }
            piBackedIDs.insert(machine.id)
        }

        // Una maquina que ya no esta en la Pi deja de considerarse suya: se
        // queda como perfil local en vez de desaparecer sin avisar.
        let alive = Set(piMachines.map(\.id))
        piBackedIDs.formIntersection(alive)

        machines.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        lastSync = .now
        persist()
        return piMachines.count
    }

    /// Guarda el perfil en la Pi **y** en la app, para que no puedan divergir.
    /// Si la maquina aun no existe alla, la Pi la crea y adopta el id que asigne.
    @discardableResult
    func saveToPi(_ machine: Machine, using client: ZeuzBridgeClient) async throws -> Machine {
        let clean = try machine.validated()
        let isNew = !piBackedIDs.contains(clean.id)
        let saved = try await client.saveMachine(clean, isNew: isNew)

        if isNew {
            // La Pi le puso su propio slug: quitamos el registro con el id viejo
            // para no quedarnos con la maquina duplicada.
            machines.removeAll { $0.id == clean.id }
            if selectedID == clean.id { select(nil) }
        }
        try save(saved)
        piBackedIDs.insert(saved.id)
        persist()
        return saved
    }

    /// Importa perfiles del `machines.json` de la Raspberry Pi tal cual.
    func importFromPi(json data: Data) throws -> Int {
        struct PiFile: Decodable {
            struct PiMachine: Decodable {
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
            let machines: [PiMachine]
        }

        let file = try JSONDecoder().decode(PiFile.self, from: data)
        var imported = 0
        for piMachine in file.machines {
            let machine = Machine(
                id: piMachine.id,
                name: piMachine.name,
                baudRate: piMachine.baudrate,
                dataBits: piMachine.bytesize,
                parity: Machine.Parity(rawValue: piMachine.parity.uppercased()) ?? .none,
                stopBits: piMachine.stopbits,
                flowControl: Machine.FlowControl(rawValue: piMachine.flow_control.lowercased()) ?? .xonXoff,
                lineTerminator: Machine.LineTerminator(rawValue: piMachine.line_terminator.uppercased()) ?? .crlf,
                dtr: piMachine.dtr ?? false,
                rts: piMachine.rts ?? false,
                dripFeed: piMachine.dripfeed ?? false
            )
            if (try? save(machine)) != nil { imported += 1 }
        }
        return imported
    }

    private func persist() {
        store.save(machines)
        UserDefaults.standard.set(Array(piBackedIDs), forKey: piBackedKey)
    }
}
