import Foundation

/// Persistencia simple en JSON dentro de Application Support.
///
/// Se escribe de forma atomica para que un cierre a medias no deje el archivo
/// de maquinas corrupto — es el mismo cuidado que tiene `machines.py` en la
/// Raspberry Pi.
struct JSONFileStore<Value: Codable & Sendable>: Sendable {
    let filename: String

    private var url: URL? {
        guard let directory = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return directory.appendingPathComponent(filename)
    }

    func load() -> Value? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Value.self, from: data)
    }

    func save(_ value: Value) {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
