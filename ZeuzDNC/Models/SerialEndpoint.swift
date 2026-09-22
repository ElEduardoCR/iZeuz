import Foundation

/// Un "puerto" al que se puede enviar, con nombre personalizable.
///
/// En la Raspberry Pi un puerto era literalmente `/dev/ttyUSB0`. En iOS no
/// existe eso (el sistema no expone adaptadores USB-serial genericos), asi
/// que un puerto aqui es un *endpoint*: o un puerto fisico de un puente en
/// la red WiFi, o un cable MFi conectado al telefono.
///
/// Un puente con hub de varios USB se modela como varios endpoints con el
/// mismo host y distinto `bridgePort` — cada uno con su nombre ("Torno 1",
/// "Fresadora vieja", etc.).
struct SerialEndpoint: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    /// Nombre libre que ve el operador. Es lo unico que deberia importarle.
    var name: String
    var kind: Kind

    // MARK: Puente en red
    var host: String
    var port: Int
    /// RFC 2217: negocia baudrate/paridad/bits con el servidor serial en vez
    /// de depender de como quedo configurado el puente. Si el puente no lo
    /// soporta, se deja apagado y se configura el baudrate en el puente.
    var useRFC2217: Bool
    /// Puerto fisico dentro del puente cuando hay un hub (informativo, y lo
    /// usa el modo puente-ZeuzDNC para elegir a que `/dev/ttyUSBx` mandar).
    var bridgePort: String

    // MARK: Cable MFi
    /// Cadena de protocolo MFi declarada en Info.plist. Depende del cable;
    /// para los Redpark se configura desde ajustes.
    var accessoryProtocol: String
    /// Fija un accesorio concreto por numero de serie cuando hay mas de uno.
    var accessorySerialNumber: String?

    init(
        id: UUID = UUID(),
        name: String,
        kind: Kind = .networkBridge,
        host: String = "",
        port: Int = 4196,
        useRFC2217: Bool = false,
        bridgePort: String = "",
        accessoryProtocol: String = SerialEndpoint.redparkProtocol,
        accessorySerialNumber: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port
        self.useRFC2217 = useRFC2217
        self.bridgePort = bridgePort
        self.accessoryProtocol = accessoryProtocol
        self.accessorySerialNumber = accessorySerialNumber
    }
}

extension SerialEndpoint {
    /// Nombre estable publicado por cada Zeuz mediante Bonjour. La IP que
    /// entrega el router puede cambiar entre reinicios, pero el hostname del
    /// equipo se conserva (por ejemplo `zeuz-dnc-1b3b992.local`).
    var connectionHost: String {
        guard kind == .zeuzBridge else { return host }
        return Self.zeuzServiceHost(deviceName: name, fallback: host)
    }

    static func zeuzServiceHost(deviceName: String, fallback: String) -> String {
        let candidate = deviceName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let bare = candidate.hasSuffix(".local")
            ? String(candidate.dropLast(".local".count))
            : candidate
        let isZeuzHostname = (bare == "zeuz" || bare.hasPrefix("zeuz-dnc-"))
            && bare.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        return isZeuzHostname ? "\(bare).local" : fallback
    }

    enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
        /// Le delega el envio al ZeuzDNC que ya corre en la Raspberry Pi: el
        /// iPhone manda la orden por HTTP y la Pi saca el G-code por su propio
        /// cable serial, con el perfil de maquina que ella ya tiene. Es el modo
        /// para reusar una Pi que ya funciona, sin cable MFi ni tocar el puerto.
        case zeuzBridge
        /// TCP a un servidor serial en la WiFi (ser2net, ESP32, Moxa, USR).
        case networkBridge
        /// Cable serial certificado MFi conectado al telefono (Redpark).
        case mfiCable
        /// Simulado: no manda nada, sirve para probar la app sin hardware.
        case simulator

        var label: String {
            switch self {
            case .zeuzBridge: L10n.text("Dispositivo ZeuzDNC")
            case .networkBridge: L10n.text("Puente en red (WiFi)")
            case .mfiCable: L10n.text("Cable MFi (Redpark)")
            case .simulator: L10n.text("Simulador (sin hardware)")
            }
        }

        var icon: String {
            switch self {
            case .zeuzBridge: "server.rack"
            case .networkBridge: "wifi"
            case .mfiCable: "cable.connector"
            case .simulator: "testtube.2"
            }
        }

        /// Puerto TCP por defecto de cada tipo. El ZeuzDNC de la Pi sirve su
        /// API Flask en el 5000; un ser2net/Moxa suele exponer 4196/4001.
        var defaultPort: Int {
            switch self {
            case .zeuzBridge: 5000
            case .networkBridge, .mfiCable, .simulator: 4196
            }
        }
    }

    /// Cadena de protocolo por defecto de los cables serial Redpark.
    /// Verificala contra la documentacion del cable que compres: si no
    /// coincide con la declarada en Info.plist, iOS no abrira la sesion.
    static let redparkProtocol = "com.redpark.hobdb9"

    /// Descripcion corta del destino, para la lista de puertos.
    var destination: String {
        switch kind {
        case .zeuzBridge:
            let base = L10n.text("Vía Zeuz Agent")
            return bridgePort.isEmpty ? base : "\(base) → \(bridgePort)"
        case .networkBridge:
            let base = host.isEmpty ? L10n.text("sin host") : "\(host):\(port)"
            return bridgePort.isEmpty ? base : "\(base) → \(bridgePort)"
        case .mfiCable:
            return accessorySerialNumber.map { L10n.format("cable · %@", $0) }
                ?? L10n.text("cable conectado")
        case .simulator:
            return L10n.text("sin hardware")
        }
    }
}

/// Errores de validacion al dar de alta o editar un puerto.
enum EndpointValidationError: LocalizedError {
    case emptyName
    case emptyHost
    case invalidPort
    case emptyProtocol

    var errorDescription: String? {
        switch self {
        case .emptyName: L10n.text("El nombre del puerto es obligatorio")
        case .emptyHost: L10n.text("Escribe la direccion IP o el nombre del puente")
        case .invalidPort: L10n.text("El puerto TCP debe estar entre 1 y 65535")
        case .emptyProtocol: L10n.text("Falta la cadena de protocolo MFi del cable")
        }
    }
}

extension SerialEndpoint {
    func validated() throws -> SerialEndpoint {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.name.isEmpty else { throw EndpointValidationError.emptyName }

        switch kind {
        case .zeuzBridge:
            // ZeuzAgent localiza ZeuzDNC por Bonjour; el iPhone no necesita
            // conocer ni validar la IP del dispositivo.
            copy.host = ""
            copy.port = Kind.zeuzBridge.defaultPort
        case .networkBridge:
            copy.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !copy.host.isEmpty else { throw EndpointValidationError.emptyHost }
            guard (1...65535).contains(port) else { throw EndpointValidationError.invalidPort }
        case .mfiCable:
            copy.accessoryProtocol = accessoryProtocol.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !copy.accessoryProtocol.isEmpty else { throw EndpointValidationError.emptyProtocol }
        case .simulator:
            break
        }
        return copy
    }
}
