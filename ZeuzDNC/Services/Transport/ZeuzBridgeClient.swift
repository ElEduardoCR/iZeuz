import Foundation

/// Operaciones autoritativas de ZeuzDNC. En operacion normal la implementa
/// ZeuzAgent para que el iPhone use una sola conexion; el cliente directo se
/// conserva exclusivamente para el emparejamiento inicial.
protocol ZeuzDNCClient: Sendable {
    func update(machineID: String, action: String, revision: String?, requestID: String?, autoInstall: Bool?) async throws -> ZeuzUpdateState
    func machines() async throws -> [ZeuzBridgeClient.PiMachine]
    func status(machineID: String?) async throws -> ZeuzBridgeClient.PiTransfer
    func selectDevice(path: String) async throws
    func selectMachine(id: String) async throws
    func saveMachine(_ machine: Machine, isNew: Bool) async throws -> Machine
    func deleteMachine(id: String) async throws
    func send(path: String, machineID: String?) async throws
    func cancel(machineID: String?) async
}

struct ZeuzUpdateState: Decodable, Sendable {
    var supported: Bool?
    var available: Bool?
    var phase: String?
    var current_version: String?
    var latest_version: String?
    var latest_revision: String?
    var auto_install: Bool?
    var error: String?
    var downloaded_bytes: Int?

    var isBusy: Bool { ["checking", "waiting_idle", "downloading", "installing", "restarting"].contains(phase ?? "") }
    var label: String {
        switch phase {
        case "checking": "Buscando actualizaciones…"
        case "available": "Actualización disponible"
        case "waiting_idle": "Esperando a que termine el envío"
        case "downloading": "Descargando actualización…"
        case "installing": "Instalando actualización…"
        case "restarting": "Reconectando el equipo…"
        case "succeeded": "Actualización completada"
        case "rolled_back": "Se restauró la versión anterior"
        case "failed": "Actualización fallida"
        case "unsupported": "Requiere firmware compatible con actualización remota"
        default: "Firmware al día"
        }
    }
}

extension ZeuzDNCClient {
    func update(machineID: String, action: String) async throws -> ZeuzUpdateState {
        try await update(machineID: machineID, action: action, revision: nil, requestID: nil, autoInstall: nil)
    }

    func update(machineID: String, action: String, revision: String?, requestID: String?, autoInstall: Bool?) async throws -> ZeuzUpdateState {
        if action == "status" { return ZeuzUpdateState(supported: false, phase: "unsupported") }
        throw NSError(domain: "ZeuzUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: "Este cliente no admite actualización remota"])
    }
}

/// Cliente HTTP contra el ZeuzDNC que ya corre en la Raspberry Pi.
///
/// No saca bytes por serial: le **delega** el envio a la Pi por su API Flask
/// (la misma que usa su pantalla tactil). El iPhone empuja el programa y da la
/// orden; la Pi lo manda a la maquina con el perfil serial que ya tiene
/// cargado y probado. Por eso este modo no implementa `SerialTransport`.
struct ZeuzBridgeClient: ZeuzDNCClient, Sendable {
    let host: String
    let port: Int

    private var base: URL? {
        // El host puede venir como IP (192.168.1.50) o nombre (zeuz.local).
        URL(string: "http://\(host):\(port)")
    }

    // MARK: - Respuestas de la Pi

    /// Perfil de maquina tal como lo guarda la Pi (`config/machines.json`).
    ///
    /// La Pi es la **fuente de verdad**: es su perfil el que abre el puerto
    /// serial al enviar. El iPhone lo espeja para mostrar los valores reales y
    /// no engañar al operador con una config distinta a la que se va a usar.
    struct PiMachine: Decodable, Sendable {
        let id: String
        let name: String
        /// Destino asignado por Zeuz Agent. Una Pi directa no incluye estos
        /// campos; por eso son opcionales en el contrato compartido.
        let revision: Int?
        let dncHost: String?
        let dncPort: Int?
        let baudrate: Int
        let bytesize: Int
        let parity: String
        let stopbits: Int
        let flowControl: String
        let lineTerminator: String
        let dtr: Bool?
        let rts: Bool?
        let dripfeed: Bool?

        enum CodingKeys: String, CodingKey {
            case id, revision, name, baudrate, bytesize, parity, stopbits, dtr, rts, dripfeed
            case dncHost = "dnc_host"
            case dncPort = "dnc_port"
            case flowControl = "flow_control"
            case lineTerminator = "line_terminator"
        }

