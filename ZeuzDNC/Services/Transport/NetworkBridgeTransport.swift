import Foundation
import Network

/// Envia el programa por TCP a un puente serial en la red WiFi: una Raspberry
/// Pi, un ESP32, o un servidor serial comercial (Moxa NPort, USR-TCP232…).
/// El puente es el que tiene el adaptador USB-RS232 fisico.
///
/// Dos modos:
///
/// - **TCP crudo**: la app solo empuja bytes; el baudrate/paridad se
///   configuran una vez en el puente. Funciona con cualquier modulo barato.
/// - **RFC 2217**: la app negocia baudrate, bits, paridad, stop y control de
///   flujo con el puente en cada envio, asi el perfil de la maquina manda y
///   no hay que reconfigurar el hardware al cambiar de CNC.
actor NetworkBridgeTransport: SerialTransport {
    private let endpoint: SerialEndpoint
    private let queue = DispatchQueue(label: "zeuzdnc.bridge")

    private var connection: NWConnection?
    private var machine: Machine?
    private var receiveTask: Task<Void, Never>?

    /// Control de flujo software: la maquina mando XOFF y hay que parar.
    private var flowPaused = false
    private var flowWaiters: [CheckedContinuation<Void, Never>] = []

    /// Handshake RFC 2217 pendiente de respuesta del puente.
    private var negotiationWaiter: CheckedContinuation<Void, Error>?

    private var bytesWritten = 0
    private var firstWriteAt: Date?

    private var telnetState = TelnetState()

    init(endpoint: SerialEndpoint) {
        self.endpoint = endpoint
    }

    // MARK: - Apertura

    func open(machine: Machine) async throws {
        self.machine = machine
        self.bytesWritten = 0
        self.firstWriteAt = nil
        self.flowPaused = false
        self.telnetState = TelnetState()

        guard let port = NWEndpoint.Port(rawValue: UInt16(endpoint.port)) else {
            throw TransportError.connectionFailed(L10n.text("Puerto TCP invalido"))
        }

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        let params = NWParameters(tls: nil, tcp: tcp)

        let conn = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: port,
            using: params
        )
        self.connection = conn

        try await withTimeout(
            seconds: 10,
            message: L10n.format("conectando con el puente %@", endpoint.host)
        ) {
            try await self.waitUntilReady(conn)
        }

        startReceiveLoop(conn)

        if endpoint.useRFC2217 {
            try await negotiateRFC2217(machine: machine)
        }
    }

    private func waitUntilReady(_ conn: NWConnection) async throws {
        let guardian = ResumeGuard()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if guardian.claim() { cont.resume() }
                case .failed(let error):
                    if guardian.claim() {
                        cont.resume(throwing: TransportError.connectionFailed(error.localizedDescription))
                    }
                case .waiting(let error):
                    // En una LAN, "waiting" casi siempre significa que el puente
                    // esta apagado o la IP no responde. NWConnection reintentaria
                    // para siempre, asi que fallamos con el motivo real.
                    if guardian.claim() {
                        cont.resume(throwing: TransportError.connectionFailed(error.localizedDescription))
                    }
                case .cancelled:
                    if guardian.claim() { cont.resume(throwing: TransportError.cancelled) }
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
    }

    // MARK: - Escritura

    func write(_ data: Data) async throws {
        guard let conn = connection else { throw TransportError.notConnected }
        try Task.checkCancellation()

        // Si la maquina mando XOFF, esperamos aqui a que reanude.
        try await awaitFlowResume()
        try Task.checkCancellation()

        if firstWriteAt == nil { firstWriteAt = Date() }

        // En RFC 2217 el flujo es telnet: un 0xFF de datos hay que duplicarlo
        // para que el puente no lo confunda con un comando IAC.
        let payload = endpoint.useRFC2217 ? Self.escapeIAC(data) : data

        try await rawSend(payload, over: conn)
        bytesWritten += data.count
    }

    private func rawSend(_ data: Data, over conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: TransportError.writeFailed(error.localizedDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    // MARK: - Vaciado antes de cerrar

    func drain(dripFeed: Bool) async throws {
        guard let machine else { return }

        // TCP ya acepto todos los bytes, pero eso solo significa que llegaron
        // al puente: todavia tienen que salir por la linea serial a 4800 o
        // 9600 baud. Si cerramos ahora, el puente descarta lo que le queda en
        // el buffer y la maquina recibe el programa incompleto.
        //
        // Estimamos cuanto tarda fisicamente y esperamos la diferencia contra
        // lo que ya paso. En goteo el control de flujo ya nos freno durante el
        // envio, asi que normalmente esto sale en cero.
        if let start = firstWriteAt {
            let physical = machine.transmissionTime(forBytes: bytesWritten)
            let elapsed = Date().timeIntervalSince(start)
            let remaining = physical - elapsed
            if remaining > 0 {
                try await Task.sleep(for: .seconds(remaining))
            }
        }

        // Margen para el FIFO interno del adaptador USB del puente.
        try await Task.sleep(for: .milliseconds(300))
    }

    func close() async {
        receiveTask?.cancel()
        receiveTask = nil
        connection?.cancel()
        connection = nil
        // Nadie debe quedarse colgado esperando un XON que ya no llegara.
        releaseFlowWaiters()
        negotiationWaiter?.resume(throwing: TransportError.cancelled)
        negotiationWaiter = nil
    }

    // MARK: - Control de flujo (XON/XOFF)

    private func awaitFlowResume() async throws {
        guard flowPaused else { return }
        let dripFeed = machine?.dripFeed ?? false
        // En goteo la maquina puede tardar minutos en pedir mas (movimientos
        // largos, cambio de herramienta): no hay limite. En punch, red de
        // seguridad de 120 s para no colgar el envio para siempre.
        let deadline = dripFeed ? nil : Date().addingTimeInterval(120)

        while flowPaused {
            if let deadline, Date() > deadline {
                throw TransportError.timeout(
                    L10n.text(
                        "esperando a que la maquina reciba (¿esta en modo recepcion? ¿control de flujo correcto?)"
                    )
                )
            }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                flowWaiters.append(cont)
            }
            try Task.checkCancellation()
        }
    }

    private func releaseFlowWaiters() {
        let waiters = flowWaiters
        flowWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func setFlowPaused(_ paused: Bool) {
        flowPaused = paused
        if !paused { releaseFlowWaiters() }
    }

    // MARK: - Lectura entrante

    private func startReceiveLoop(_ conn: NWConnection) {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                let chunk: Data?
                do {
                    chunk = try await Self.receiveOnce(conn)
                } catch {
                    return
                }
                guard let chunk, !chunk.isEmpty else {
                    if chunk == nil { return }  // conexion cerrada por el otro lado
                    continue
                }
                await self?.handleIncoming(chunk)
            }
        }
    }

    private static func receiveOnce(_ conn: NWConnection) async throws -> Data? {
        let guardian = ResumeGuard()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                guard guardian.claim() else { return }
                if let error {
                    cont.resume(throwing: error)
                } else if isComplete {
                    cont.resume(returning: nil)
                } else {
                    cont.resume(returning: data ?? Data())
                }
            }
        }
    }

    /// Separa comandos telnet de datos reales y reacciona a XON/XOFF.
    private func handleIncoming(_ chunk: Data) {
        let parsed = endpoint.useRFC2217
            ? telnetState.consume(chunk)
            : TelnetState.Parsed(data: chunk, sawComPortAck: false)

        if parsed.sawComPortAck, let waiter = negotiationWaiter {
            negotiationWaiter = nil
            waiter.resume()
        }

        guard machine?.flowControl == .xonXoff else { return }
        for byte in parsed.data {
            if byte == Telnet.xoff {
                setFlowPaused(true)
            } else if byte == Telnet.xon {
                setFlowPaused(false)
            }
        }
    }

    // MARK: - RFC 2217

    private func negotiateRFC2217(machine: Machine) async throws {
        guard let conn = connection else { throw TransportError.notConnected }

        // IAC WILL COM-PORT-OPTION → el puente debe responder IAC DO.
        try await rawSend(Data([Telnet.iac, Telnet.will, Telnet.comPortOption]), over: conn)

        do {
            try await waitForComPortAck(timeout: 5)
        } catch {
            throw TransportError.handshakeFailed(
                L10n.format(
                    "no respondio a RFC 2217. Si el puente no lo soporta, apaga esa opcion en el puerto y configura %lld baud directamente en el puente.",
                    machine.baudRate
                )
            )
        }

        for command in Telnet.comPortCommands(for: machine) {
            try await rawSend(command, over: conn)
        }
        // Le damos un instante al puente para aplicar la config antes de datos.
        try await Task.sleep(for: .milliseconds(150))
    }

    /// Espera el `IAC DO COM-PORT-OPTION` del puente. El timeout se arma como
    /// una tarea aparte que resuelve el mismo waiter: asi la continuation se
    /// crea y se guarda dentro del actor, sin cruzar limites de aislamiento.
    private func waitForComPortAck(timeout: TimeInterval) async throws {
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            await self?.failNegotiation()
        }
        defer { timeoutTask.cancel() }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            negotiationWaiter = cont
        }
    }

    private func failNegotiation() {
        guard let waiter = negotiationWaiter else { return }
        negotiationWaiter = nil
        waiter.resume(throwing: TransportError.timeout(
            L10n.text("negociando RFC 2217 con el puente")
        ))
    }

    private static func escapeIAC(_ data: Data) -> Data {
        guard data.contains(Telnet.iac) else { return data }
        var out = Data()
        out.reserveCapacity(data.count + 16)
        for byte in data {
            out.append(byte)
            if byte == Telnet.iac { out.append(Telnet.iac) }
        }
        return out
    }
}

