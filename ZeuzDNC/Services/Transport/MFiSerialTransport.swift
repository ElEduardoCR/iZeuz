import Foundation
#if canImport(ExternalAccessory)
import ExternalAccessory
#endif

/// Envia por un cable serial certificado MFi conectado directo al telefono
/// (Redpark L2-DB9V3 para Lightning, C4-DB9V para USB-C).
///
/// ## Por que no sirve un adaptador USB-RS232 normal
///
/// iOS no expone ninguna API publica para adaptadores USB-serial genericos
/// (FTDI, CH340, PL2303). No existe `/dev/ttyUSB0`. La unica via oficial es
/// ExternalAccessory, que solo habla con accesorios certificados MFi.
///
/// ## Limite de esta implementacion
///
/// ExternalAccessory da un **tubo de bytes**, no control de la linea: con la
/// API publica NO se puede fijar baudrate, paridad ni bits de stop. Esa parte
/// la expone el SDK del fabricante (en Redpark, `RscMgr`), que se distribuye
/// bajo licencia y no se puede incluir aqui.
///
/// El punto de integracion esta marcado en `applyLineConfiguration(_:)`: al
/// agregar el SDK del cable, se implementa ahi y el resto de la app no cambia.
@MainActor
final class MFiSerialTransport: NSObject, SerialTransport {
    private let endpoint: SerialEndpoint
    private var machine: Machine?

    #if canImport(ExternalAccessory)
    private var session: EASession?
    #endif

    private var flowPaused = false
    private var flowWaiters: [CheckedContinuation<Void, Never>] = []
    private var spaceWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasSpace = false

    private var bytesWritten = 0
    private var firstWriteAt: Date?

    init(endpoint: SerialEndpoint) {
        self.endpoint = endpoint
        super.init()
    }

    // MARK: - Apertura

    func open(machine: Machine) async throws {
        #if canImport(ExternalAccessory)
        self.machine = machine
        self.bytesWritten = 0
        self.firstWriteAt = nil
        self.flowPaused = false
        self.hasSpace = false

        let manager = EAAccessoryManager.shared()
        let candidates = manager.connectedAccessories.filter {
            $0.protocolStrings.contains(endpoint.accessoryProtocol)
        }

        // Con varios cables conectados, el puerto puede fijar cual usar por
        // numero de serie; si no, se toma el primero que coincida.
        let accessory: EAAccessory?
        if let serial = endpoint.accessorySerialNumber, !serial.isEmpty {
            accessory = candidates.first { $0.serialNumber == serial }
        } else {
            accessory = candidates.first
        }

        guard let accessory else {
            throw manager.connectedAccessories.isEmpty
                ? TransportError.accessoryNotFound
                : TransportError.accessoryProtocolMismatch(endpoint.accessoryProtocol)
        }

        guard let session = EASession(accessory: accessory, forProtocol: endpoint.accessoryProtocol) else {
            throw TransportError.accessoryProtocolMismatch(endpoint.accessoryProtocol)
        }
        self.session = session

        try applyLineConfiguration(machine)

        // Los streams de EASession trabajan sobre un run loop. Los montamos en
        // el principal: las escrituras van por bloques y ceden el control en
        // cada await, asi que no bloquean la interfaz.
        session.outputStream?.delegate = self
        session.outputStream?.schedule(in: .main, forMode: .default)
        session.outputStream?.open()

        session.inputStream?.delegate = self
        session.inputStream?.schedule(in: .main, forMode: .default)
        session.inputStream?.open()

        try await withTimeout(
            seconds: 5,
            message: L10n.text("abriendo el cable serial")
        ) { [weak self] in
            try await self?.waitForSpace()
        }
        #else
        throw TransportError.accessoryNotFound
        #endif
    }

    /// PUNTO DE INTEGRACION del SDK del cable.
    ///
    /// La API publica de ExternalAccessory no permite fijar la linea, asi que
    /// aqui solo validamos. Con el SDK de Redpark, esto seria:
    ///
    /// ```swift
    /// rscMgr.setBaud(Int32(machine.baudRate))
    /// rscMgr.setDataSize(...)
    /// rscMgr.setParity(...)
    /// rscMgr.setStopBits(...)
    /// ```
    private func applyLineConfiguration(_ machine: Machine) throws {
        // Sin SDK del fabricante el cable usa la configuracion que traiga por
        // defecto. Si no coincide con la maquina, la CNC recibira basura, asi
        // que es mejor decirlo que fallar en silencio en el taller.
        assert(
            machine.baudRate > 0,
            L10n.format("Perfil invalido: revisa el baudrate de %@", machine.name)
        )
    }

