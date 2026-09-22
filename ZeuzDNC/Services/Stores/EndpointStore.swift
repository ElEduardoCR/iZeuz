import Foundation
#if canImport(ExternalAccessory)
import ExternalAccessory
#endif

/// Alta, edicion y borrado de puertos, con nombre libre.
///
/// Reemplaza al `usb_monitor.py` de la Pi: alla los puertos aparecian solos
/// al conectar el adaptador; aqui se dan de alta a mano porque un endpoint de
/// red no se puede "detectar" igual. A cambio, cada puerto tiene el nombre
/// que quiera el taller ("Torno chico", "Fresadora del fondo").
@MainActor
@Observable
final class EndpointStore {
    private(set) var endpoints: [SerialEndpoint] = []
    var selectedID: UUID?

    /// Cables MFi que iOS reporta conectados ahora mismo.
    private(set) var connectedAccessories: [ConnectedAccessory] = []

    private let store = JSONFileStore<[SerialEndpoint]>(filename: "endpoints.json")
    private let selectionKey = "zeuzdnc.selectedEndpointID"

    struct ConnectedAccessory: Identifiable, Hashable, Sendable {
        var id: String { serialNumber.isEmpty ? name : serialNumber }
        var name: String
        var serialNumber: String
        var protocolStrings: [String]
    }

    var selected: SerialEndpoint? {
        guard let selectedID else { return nil }
        return endpoints.first { $0.id == selectedID }
    }

    init() {
        endpoints = store.load() ?? []
        // Las primeras versiones guardaban la IP asignada durante el alta.
        // Si el router entregaba otra al reiniciar, la app seguia llamando a
        // la direccion vieja. Los equipos creados por la imagen Zeuz traen su
        // hostname unico en el nombre; migramos esos registros a Bonjour.
        var migrated = false
        for index in endpoints.indices where endpoints[index].kind == .zeuzBridge {
            let stableHost = endpoints[index].connectionHost
            if !stableHost.isEmpty, stableHost != endpoints[index].host {
                endpoints[index].host = stableHost
                migrated = true
            }
        }
        if migrated { persist() }
        if let raw = UserDefaults.standard.string(forKey: selectionKey) {
            selectedID = UUID(uuidString: raw)
        }
        if selectedID != nil, selected == nil { selectedID = nil }
        refreshAccessories()
    }

    func select(_ endpoint: SerialEndpoint?) {
        selectedID = endpoint?.id
        UserDefaults.standard.set(selectedID?.uuidString, forKey: selectionKey)
    }

    @discardableResult
    func save(_ endpoint: SerialEndpoint) throws -> SerialEndpoint {
        let clean = try endpoint.validated()
        if let index = endpoints.firstIndex(where: { $0.id == clean.id }) {
            endpoints[index] = clean
        } else {
            endpoints.append(clean)
        }
        persist()
        return clean
    }

    func delete(_ endpoint: SerialEndpoint) {
        endpoints.removeAll { $0.id == endpoint.id }
        if selectedID == endpoint.id { select(nil) }
        persist()
    }

    func delete(at offsets: IndexSet) {
        let removed = offsets.map { endpoints[$0] }
        endpoints.remove(atOffsets: offsets)
        if let selectedID, removed.contains(where: { $0.id == selectedID }) { select(nil) }
        persist()
    }

    @discardableResult
    func upsertZeuzBridge(name: String, host: String, port: Int = 5000) throws -> SerialEndpoint {
        let stableHost = SerialEndpoint.zeuzServiceHost(deviceName: name, fallback: host)
        var endpoint = endpoints.first(where: {
            $0.kind == .zeuzBridge && ($0.connectionHost == stableHost || $0.name == name)
        }) ?? SerialEndpoint(name: name, kind: .zeuzBridge)
        endpoint.name = name
        endpoint.host = stableHost
        endpoint.port = port
        let saved = try save(endpoint)
        select(saved)
        return saved
    }

    func move(from source: IndexSet, to destination: Int) {
        endpoints.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    /// Estado de conexion de un puerto, para el semaforo de la interfaz.
    /// Un puente en red no se puede saber sin intentar conectar, asi que se
    /// reporta como "por verificar" en vez de mentir con un verde.
    func availability(of endpoint: SerialEndpoint) -> Availability {
        switch endpoint.kind {
        case .simulator:
            return .ready
        case .zeuzBridge, .networkBridge:
            return endpoint.host.isEmpty ? .notConfigured : .unknown
        case .mfiCable:
            let matches = connectedAccessories.contains { accessory in
                guard accessory.protocolStrings.contains(endpoint.accessoryProtocol) else { return false }
                guard let serial = endpoint.accessorySerialNumber, !serial.isEmpty else { return true }
                return accessory.serialNumber == serial
            }
            return matches ? .ready : .disconnected
        }
    }

    enum Availability: Sendable {
        case ready
        case unknown
        case disconnected
        case notConfigured

        var label: String {
            switch self {
            case .ready: L10n.text("Conectado")
            case .unknown: L10n.text("Se verifica al enviar")
            case .disconnected: L10n.text("Cable no conectado")
            case .notConfigured: L10n.text("Sin configurar")
            }
        }
    }

    func refreshAccessories() {
        #if canImport(ExternalAccessory)
        connectedAccessories = EAAccessoryManager.shared().connectedAccessories.map {
            ConnectedAccessory(
                name: $0.name,
                serialNumber: $0.serialNumber,
                protocolStrings: $0.protocolStrings
            )
        }
        #endif
    }

    /// Crea de golpe varios puertos para un puente con hub de varios USB.
    /// Cada uno queda con su nombre y su `/dev/ttyUSBx`.
    func addBridgePorts(host: String, basePort: Int, count: Int, namePrefix: String) throws {
        for index in 0..<count {
            let endpoint = SerialEndpoint(
                name: "\(namePrefix) \(index + 1)",
                kind: .networkBridge,
                host: host,
                // Los servidores serial multipuerto exponen un TCP por puerto
                // fisico, consecutivos desde el base (Moxa: 4001, 4002…).
                port: basePort + index,
                bridgePort: "/dev/ttyUSB\(index)"
            )
            try save(endpoint)
        }
    }

    private func persist() {
        store.save(endpoints)
    }
}