// MARK: - Telnet / RFC 2217

private enum Telnet {
    static let se: UInt8 = 240
    static let sb: UInt8 = 250
    static let will: UInt8 = 251
    static let doCmd: UInt8 = 253
    static let dontCmd: UInt8 = 254
    static let wont: UInt8 = 252
    static let iac: UInt8 = 255
    static let comPortOption: UInt8 = 44

    static let xon: UInt8 = 0x11
    static let xoff: UInt8 = 0x13

    // Comandos cliente→servidor de RFC 2217.
    static let setBaudRate: UInt8 = 1
    static let setDataSize: UInt8 = 2
    static let setParity: UInt8 = 3
    static let setStopSize: UInt8 = 4
    static let setControl: UInt8 = 5

    static func subnegotiation(_ command: UInt8, _ payload: [UInt8]) -> Data {
        var data = Data([iac, sb, comPortOption, command])
        // Dentro de una subnegociacion tambien hay que escapar 0xFF.
        for byte in payload {
            data.append(byte)
            if byte == iac { data.append(iac) }
        }
        data.append(contentsOf: [iac, se])
        return data
    }

    static func comPortCommands(for machine: Machine) -> [Data] {
        var commands: [Data] = []

        let baud = UInt32(machine.baudRate).bigEndian
        let baudBytes = withUnsafeBytes(of: baud) { Array($0) }
        commands.append(subnegotiation(setBaudRate, baudBytes))

        commands.append(subnegotiation(setDataSize, [UInt8(machine.dataBits)]))

        let parityCode: UInt8 = switch machine.parity {
        case .none: 1
        case .odd: 2
        case .even: 3
        case .mark: 4
        case .space: 5
        }
        commands.append(subnegotiation(setParity, [parityCode]))

        commands.append(subnegotiation(setStopSize, [UInt8(machine.stopBits)]))

        let flowCode: UInt8 = switch machine.flowControl {
        case .none: 1
        case .xonXoff: 2
        case .rtsCts: 3
        }
        commands.append(subnegotiation(setControl, [flowCode]))

        // DTR y RTS explicitos: 8=DTR ON, 9=DTR OFF, 11=RTS ON, 12=RTS OFF.
        commands.append(subnegotiation(setControl, [machine.dtr ? 8 : 9]))
        if machine.flowControl != .rtsCts {
            commands.append(subnegotiation(setControl, [machine.rts ? 11 : 12]))
        }

        return commands
    }
}

