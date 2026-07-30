import Foundation

/// Cliente nativo del contrato HTTP v1 de Zeuz Agent.
actor ZeuzAgentProgramClient: ProgramClient {
    private let settings: ZeuzAgentSettings
    private let token: String

    init(settings: ZeuzAgentSettings, token: String) {
        self.settings = settings
        self.token = token
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
        return String(value.version)
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
        guard let url = URL(string: settings.normalizedURL + path) else {
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
        let data = try await Self.data(for: request)
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
