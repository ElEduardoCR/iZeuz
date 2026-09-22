import Foundation

struct ZeuzAgentSettings: Codable, Equatable, Sendable {
    var baseURL: String = ""
    var agentName: String = ""

    var normalizedURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var isConfigured: Bool {
        guard let url = URL(string: normalizedURL),
              let scheme = url.scheme?.lowercased()
        else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }

    var displayName: String {
        agentName.isEmpty ? normalizedURL : agentName
    }

    var keychainAccount: String {
        "zeuz-agent:\(normalizedURL)"
    }
}

@MainActor
@Observable
final class ZeuzAgentSettingsStore {
    var settings: ZeuzAgentSettings {
        didSet { store.save(settings) }
    }

    private let store = JSONFileStore<ZeuzAgentSettings>(filename: "zeuz-agent.json")

    init() {
        settings = store.load() ?? ZeuzAgentSettings()
    }

    var token: String {
        get { Keychain.get(account: settings.keychainAccount) ?? "" }
        set { Keychain.set(newValue, account: settings.keychainAccount) }
    }

    var isReady: Bool {
        settings.isConfigured && !token.isEmpty
    }

    func forget() {
        UserDefaults.standard.removeObject(forKey: "zeuz.workshop.fallback:" + settings.normalizedURL)
        UserDefaults.standard.removeObject(forKey: "zeuz.workshop.active:" + settings.normalizedURL)
        Keychain.delete(account: settings.keychainAccount)
        settings = ZeuzAgentSettings()
    }
}

