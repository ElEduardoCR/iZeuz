import Foundation

/// Datos de conexion a la carpeta compartida de la red WiFi.
/// La contrasena NO vive aqui: va al llavero (ver `Keychain`).
struct SMBSettings: Codable, Equatable, Sendable {
    /// IP o nombre del equipo que comparte la carpeta (el NAS, la PC de
    /// oficina, la Raspberry Pi…).
    var host: String = ""
    /// Nombre del recurso compartido, p. ej. "cnc-programs".
    var share: String = ""
    var username: String = ""
    var domain: String = ""
    /// Subcarpeta dentro del share donde estan los programas. Vacio = raiz.
    var rootPath: String = ""

    var isConfigured: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !share.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Cuenta con la que se guarda la contrasena en el llavero.
    var keychainAccount: String {
        "\(username)@\(host)/\(share)"
    }

    var displayPath: String {
        guard isConfigured else { return L10n.text("Sin configurar") }
        let base = "smb://\(host)/\(share)"
        return rootPath.isEmpty ? base : "\(base)/\(rootPath)"
    }
}

/// Guarda y recupera la configuracion del share.
@MainActor
@Observable
final class SMBSettingsStore {
    var settings: SMBSettings {
        didSet { store.save(settings) }
    }

    private let store = JSONFileStore<SMBSettings>(filename: "smb.json")

    init() {
        settings = store.load() ?? SMBSettings()
    }

    var password: String {
        get { Keychain.get(account: settings.keychainAccount) ?? "" }
        set { Keychain.set(newValue, account: settings.keychainAccount) }
    }

    func clearPassword() {
        Keychain.delete(account: settings.keychainAccount)
    }
}