        init(
            id: String,
            name: String,
            revision: Int? = nil,
            dncHost: String? = nil,
            dncPort: Int? = nil,
            baudrate: Int,
            bytesize: Int,
            parity: String,
            stopbits: Int,
            flowControl: String,
            lineTerminator: String,
            dtr: Bool? = nil,
            rts: Bool? = nil,
            dripfeed: Bool? = nil
        ) {
            self.id = id
            self.revision = revision
            self.name = name
            self.dncHost = dncHost
            self.dncPort = dncPort
            self.baudrate = baudrate
            self.bytesize = bytesize
            self.parity = parity
            self.stopbits = stopbits
            self.flowControl = flowControl
            self.lineTerminator = lineTerminator
            self.dtr = dtr
            self.rts = rts
            self.dripfeed = dripfeed
        }

        /// Traduce el perfil de la Pi al modelo de la app. Los valores que la
        /// app no reconozca caen en el default en vez de tirar la sincronizacion
        /// entera por una maquina rara.
        var asMachine: Machine {
            Machine(
                id: id,
                name: name,
                baudRate: baudrate,
                dataBits: bytesize,
                parity: Machine.Parity(rawValue: parity.uppercased()) ?? .none,
                stopBits: stopbits,
                flowControl: Machine.FlowControl(rawValue: flowControl.lowercased()) ?? .xonXoff,
                lineTerminator: Machine.LineTerminator(rawValue: lineTerminator.uppercased()) ?? .crlf,
                dtr: dtr ?? false,
                rts: rts ?? false,
                dripFeed: dripfeed ?? false,
                revision: revision ?? 0
            )
        }
    }

    /// Cuerpo de `POST /api/machine/save`, con los nombres de campo de la Pi.
    /// Sin `id` la Pi crea la maquina y le asigna un slug nuevo.
    private struct PiMachinePayload: Encodable {
        let revision: Int?
        let id: String?
        let name: String
        let baudrate: Int
        let bytesize: Int
        let parity: String
        let stopbits: Int
        let flow_control: String
        let line_terminator: String
        let dtr: Bool
        let rts: Bool
        let dripfeed: Bool

        init(_ machine: Machine, includeID: Bool) {
            self.revision = machine.revision
            self.id = includeID ? machine.id : nil
            self.name = machine.name
            self.baudrate = machine.baudRate
            self.bytesize = machine.dataBits
            self.parity = machine.parity.rawValue
            self.stopbits = machine.stopBits
            self.flow_control = machine.flowControl.rawValue
            self.line_terminator = machine.lineTerminator.rawValue
            self.dtr = machine.dtr
            self.rts = machine.rts
            self.dripfeed = machine.dripFeed
        }
    }

    private struct SavedMachineResponse: Decodable {
        let ok: Bool?
        let error: String?
        let machine: PiMachine?
    }

    /// Estado de la transferencia que reporta la Pi (`GET /api/transfer/status`).
    struct PiTransfer: Decodable, Sendable {
        let status: String            // idle | sending | success | error | cancelled
        let filename: String?
        let machine: String?
        let bytesSent: Int
        let totalBytes: Int
        let percent: Int
        let message: String

        enum CodingKeys: String, CodingKey {
            case status, filename, machine, percent, message
            case bytesSent = "bytes_sent"
            case totalBytes = "total_bytes"
        }

        init(
            status: String,
            filename: String?,
            machine: String? = nil,
            bytesSent: Int,
            totalBytes: Int,
            percent: Int,
            message: String
        ) {
            self.status = status
            self.filename = filename
            self.machine = machine
            self.bytesSent = bytesSent
            self.totalBytes = totalBytes
            self.percent = percent
            self.message = message
        }
    }

    /// Sobre comun de las rutas que solo confirman: `{ "ok": bool, "error"? }`.
    private struct Ack: Decodable {
        let ok: Bool?
        let error: String?
    }

    // MARK: - Lectura

    /// Maquinas dadas de alta en la Pi, para emparejar por nombre.
    func machines() async throws -> [PiMachine] {
        try await get("/api/machines", as: [PiMachine].self)
    }

    func status(machineID: String? = nil) async throws -> PiTransfer {
        try await get("/api/transfer/status", as: PiTransfer.self)
    }

    func pairAgent(url: String, code: String) async throws {
        try await post("/api/agent/pair", body: ["url": url, "code": code])
    }

