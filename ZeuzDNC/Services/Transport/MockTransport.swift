import Foundation

/// Transporte simulado: no manda nada a ningun lado, pero respeta el tiempo
/// real que tardaria la linea al baudrate del perfil.
///
/// Sirve para probar el flujo completo (elegir programa, elegir maquina,
/// barra de progreso, cancelar) en el simulador de Xcode o en un iPhone sin
/// tener el puente ni el cable a la mano.
actor MockTransport: SerialTransport {
    private var machine: Machine?
    private var bytesWritten = 0

    /// Simula que la maquina manda XOFF a mitad del programa, para poder
    /// probar que la pausa por control de flujo se ve bien en pantalla.
    private let simulateFlowControlPause: Bool

    init(simulateFlowControlPause: Bool = false) {
        self.simulateFlowControlPause = simulateFlowControlPause
    }

    func open(machine: Machine) async throws {
        self.machine = machine
        self.bytesWritten = 0
        // Un handshake real tarda un momento; lo imitamos para que la
        // interfaz no salte de golpe de "Conectando" a "Enviando".
        try await Task.sleep(for: .milliseconds(400))
    }

    func write(_ data: Data) async throws {
        guard let machine else { throw TransportError.notConnected }
        try Task.checkCancellation()

        if simulateFlowControlPause, bytesWritten > 0, bytesWritten % 4096 < data.count {
            try await Task.sleep(for: .milliseconds(800))
        }

        // Esperamos lo que tardaria de verdad este bloque en salir por la
        // linea: asi la barra de progreso avanza a la velocidad real.
        try await Task.sleep(for: .seconds(machine.transmissionTime(forBytes: data.count)))
        bytesWritten += data.count
    }

    func drain(dripFeed: Bool) async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    func close() async {
        machine = nil
    }
}
