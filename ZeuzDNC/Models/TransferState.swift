import Foundation

/// Estado de una transferencia hacia la maquina.
struct TransferState: Sendable, Equatable {
    var status: Status = .idle
    var fileName: String?
    var machineName: String?
    var endpointName: String?
    var bytesSent: Int = 0
    var totalBytes: Int = 0
    var message: String = ""

    enum Status: String, Sendable {
        case idle
        case connecting
        case sending
        case finishing
        case success
        case error
        case cancelled

        var isActive: Bool {
            self == .connecting || self == .sending || self == .finishing
        }

        var label: String {
            switch self {
            case .idle: "Listo"
            case .connecting: "Conectando…"
            case .sending: "Enviando…"
            case .finishing: "Finalizando…"
            case .success: "Transferencia completada"
            case .error: "Error"
            case .cancelled: "Envio cancelado"
            }
        }
    }

    var percent: Int {
        guard totalBytes > 0 else { return status == .success ? 100 : 0 }
        return min(100, Int(Double(bytesSent) * 100.0 / Double(totalBytes)))
    }

    var fraction: Double {
        guard totalBytes > 0 else { return status == .success ? 1 : 0 }
        return min(1, Double(bytesSent) / Double(totalBytes))
    }

    var progressLabel: String {
        guard totalBytes > 0 else { return "" }
        let sent = ByteCountFormatter.string(fromByteCount: Int64(bytesSent), countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
        return "\(sent) de \(total)"
    }

    static let idle = TransferState()
}

/// Eventos que emite el envio mientras corre.
enum TransferEvent: Sendable {
    case connecting
    case started(totalBytes: Int)
    case progress(bytesSent: Int)
    case finishing(message: String)
    case finished
    case cancelled
    case failed(String)
}