    // MARK: - Ordenes

    /// Elige el puerto serial fisico de la Pi (`/dev/ttyUSBx`). Solo hace falta
    /// cuando la Pi tiene varios adaptadores; con uno solo, ella lo elige sola.
    func selectDevice(path: String) async throws {
        try await post("/api/device/select", body: ["path": path])
    }

    func selectMachine(id: String) async throws {
        try await post("/api/machine/select", body: ["id": id])
    }

    /// Guarda un perfil en la Pi. Con `isNew` la Pi lo crea y devuelve el perfil
    /// ya con el slug que le asigno, para que la app adopte ese mismo id y las
    /// dos queden apuntando a la misma maquina.
    @discardableResult
    func saveMachine(_ machine: Machine, isNew: Bool = false) async throws -> Machine {
        let data = try await postRaw(
            "/api/machine/save",
            body: PiMachinePayload(machine, includeID: !isNew)
        )
        guard let saved = try? JSONDecoder().decode(SavedMachineResponse.self, from: data),
              let piMachine = saved.machine
        else {
            throw ZeuzBridgeError.badResponse
        }
        return piMachine.asMachine
    }

    func deleteMachine(id: String) async throws {
        try await post("/api/machine/delete", body: ["id": id])
    }

    /// Empuja el contenido del programa a la carpeta de la Pi. Es idempotente:
    /// si la carpeta compartida ya es la de la Pi, reescribe el mismo archivo.
    func saveFile(path: String, content: String) async throws {
        try await post("/api/file/save", body: ["path": path, "content": content])
    }

    /// La orden que pediste: la Pi recibe esto y arranca el envio a la maquina.
    func send(path: String, machineID: String? = nil) async throws {
        try await post("/api/send", body: ["path": path])
    }

    func cancel(machineID: String? = nil) async {
        // Best-effort: si ya termino o la red se cayo, no hay nada que rescatar.
        try? await post("/api/send/cancel", body: [String: String]())
    }

    // MARK: - Transporte HTTP

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        guard let base, let url = URL(string: path, relativeTo: base) else {
            throw ZeuzBridgeError.badAddress(host)
        }
        let data = try await data(for: URLRequest(url: url))
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ZeuzBridgeError.badResponse
        }
    }

    private func post<Body: Encodable>(_ path: String, body: Body) async throws {
        _ = try await postRaw(path, body: body)
    }

    /// POST que devuelve el cuerpo de la respuesta, para las rutas que traen
    /// datos de vuelta (como `machine/save`).
    @discardableResult
    private func postRaw<Body: Encodable>(_ path: String, body: Body) async throws -> Data {
        guard let base, let url = URL(string: path, relativeTo: base) else {
            throw ZeuzBridgeError.badAddress(host)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let data = try await data(for: request)
        // La Pi contesta 4xx/409 con {ok:false, error} en el cuerpo; URLSession
        // no lo trata como error, asi que el veredicto sale del propio JSON.
        if let ack = try? JSONDecoder().decode(Ack.self, from: data), ack.ok == false {
            throw ZeuzBridgeError.rejected(
                ack.error ?? L10n.text("ZeuzDNC rechazó la orden")
            )
        }
        return data
    }

    /// Envuelve `URLSession` para traducir un fallo de red a un error entendible
    /// ("no se pudo contactar la Pi") en vez del texto crudo del sistema.
    private func data(for request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = 10
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return data
        } catch let error as URLError {
            throw ZeuzBridgeError.unreachable(host, error.localizedDescription)
        }
    }
}

enum ZeuzBridgeError: LocalizedError, Sendable {
    case badAddress(String)
    case unreachable(String, String)
    case badResponse
    case machineNotFound(String)
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .badAddress(let host):
            L10n.format("Direccion invalida del puente: %@", host)
        case .unreachable(let host, let detail):
            L10n.format(
                "No se pudo contactar ZeuzDNC en %1$@. ¿Está encendido y en la misma red Wi-Fi? (%2$@)",
                host,
                detail
            )
        case .badResponse:
            L10n.text("ZeuzDNC respondió algo inesperado. ¿Está ejecutándose el servicio?")
        case .machineNotFound(let name):
            L10n.format(
                "La máquina \"%@\" no existe en ZeuzDNC. Agrégala en ZeuzDNC y vuelve a sincronizar.",
                name
            )
        case .rejected(let detail):
            detail
        }
    }
}
