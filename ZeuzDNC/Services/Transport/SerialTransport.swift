import Foundation

/// Abstraccion de "por donde salen los bytes hacia la maquina".
///
/// En la Raspberry Pi esto era simplemente abrir `/dev/ttyUSB0` con pyserial.
/// iOS no expone adaptadores USB-serial genericos, asi que hay varias
/// implementaciones posibles (puente WiFi, cable MFi, simulador) y el resto
/// de la app no necesita saber cual esta en uso.
protocol SerialTransport: Sendable {
    /// Abre el enlace y deja la linea configurada segun el perfil de maquina.
    func open(machine: Machine) async throws

    /// Escribe un bloque. Debe respetar el control de flujo: si la maquina
    /// mando XOFF (o bajo CTS), esta llamada se bloquea hasta que reanude.
    func write(_ data: Data) async throws

    /// Espera a que los bytes salgan fisicamente por la linea serial antes de
    /// cerrar. Sin esto, a 4800 baud se pierde la cola del programa.
    func drain(dripFeed: Bool) async throws

    /// Cierra el enlace. No debe lanzar: se llama tambien en rutas de error.
    func close() async
}

/// Errores que la interfaz muestra tal cual al operador.
enum TransportError: LocalizedError, Sendable {
    case notConnected
    case connectionFailed(String)
    case handshakeFailed(String)
    case writeFailed(String)
    case timeout(String)
    case accessoryNotFound
    case accessoryProtocolMismatch(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "No hay conexion con el puerto"
        case .connectionFailed(let detail):
            "No se pudo conectar: \(detail)"
        case .handshakeFailed(let detail):
            "El puente rechazo la configuracion del puerto: \(detail)"
        case .writeFailed(let detail):
            "Error al enviar: \(detail)"
        case .timeout(let detail):
            "Se agoto el tiempo \(detail)"
        case .accessoryNotFound:
            "No se encontro el cable serial conectado al telefono"
        case .accessoryProtocolMismatch(let proto):
            """
            iOS no abrio la sesion con el cable. Revisa que "\(proto)" \
            este declarado en UISupportedExternalAccessoryProtocols del Info.plist \
            y que coincida con el protocolo del cable.
            """
        case .cancelled:
            "Envio cancelado"
        }
    }
}

extension Machine {
    /// Bits totales por byte en la linea, contando start, datos, paridad y
    /// stop. Sirve para estimar cuanto tarda fisicamente el programa en salir.
    var bitsPerByte: Double {
        let parityBits: Double = parity == .none ? 0 : 1
        return 1 + Double(dataBits) + parityBits + Double(stopBits)
    }

    /// Bytes por segundo que aguanta la linea a este baudrate.
    var bytesPerSecond: Double {
        max(1, Double(baudRate) / bitsPerByte)
    }

    /// Cuanto tarda fisicamente en salir esa cantidad de bytes.
    func transmissionTime(forBytes count: Int) -> TimeInterval {
        Double(count) / bytesPerSecond
    }
}
