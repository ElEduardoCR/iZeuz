import Foundation

/// Envio por el puente ZeuzDNC de la Raspberry Pi.
///
/// Es el equivalente de `GCodeSender` para el modo delegado: en vez de sacar
/// los bytes uno mismo, le da la orden a la Pi y sigue su progreso. Emite el
/// mismo `AsyncStream<TransferEvent>`, asi que la barra de progreso y el boton
/// CANCELAR funcionan igual que con los otros transportes.
///
/// La secuencia al picar ENVIAR:
/// 1. pedir la lista de maquinas de la Pi y emparejar por nombre,
/// 2. (si hay varios adaptadores) elegir el puerto serial,
/// 3. seleccionar la maquina en la Pi,
/// 4. **dar la orden de enviar** el archivo que YA esta en la Pi,
/// 5. sondear el estado hasta que termine.
///
/// ## Por que NO reescribe el archivo
///
/// Con los programas viviendo en la propia Pi (el caso normal), el iPhone edita
/// y guarda por SMB directo sobre la carpeta de la Pi, asi que el archivo ya
/// esta ahi y actualizado al picar ENVIAR. Antes se empujaba el contenido por
/// HTTP "por robustez", pero eso reescribia el programa bueno de la Pi con la
/// copia del iPhone — y cualquier diferencia en esa copia mandaba basura a la
/// maquina y dejaba el archivo dañado para el siguiente envio (incluso el de la
/// Pi directa). La orden manda el MISMO archivo que el boton de la Pi: identico.
enum ZeuzBridgeSender {

    /// Cada cuanto se le pregunta a la Pi como va. 400 ms se siente en vivo sin
    /// saturar el Flask de un solo hilo por peticion.
    static let pollInterval: Duration = .milliseconds(400)

    static func send(
        document: ProgramDocument,
        machine: Machine,
        endpoint: SerialEndpoint
    ) -> AsyncStream<TransferEvent> {
        AsyncStream { continuation in
            let client = ZeuzBridgeClient(host: endpoint.host, port: endpoint.port)

            let task = Task {
                do {
                    continuation.yield(.connecting)

                    // 1. Emparejar la maquina del iPhone con una de la Pi por nombre.
                    let piMachines = try await client.machines()
                    let wanted = machine.name.trimmingCharacters(in: .whitespaces)
                    guard let pick = piMachines.first(where: {
                        $0.name.trimmingCharacters(in: .whitespaces)
                            .caseInsensitiveCompare(wanted) == .orderedSame
                    }) else {
                        throw ZeuzBridgeError.machineNotFound(machine.name)
                    }

                    try Task.checkCancellation()

                    // 2. Puerto serial de la Pi, solo si el puerto trae uno anotado
                    //    (hub con varios adaptadores). Con uno solo, la Pi elige.
                    if !endpoint.bridgePort.isEmpty {
                        try? await client.selectDevice(path: endpoint.bridgePort)
                    }

                    // 3. Maquina activa en la Pi (por id, ya emparejada por nombre).
                    try await client.selectMachine(id: pick.id)

                    try Task.checkCancellation()

                    // 4. La orden, sobre el archivo que YA esta en la Pi. No se
                    //    reescribe nada: se manda tal cual, identico al boton de
                    //    la Pi. Si falta algo (cable, puerto, otra transferencia
                    //    en curso) la Pi lo dice aqui y se muestra tal cual.
                    try await client.send(path: document.path)

                    // 5. Seguir el envio que ya corre en la Pi.
                    try await pollUntilDone(client: client, continuation: continuation)
                } catch is CancellationError {
                    await client.cancel()
                    continuation.yield(.cancelled)
                } catch let error as ZeuzBridgeError {
                    continuation.yield(.failed(error.errorDescription ?? "Error con el puente"))
                } catch {
                    continuation.yield(.failed(error.localizedDescription))
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Sondea `/api/transfer/status` y traduce cada estado de la Pi a un evento.
    private static func pollUntilDone(
        client: ZeuzBridgeClient,
        continuation: AsyncStream<TransferEvent>.Continuation
    ) async throws {
        var announcedTotal = false

        while true {
            try Task.checkCancellation()
            let snap = try await client.status()

            switch snap.status {
            case "sending":
                // El total real (con el terminador ya aplicado) lo sabe la Pi;
                // se anuncia en cuanto llega para que la barra tenga escala.
                if !announcedTotal, snap.totalBytes > 0 {
                    continuation.yield(.started(totalBytes: snap.totalBytes))
                    announcedTotal = true
                }
                if snap.message.localizedCaseInsensitiveContains("finaliz") {
                    continuation.yield(.finishing(message: snap.message))
                } else {
                    continuation.yield(.progress(bytesSent: snap.bytesSent))
                }

            case "success":
                if !announcedTotal {
                    continuation.yield(.started(totalBytes: max(snap.totalBytes, 1)))
                }
                continuation.yield(.finished)
                return

            case "error":
                continuation.yield(.failed(
                    snap.message.isEmpty ? "La Raspberry Pi reporto un error en el envio" : snap.message
                ))
                return

            case "cancelled":
                continuation.yield(.cancelled)
                return

            default:
                // "idle" justo despues de la orden: la Pi todavia esta armando
                // el hilo de transferencia. Se sigue sondeando.
                break
            }

            try await Task.sleep(for: pollInterval)
        }
    }
}
