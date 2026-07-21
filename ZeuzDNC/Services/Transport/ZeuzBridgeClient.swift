import Foundation

/// Cliente HTTP contra el ZeuzDNC que ya corre en la Raspberry Pi.
///
/// No saca bytes por serial: le **delega** el envio a la Pi por su API Flask
/// (la misma que usa su pantalla tactil). El iPhone empuja el programa y da la
/// orden; la Pi lo manda a la maquina con el perfil serial que ya tiene
/// cargado y probado. Por eso este modo no implementa `SerialTransport`.
struct ZeuzBridgeClient: Sendable {
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
            case id, name, baudrate, bytesize, parity, stopbits, dtr, rts, dripfeed
            case flowControl = "flow_control"
            case lineTerminator = "line_terminator"
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
                dripFeed: dripfeed ?? false
            )
        }
    }

    /// Cuerpo de `POST /api/machine/save`, con los nombres de campo de la Pi.
    /// Sin `id` la Pi crea la maquina y le asigna un slug nuevo.
    private struct PiMachinePayload: Encodable {
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
        let bytesSent: Int
        let totalBytes: Int
        let percent: Int
        let message: String

        enum CodingKeys: String, CodingKey {
            case status, filename, percent, message
            case bytesSent = "bytes_sent"
            case totalBytes = "total_bytes"
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

    func status() async throws -> PiTransfer {
        try await get("/api/transfer/status", as: PiTransfer.self)
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

    /// Empuja el contenido del programa a la carpeta de la Pi. Es idempotente:
    /// si la carpeta compartida ya es la de la Pi, reescribe el mismo archivo.
    func saveFile(path: String, content: String) async throws {
        try await post("/api/file/save", body: ["path": path, "content": content])
    }

    /// La orden que pediste: la Pi recibe esto y arranca el envio a la maquina.
    func send(path: String) async throws {
        try await post("/api/send", body: ["path": path])
    }

    func cancel() async {
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
            throw ZeuzBridgeError.rejected(ack.error ?? "La Pi rechazo la orden")
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
            "Direccion invalida del puente: \(host)"
        case .unreachable(let host, let detail):
            "No se pudo contactar la Raspberry Pi en \(host). ¿Esta encendida y en la "
                + "misma red WiFi? (\(detail))"
        case .badResponse:
            "La Raspberry Pi respondio algo inesperado. ¿Esta corriendo ZeuzDNC?"
        case .machineNotFound(let name):
            "La maquina \"\(name)\" no existe en la Raspberry Pi. Dala de alta en la Pi "
                + "con ese mismo nombre, o cambia el nombre en el iPhone para que coincida."
        case .rejected(let detail):
            detail
        }
    }
}