/// Maquina de estados que va separando comandos telnet de datos reales.
/// Los comandos pueden partirse entre dos paquetes TCP, por eso el estado
/// vive entre llamadas.
private struct TelnetState {
    struct Parsed {
        var data: Data
        var sawComPortAck: Bool
    }

    private enum Mode {
        case normal
        case iac
        case command       // esperando el byte de opcion tras WILL/WONT/DO/DONT
        case subnegotiation
        case subnegotiationIAC
    }

    private var mode: Mode = .normal
    private var pendingCommand: UInt8 = 0
    private var subnegotiationOption: UInt8?

    mutating func consume(_ chunk: Data) -> Parsed {
        var out = Data()
        out.reserveCapacity(chunk.count)
        var sawAck = false

        for byte in chunk {
            switch mode {
            case .normal:
                if byte == Telnet.iac { mode = .iac } else { out.append(byte) }

            case .iac:
                switch byte {
                case Telnet.iac:
                    out.append(Telnet.iac)      // 0xFF escapado = dato real
                    mode = .normal
                case Telnet.will, Telnet.wont, Telnet.doCmd, Telnet.dontCmd:
                    pendingCommand = byte
                    mode = .command
                case Telnet.sb:
                    subnegotiationOption = nil
                    mode = .subnegotiation
                default:
                    mode = .normal
                }

            case .command:
                // El puente acepta RFC 2217 respondiendo DO COM-PORT-OPTION.
                if byte == Telnet.comPortOption, pendingCommand == Telnet.doCmd {
                    sawAck = true
                }
                mode = .normal

            case .subnegotiation:
                if byte == Telnet.iac {
                    mode = .subnegotiationIAC
                } else if subnegotiationOption == nil {
                    subnegotiationOption = byte
                }

            case .subnegotiationIAC:
                if byte == Telnet.se {
                    mode = .normal
                } else {
                    // IAC IAC dentro de la subnegociacion: seguimos dentro.
                    mode = .subnegotiation
                }
            }
        }

        return Parsed(data: out, sawComPortAck: sawAck)
    }
}

// MARK: - Utilidades

/// Garantiza que una continuation se reanude una sola vez aunque el callback
/// de Network.framework se dispare varias veces desde otra cola.
final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Corre una operacion con limite de tiempo y un mensaje entendible si expira.
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    message: String,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TransportError.timeout(message)
        }
        guard let result = try await group.next() else {
            throw TransportError.timeout(message)
        }
        group.cancelAll()
        return result
    }
}
