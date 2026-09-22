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
/// 2. seleccionar la máquina en Zeuz Agent,
/// 3. **dar la orden de enviar**; el agente adjunta el perfil y el destino,
/// 4. sondear el estado hasta que termine.
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
    /// Al desbloquear el iPhone, Wi-Fi puede tardar unos segundos en volver.
    /// Un fallo de sondeo no significa que la Pi haya detenido el goteo.
    static let statusRetryAttempts = 30

    /// Una escritura bloqueada por XOFF puede no salir con el primer
    /// `cancel_write()` de pyserial. Repetimos la orden y comprobamos el estado
    /// remoto para que CANCELAR signifique que la Pi realmente se detuvo.
    static let cancelAttempts = 8
    static let cancelRetryInterval: Duration = .milliseconds(400)

    static func send(
        document: ProgramDocument,
        machine: Machine,
        endpoint: SerialEndpoint,
        client: any ZeuzDNCClient
    ) -> AsyncStream<TransferEvent> {
        AsyncStream { continuation in
            let task = Task {
                var activeMachineID = machine.id
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
                    activeMachineID = pick.id

                    try Task.checkCancellation()

                    // 2. Máquina activa en Zeuz Agent. Su perfil ya contiene la
                    //    Orange Pi asignada y todos los parámetros seriales.
                    try await client.selectMachine(id: pick.id)

                    try Task.checkCancellation()

                    // 3. La orden. La Pi descarga ese mismo archivo del agente y
                    //    recibe el perfil serial junto con la solicitud.
                    try await client.send(path: document.path, machineID: pick.id)

                    // 4. Seguir el envío que ya corre en la Pi.
                    try await pollUntilDone(
                        client: client,
                        machineID: pick.id,
                        continuation: continuation
                    )
                } catch {
                    if error is CancellationError || Task.isCancelled {
                        let machineID = activeMachineID
                        // No heredar la cancelacion de la tarea de sondeo: una
                        // URLSession iniciada desde ella se cancelaba antes de
                        // alcanzar a Zeuz Agent/Raspberry Pi.
                        await Task.detached(priority: .userInitiated) {
                            await cancelRemotely(client: client, machineID: machineID)
                        }.value
                        continuation.yield(.cancelled)
                    } else if let bridgeError = error as? ZeuzBridgeError {
                        continuation.yield(.failed(
                            bridgeError.errorDescription ?? L10n.text("Error con el puente")
                        ))
                    } else {
                        continuation.yield(.failed(error.localizedDescription))
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Cancela fuera de la tarea de sondeo y no regresa hasta confirmar que la
    /// Pi dejo de reportar `sending` o agotar los reintentos.
    static func cancelRemotely(client: any ZeuzDNCClient, machineID: String) async {
        for attempt in 0..<cancelAttempts {
            await client.cancel(machineID: machineID)
            if let snapshot = try? await client.status(machineID: machineID),
               snapshot.status != "sending" {
                return
            }
            guard attempt + 1 < cancelAttempts else { return }
            try? await Task.sleep(for: cancelRetryInterval)
        }
    }

    /// Sondea `/api/transfer/status` y traduce cada estado de la Pi a un evento.
    private static func pollUntilDone(
        client: any ZeuzDNCClient,
        machineID: String,
        continuation: AsyncStream<TransferEvent>.Continuation
    ) async throws {
        var announcedTotal = false
        var consecutiveStatusFailures = 0

        while true {
            try Task.checkCancellation()
            let snap: ZeuzBridgeClient.PiTransfer
            do {
                snap = try await client.status(machineID: machineID)
                consecutiveStatusFailures = 0
            } catch {
                try Task.checkCancellation()
                consecutiveStatusFailures += 1
                guard consecutiveStatusFailures < statusRetryAttempts else {
                    throw error
                }
                try await Task.sleep(for: pollInterval)
                continue
            }

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
                    snap.message.isEmpty
                        ? L10n.text("ZeuzDNC reportó un error en el envío")
                        : snap.message
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