    // MARK: - Escritura

    func write(_ data: Data) async throws {
        #if canImport(ExternalAccessory)
        guard let stream = session?.outputStream else { throw TransportError.notConnected }
        try Task.checkCancellation()
        try await awaitFlowResume()

        if firstWriteAt == nil { firstWriteAt = Date() }

        var remaining = data
        while !remaining.isEmpty {
            try Task.checkCancellation()
            try await awaitFlowResume()

            if !stream.hasSpaceAvailable {
                hasSpace = false
                try await withTimeout(
                    seconds: 60,
                    message: L10n.text("esperando espacio en el cable")
                ) { [weak self] in
                    try await self?.waitForSpace()
                }
            }

            let written = remaining.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return stream.write(base, maxLength: remaining.count)
            }

            if written < 0 {
                let detail = stream.streamError?.localizedDescription
                    ?? L10n.text("el cable rechazo los datos")
                throw TransportError.writeFailed(detail)
            }
            if written == 0 {
                hasSpace = false
                continue
            }
            remaining = remaining.dropFirst(written)
            bytesWritten += written
        }
        #else
        throw TransportError.notConnected
        #endif
    }

    func drain(dripFeed: Bool) async throws {
        // El cable tiene su propio FIFO: esperamos lo que tarde en salir a la
        // velocidad de la linea antes de cerrar, o se pierde la cola.
        if let machine, let start = firstWriteAt {
            let physical = machine.transmissionTime(forBytes: bytesWritten)
            let remaining = physical - Date().timeIntervalSince(start)
            if remaining > 0 {
                try await Task.sleep(for: .seconds(remaining))
            }
        }
        try await Task.sleep(for: .milliseconds(300))
    }

    func close() async {
        #if canImport(ExternalAccessory)
        if let output = session?.outputStream {
            output.close()
            output.remove(from: .main, forMode: .default)
            output.delegate = nil
        }
        if let input = session?.inputStream {
            input.close()
            input.remove(from: .main, forMode: .default)
            input.delegate = nil
        }
        session = nil
        #endif
        releaseFlowWaiters()
        releaseSpaceWaiters()
    }

    // MARK: - Esperas

    private func waitForSpace() async {
        guard !hasSpace else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            spaceWaiters.append(cont)
        }
    }

    private func awaitFlowResume() async throws {
        guard flowPaused else { return }
        let deadline = (machine?.dripFeed ?? false) ? nil : Date().addingTimeInterval(120)
        while flowPaused {
            if let deadline, Date() > deadline {
                throw TransportError.timeout(
                    L10n.text("esperando a que la maquina reciba (XOFF sin XON)")
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

    private func releaseSpaceWaiters() {
        let waiters = spaceWaiters
        spaceWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func handleIncoming(_ data: Data) {
        guard machine?.flowControl == .xonXoff else { return }
        for byte in data {
            if byte == 0x13 {
                flowPaused = true
            } else if byte == 0x11 {
                flowPaused = false
                releaseFlowWaiters()
            }
        }
    }
}

#if canImport(ExternalAccessory)
extension MFiSerialTransport: StreamDelegate {
    nonisolated func stream(_ stream: Stream, handle eventCode: Stream.Event) {
        // Los streams estan montados en el run loop principal, asi que este
        // callback ya llega en el main actor. Leemos aqui, antes del salto,
        // porque `Stream` no es Sendable y no se puede cruzar el limite de
        // aislamiento — pero `Data` si.
        var incoming: Data?
        if eventCode == .hasBytesAvailable, let input = stream as? InputStream {
            var buffer = [UInt8](repeating: 0, count: 512)
            let read = input.read(&buffer, maxLength: buffer.count)
            if read > 0 { incoming = Data(buffer[0..<read]) }
        }

        MainActor.assumeIsolated {
            switch eventCode {
            case .hasSpaceAvailable:
                hasSpace = true
                releaseSpaceWaiters()

            case .hasBytesAvailable:
                if let incoming { handleIncoming(incoming) }

            case .errorOccurred, .endEncountered:
                releaseSpaceWaiters()
                releaseFlowWaiters()

            default:
                break
            }
        }
    }
}
#endif
