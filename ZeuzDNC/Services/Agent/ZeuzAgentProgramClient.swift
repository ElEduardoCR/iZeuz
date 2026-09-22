import Foundation

/// Cliente nativo del contrato HTTP v1 de Zeuz Agent.
actor ZeuzAgentProgramClient: ProgramClient, ZeuzDNCClient {
    private let settings: ZeuzAgentSettings
    private let token: String
    private var activeURL: String
    private var fallbackKey: String { "zeuz.workshop.fallback:" + settings.normalizedURL }
    private var activeKey: String { "zeuz.workshop.active:" + settings.normalizedURL }

    init(settings: ZeuzAgentSettings, token: String) {
        self.settings = settings
        self.token = token
        let fallback = UserDefaults.standard.string(forKey: "zeuz.workshop.fallback:" + settings.normalizedURL)
        let active = UserDefaults.standard.string(forKey: "zeuz.workshop.active:" + settings.normalizedURL)
        self.activeURL = active == fallback ? (fallback ?? settings.normalizedURL) : settings.normalizedURL
    }

    static func pair(baseURL: String, code: String) async throws -> PairResult {
        let candidate = ZeuzAgentSettings(baseURL: baseURL)
        let cleanCode = code.filter(\.isNumber)
        guard candidate.isConfigured,
              let url = URL(string: candidate.normalizedURL + "/v1/pair") else {
            throw ZeuzAgentError.invalidAddress
        }
        guard cleanCode.count == 6 else {
            throw ZeuzAgentError.invalidPairingCode
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(PairBody(code: cleanCode))
        let data = try await Self.data(for: request)
        do {
            return try JSONDecoder().decode(PairResult.self, from: data)
        } catch {
            throw ZeuzAgentError.badResponse
        }
    }

    func checkConnection() async throws {
        _ = try await request("GET", "/v1/programs?path=", as: AgentListing.self)
        if activeURL == settings.normalizedURL,
           let workshop = try? await request("GET", "/v1/workshop", as: WorkshopConnection.self),
           !workshop.server_url.isEmpty {
            UserDefaults.standard.set(workshop.server_url, forKey: fallbackKey)
        }
    }

    func disconnect() async {}

    func list(path: String) async throws -> DirectoryListing {
        let listing = try await request(
            "GET",
            "/v1/programs?path=\(escaped(path))",
            as: AgentListing.self
        )
        let entries = listing.entries.map(\.programEntry)
        return DirectoryListing(
            path: listing.path,
            breadcrumb: SMBPath.breadcrumb(for: listing.path),
            directories: entries.filter(\.isDirectory),
            files: entries.filter { !$0.isDirectory }
        )
    }

    func search(query: String, limit: Int = 300) async throws -> [ProgramEntry] {
        let result = try await request(
            "GET",
            "/v1/programs/search?q=\(escaped(query))",
            as: SearchResponse.self
        )
        return Array(result.results.prefix(limit)).map(\.programEntry)
    }

    func read(path: String) async throws -> ProgramDocument {
        let document = try await request(
            "GET",
            "/v1/programs/content?path=\(escaped(path))",
            as: AgentDocument.self
        )
        return ProgramDocument(
            path: document.path,
            name: document.name,
            content: document.content,
            truncated: document.truncated
        )
    }

    func write(path: String, content: String) async throws {
        _ = try await request(
            "PUT",
            "/v1/programs/content",
            body: WriteBody(path: path, content: content),
            as: Ack.self
        )
    }

    func createFile(directory: String, name: String) async throws -> String {
        let result = try await request(
            "POST",
            "/v1/programs",
            body: CreateBody(directory: directory, name: name, kind: "file"),
            as: CreateResult.self
        )
        return result.path
    }

    func createDirectory(parent: String, name: String) async throws -> String {
        let result = try await request(
            "POST",
            "/v1/programs",
            body: CreateBody(directory: parent, name: name, kind: "directory"),
            as: CreateResult.self
        )
        return result.path
    }

    func delete(path: String) async throws {
        _ = try await request(
            "DELETE",
            "/v1/programs/content?path=\(escaped(path))",
            as: Ack.self
        )
    }

    func fingerprint(path: String) async -> String {
        guard let value = try? await request(
            "GET",
            "/v1/changes?since=0",
            as: ChangeResponse.self
        ) else { return "" }
        if activeURL == settings.normalizedURL,
           let workshop = try? await request("GET", "/v1/workshop", as: WorkshopConnection.self),
           !workshop.server_url.isEmpty {
            UserDefaults.standard.set(workshop.server_url, forKey: fallbackKey)
        }
        return String(value.version)
    }

    // MARK: ZeuzDNC a traves de ZeuzAgent

    func machines() async throws -> [ZeuzBridgeClient.PiMachine] {
        try await request("GET", "/v1/dnc/machines", as: [ZeuzBridgeClient.PiMachine].self)
    }

    func status(machineID: String? = nil) async throws -> ZeuzBridgeClient.PiTransfer {
        let suffix = machineID.map { "?machine_id=\(escaped($0))" } ?? ""
        return try await request(
            "GET", "/v1/dnc/transfer/status\(suffix)", as: ZeuzBridgeClient.PiTransfer.self
        )
    }

    func update(machineID: String, action: String, revision: String? = nil, requestID: String? = nil, autoInstall: Bool? = nil) async throws -> ZeuzUpdateState {
        if action == "status" {
            return try await request("GET", "/v1/dnc/update/status?machine_id=\(escaped(machineID))", as: ZeuzUpdateState.self)
        }
        return try await request("POST", "/v1/dnc/update/\(action)",
            body: UpdateBody(machine_id: machineID, revision: revision, request_id: requestID, auto_install: autoInstall), as: ZeuzUpdateState.self)
    }

    private struct UpdateBody: Encodable {
        let machine_id: String
        let revision: String?
        let request_id: String?
        let auto_install: Bool?
    }

    func selectDevice(path: String) async throws {
        _ = try await request(
            "POST", "/v1/dnc/device/select", body: ["path": path], as: Ack.self
        )
    }

    func selectMachine(id: String) async throws {
        _ = try await request(
            "POST", "/v1/dnc/machine/select", body: ["id": id], as: Ack.self
        )
    }

    func saveMachine(_ machine: Machine, isNew: Bool = false) async throws -> Machine {
        let response = try await request(
            "POST",
            "/v1/dnc/machine/save",
            body: DNCMachinePayload(machine, includeID: !isNew),
            as: SavedDNCMachine.self
        )
        guard let saved = response.machine else { throw ZeuzAgentError.badResponse }
        return saved.asMachine
    }

    /// Registra el perfil creado durante el alta y lo asocia con la Orange Pi
    /// que acaba de entrar a la red.
    func saveProvisionedMachine(
        _ machine: Machine,
        dncHost: String,
        dncPort: Int
    ) async throws -> Machine {
        let response = try await request(
            "POST",
            "/v1/dnc/machine/save",
            body: ProvisionedDNCMachinePayload(machine, dncHost: dncHost, dncPort: dncPort),
            as: SavedDNCMachine.self
        )
        guard let saved = response.machine else { throw ZeuzAgentError.badResponse }
        return saved.asMachine
    }

    func deleteMachine(id: String) async throws {
        _ = try await request(
            "POST", "/v1/dnc/machine/delete", body: ["id": id], as: Ack.self
        )
    }

    func send(path: String, machineID: String? = nil) async throws {
        _ = try await request(
            "POST",
            "/v1/dnc/send",
            body: ["path": path, "machine_id": machineID ?? ""],
            as: Ack.self
        )
    }

    func cancel(machineID: String? = nil) async {
        _ = try? await request(
            "POST",
            "/v1/dnc/send/cancel",
            body: ["machine_id": machineID ?? ""],
            as: Ack.self
        )
    }

    // MARK: Transporte

    private func escaped(_ value: String) -> String {
        let allowed = CharacterSet.urlQueryAllowed
            .subtracting(CharacterSet(charactersIn: "&+="))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private func request<Response: Decodable>(
        _ method: String,
        _ path: String,
        as type: Response.Type
    ) async throws -> Response {
        try await request(method, path, body: Optional<EmptyBody>.none, as: type)
    }

    private func request<Body: Encodable, Response: Decodable>(
        _ method: String,
        _ path: String,
        body: Body?,
        as type: Response.Type
    ) async throws -> Response {
        guard let url = URL(string: activeURL + path) else {
            throw ZeuzAgentError.invalidAddress
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let data: Data
        do {
            data = try await Self.data(for: request)
        } catch ZeuzAgentError.unreachable {
            // Only retry reads. A timed-out write/send may already have reached
            // the CNC; the next operation can use the confirmed Pi connection.
            guard activeURL == settings.normalizedURL,
                  let fallback = UserDefaults.standard.string(forKey: fallbackKey),
                  let probeURL = URL(string: fallback + "/v1/programs?path=") else { throw ZeuzAgentError.unreachable("No se pudo contactar el taller") }
            var probe = URLRequest(url: probeURL)
            probe.timeoutInterval = 5
            probe.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            _ = try await Self.data(for: probe)
            activeURL = fallback
            UserDefaults.standard.set(fallback, forKey: activeKey)
            guard method == "GET" else {
                throw ZeuzAgentError.unreachable("La conexión cambió al servidor del taller. Revisa el estado antes de repetir la operación.")
            }
            request.url = URL(string: fallback + path)
            data = try await Self.data(for: request)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ZeuzAgentError.badResponse
        }
    }

    private static func data(for request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ZeuzAgentError.badResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                let failure = try? JSONDecoder().decode(Failure.self, from: data)
                throw ZeuzAgentError.rejected(failure?.error ?? "Error HTTP \(http.statusCode)")
            }
            return data
        } catch let error as ZeuzAgentError {
            throw error
        } catch {
            throw ZeuzAgentError.unreachable(error.localizedDescription)
        }
    }
}

extension ZeuzAgentProgramClient {
    struct PairResult: Decodable, Sendable {
        let token: String
        let agentName: String

        enum CodingKeys: String, CodingKey {
            case token
            case agentName = "agent_name"
        }
    }

    private struct WorkshopConnection: Decodable { let server_url: String }
    private struct PairBody: Encodable { let code: String }
    private struct EmptyBody: Encodable {}
    private struct Ack: Decodable { let ok: Bool }
    private struct Failure: Decodable { let error: String }
    private struct ChangeResponse: Decodable { let version: Int }
    private struct SearchResponse: Decodable { let results: [AgentEntry] }
    private struct CreateResult: Decodable { let path: String }
    private struct WriteBody: Encodable { let path: String; let content: String }
    private struct CreateBody: Encodable {
        let directory: String
        let name: String
        let kind: String
    }

    private struct SavedDNCMachine: Decodable {
        let machine: ZeuzBridgeClient.PiMachine?
    }

    private struct DNCMachinePayload: Encodable {
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
            revision = machine.revision
            id = includeID ? machine.id : nil
            name = machine.name
            baudrate = machine.baudRate
            bytesize = machine.dataBits
            parity = machine.parity.rawValue
            stopbits = machine.stopBits
            flow_control = machine.flowControl.rawValue
            line_terminator = machine.lineTerminator.rawValue
            dtr = machine.dtr
            rts = machine.rts
            dripfeed = machine.dripFeed
        }
    }

    private struct ProvisionedDNCMachinePayload: Encodable {
        let id: String
        let name: String
        let dnc_host: String
        let dnc_port: Int
        let baudrate: Int
        let bytesize: Int
        let parity: String
        let stopbits: Int
        let flow_control: String
        let line_terminator: String
        let dtr: Bool
        let rts: Bool
        let dripfeed: Bool

        init(_ machine: Machine, dncHost: String, dncPort: Int) {
            id = machine.id
            name = machine.name
            dnc_host = dncHost
            dnc_port = dncPort
            baudrate = machine.baudRate
            bytesize = machine.dataBits
            parity = machine.parity.rawValue
            stopbits = machine.stopBits
            flow_control = machine.flowControl.rawValue
            line_terminator = machine.lineTerminator.rawValue
            dtr = machine.dtr
            rts = machine.rts
            dripfeed = machine.dripFeed
        }
    }

    private struct AgentListing: Decodable {
        let path: String
        let entries: [AgentEntry]
    }

    private struct AgentEntry: Decodable {
        let name: String
        let path: String
        let kind: String?
        let size: Int64
        let modified: TimeInterval?

        var programEntry: ProgramEntry {
            ProgramEntry(
                name: name,
                path: path,
                isDirectory: kind == "directory",
                size: size,
                modified: modified.map { Date(timeIntervalSince1970: $0) }
            )
        }
    }

    private struct AgentDocument: Decodable {
        let name: String
        let path: String
        let content: String
        let truncated: Bool
    }
}

enum ZeuzAgentError: LocalizedError, Sendable {
    case invalidAddress
    case invalidPairingCode
    case unreachable(String)
    case rejected(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            "Direccion de Zeuz Agent invalida"
        case .invalidPairingCode:
            "El codigo de emparejamiento debe tener 6 digitos"
        case .unreachable(let detail):
            "No se pudo contactar Zeuz Agent: \(detail)"
        case .rejected(let detail):
            detail
        case .badResponse:
            "Zeuz Agent respondio datos incompatibles"
        }
    }
}
