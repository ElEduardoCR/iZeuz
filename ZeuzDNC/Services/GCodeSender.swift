import Foundation

/// Prepara y transmite un programa G-code hacia la maquina.
///
/// Es una transferencia completa a la memoria ("punch"), no un drip-feed
/// sincronizado con el ciclo de maquinado — salvo que el perfil marque
/// `dripFeed`, en cuyo caso se alimenta indefinidamente y solo se detiene
/// al cancelar.
enum GCodeSender {
    /// Igual que en la Pi: bloques chicos para que la barra de progreso
    /// avance suave y para poder cancelar rapido entre bloque y bloque.
    static let chunkSize = 256

    /// Convierte el texto del programa al terminador de linea que espera la
    /// maquina y lo pasa a bytes.
    ///
    /// Se usa latin-1 (ISO 8859-1) porque mapea 1 a 1 cada byte: nunca falla
    /// con G-code/ISO y no altera el contenido. El archivo original en la
    /// carpeta compartida no se toca — la conversion es solo del envio.
    static func preparePayload(content: String, terminator: Machine.LineTerminator) -> Data {
        // `components(separatedBy:)` sobre los saltos ya normalizados evita
        // duplicar el CR cuando el archivo venia de Windows con CRLF.
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var lines = normalized.components(separatedBy: "\n")
        // Un archivo que termina en salto genera un ultimo elemento vacio que
        // no es una linea real; si lo dejamos, mandamos un terminador de mas.
        if lines.last?.isEmpty == true { lines.removeLast() }

        guard !lines.isEmpty else { return Data() }

        let body = lines.joined(separator: terminator.bytes) + terminator.bytes
        return body.data(using: .isoLatin1, allowLossyConversion: true) ?? Data()
    }

    /// Ejecuta la transferencia emitiendo eventos de avance.
    ///
    /// El `AsyncStream` termina siempre — con `.finished`, `.cancelled` o
    /// `.failed` — para que quien lo consume nunca se quede colgado.
    static func send(
        payload: Data,
        machine: Machine,
        transport: SerialTransport
    ) -> AsyncStream<TransferEvent> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.connecting)
                    try await transport.open(machine: machine)

                    let total = payload.count
                    continuation.yield(.started(totalBytes: total))

                    var sent = 0
                    var index = payload.startIndex
                    while index < payload.endIndex {
                        try Task.checkCancellation()
                        let end = payload.index(
                            index,
                            offsetBy: chunkSize,
                            limitedBy: payload.endIndex
                        ) ?? payload.endIndex

                        try await transport.write(payload[index..<end])
                        sent += payload.distance(from: index, to: end)
                        continuation.yield(.progress(bytesSent: sent))
                        index = end
                    }

                    continuation.yield(.finishing(
                        message: machine.dripFeed ? "Finalizando goteo…" : "Finalizando envio…"
                    ))
                    try await transport.drain(dripFeed: machine.dripFeed)

                    await transport.close()
                    continuation.yield(.finished)
                } catch is CancellationError {
                    await transport.close()
                    continuation.yield(.cancelled)
                } catch let error as TransportError {
                    await transport.close()
                    if case .cancelled = error {
                        continuation.yield(.cancelled)
                    } else {
                        continuation.yield(.failed(error.localizedDescription))
                    }
                } catch {
                    await transport.close()
                    continuation.yield(.failed(error.localizedDescription))
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Maneja el estado visible de la transferencia en curso y permite cancelarla.
@MainActor
@Observable
final class TransferController {
    private(set) var state: TransferState = .idle
    private var task: Task<Void, Never>?

    var isSending: Bool { state.status.isActive }

    func send(
        document: ProgramDocument,
        machine: Machine,
        endpoint: SerialEndpoint
    ) {
        guard !isSending else { return }

        let payload = GCodeSender.preparePayload(
            content: document.content,
            terminator: machine.lineTerminator
        )
        let transport = TransportFactory.make(for: endpoint)

        state = TransferState(
            status: .connecting,
            fileName: document.name,
            machineName: machine.name,
            endpointName: endpoint.name,
            bytesSent: 0,
            totalBytes: payload.count,
            message: "Conectando con \(endpoint.name)…"
        )

        task = Task { [weak self] in
            let events = GCodeSender.send(
                payload: payload,
                machine: machine,
                transport: transport
            )
            for await event in events {
                guard let self else { return }
                self.apply(event)
            }
            self?.task = nil
        }
    }

    func cancel() {
        guard isSending else { return }
        task?.cancel()
        task = nil
        state.status = .cancelled
        state.message = "Envio cancelado"
    }

    func reset() {
        guard !isSending else { return }
        state = .idle
    }

    private func apply(_ event: TransferEvent) {
        switch event {
        case .connecting:
            state.status = .connecting
        case .started(let total):
            state.status = .sending
            state.totalBytes = total
            state.bytesSent = 0
            state.message = ""
        case .progress(let sent):
            state.status = .sending
            state.bytesSent = sent
        case .finishing(let message):
            state.status = .finishing
            state.message = message
        case .finished:
            state.status = .success
            state.bytesSent = state.totalBytes
            state.message = "Transferencia completada"
        case .cancelled:
            state.status = .cancelled
            state.message = "Envio cancelado"
        case .failed(let message):
            state.status = .error
            state.message = message
        }
    }
}
