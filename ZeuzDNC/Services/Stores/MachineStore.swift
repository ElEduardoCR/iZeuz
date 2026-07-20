import Foundation

/// Alta, edicion y borrado de perfiles de maquina. Equivale a `machines.py`
/// y `config/machines.json` del proyecto de la Raspberry Pi.
@MainActor
@Observable
final class MachineStore {
    private(set) var machines: [Machine] = []
    var selectedID: String?

    private let store = JSONFileStore<[Machine]>(filename: "machines.json")
    private let selectionKey = "zeuzdnc.selectedMachineID"

    var selected: Machine? {
        guard let selectedID else { return nil }
        return machines.first { $0.id == selectedID }
    }

    init() {
        // La primera vez sembramos Fanuc y Fadal como referencia, igual que
        // la Pi. Son valores tipicos: hay que confirmarlos contra el manual
        // de cada control antes de usarlos en produccion.
        machines = store.load() ?? Machine.defaults
        selectedID = UserDefaults.standard.string(forKey: selectionKey)
        if selectedID != nil, selected == nil { selectedID = nil }
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

    func delete(_ machine: Machine) {
        machines.removeAll { $0.id == machine.id }
        // Si borramos la maquina activa, se limpia la seleccion para que no
        // quede un envio apuntando a un perfil que ya no existe.
        if selectedID == machine.id { select(nil) }
        persist()
    }

    func delete(at offsets: IndexSet) {
        let removed = offsets.map { machines[$0] }
        machines.remove(atOffsets: offsets)
        if let selectedID, removed.contains(where: { $0.id == selectedID }) { select(nil) }
        persist()
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
    }
}
