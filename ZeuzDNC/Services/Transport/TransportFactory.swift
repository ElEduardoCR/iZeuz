import Foundation

/// Crea el transporte correcto para un puerto. Es el unico lugar de la app
/// que sabe que existen varias formas de sacar bytes hacia la maquina.
enum TransportFactory {
    /// Aislado al main actor porque el transporte MFi vive ahi: sus streams
    /// cuelgan del run loop principal.
    @MainActor
    static func make(for endpoint: SerialEndpoint) -> SerialTransport {
        switch endpoint.kind {
        case .networkBridge:
            NetworkBridgeTransport(endpoint: endpoint)
        case .mfiCable:
            MFiSerialTransport(endpoint: endpoint)
        case .simulator:
            MockTransport()
        }
    }
}
