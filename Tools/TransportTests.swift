import Foundation

// Banco de pruebas del nucleo de envio: compila los mismos archivos de la app
// (sin SwiftUI ni SMB) y los ejerce de verdad contra un puente TCP.

var failures = 0

@MainActor func check(_ label: String, _ passed: Bool, detail: String = "") {
    if passed {
        print("  OK   \(label)")
    } else {
        failures += 1
        print("  FALLA \(label) \(detail)")
    }
}

func hex(_ data: Data) -> String {
    data.map { String(format: "%02X", $0) }.joined(separator: " ")
}

// MARK: - 1. Conversion de fin de linea

print("\n[1] preparePayload: conversion de terminador")

let source = "O1234\nG00 X0 Y0\nM30\n"

let cr = GCodeSender.preparePayload(content: source, terminator: .cr)
check(
    "CR usa 0x0D y no mete 0x0A",
    cr == Data("O1234\rG00 X0 Y0\rM30\r".utf8),
    detail: hex(cr)
)

let crlf = GCodeSender.preparePayload(content: source, terminator: .crlf)
check(
    "CRLF usa 0x0D 0x0A",
    crlf == Data("O1234\r\nG00 X0 Y0\r\nM30\r\n".utf8),
    detail: hex(crlf)
)

// Un archivo que llega de Windows ya trae CRLF: no debe duplicarse.
let fromWindows = "O1234\r\nM30\r\n"
let reconverted = GCodeSender.preparePayload(content: fromWindows, terminator: .cr)
check(
    "un archivo CRLF de Windows no duplica el CR al pasar a CR",
    reconverted == Data("O1234\rM30\r".utf8),
    detail: hex(reconverted)
)

// Sin salto final, tampoco debe faltar el terminador de la ultima linea.
let noTrailing = GCodeSender.preparePayload(content: "M30", terminator: .crlf)
check(
    "la ultima linea sin salto igual termina con el terminador",
    noTrailing == Data("M30\r\n".utf8),
    detail: hex(noTrailing)
)

check(
    "un programa vacio produce 0 bytes",
    GCodeSender.preparePayload(content: "", terminator: .cr).isEmpty
)

// MARK: - 2. Encabezado de programa

print("\n[2] Descriptor del encabezado de programa")

check(
    "extrae el parentesis que sigue a OXXXX",
    ProgramEntry.descriptor(in: "%\r\nO0200 (16-312-2)\r\nG00 X0") == "(16-312-2)"
)
check(
    "no agrega texto cuando OXXXX no lleva parentesis",
    ProgramEntry.descriptor(in: "O0050\r\nG00 X0 (comentario)") == nil
)
check(
    "acepta el parentesis junto al numero",
    ProgramEntry.descriptor(in: "O1234(PIEZA A)\nM30") == "(PIEZA A)"
)

// MARK: - 3. Tiempos de linea

print("\n[3] Calculo de tiempo fisico de transmision")

// Fanuc: 4800 baud, 7E2 -> 1 start + 7 datos + 1 paridad + 2 stop = 11 bits.
let fanuc = Machine.defaults[0]
check(
    "Fanuc 7E2 son 11 bits por byte",
    fanuc.bitsPerByte == 11,
    detail: "\(fanuc.bitsPerByte)"
)
check(
    "Fanuc a 4800 baud da ~436 bytes/s",
    abs(fanuc.bytesPerSecond - 4800.0 / 11.0) < 0.01,
    detail: "\(fanuc.bytesPerSecond)"
)

// Fadal: 9600 baud, 8N1 -> 1 + 8 + 0 + 1 = 10 bits.
let fadal = Machine.defaults[1]
check("Fadal 8N1 son 10 bits por byte", fadal.bitsPerByte == 10, detail: "\(fadal.bitsPerByte)")
check(
    "1000 bytes a 9600 8N1 tardan ~1.04 s",
    abs(fadal.transmissionTime(forBytes: 1000) - 1.0416) < 0.01,
    detail: "\(fadal.transmissionTime(forBytes: 1000))"
)

// MARK: - 4. Envio real por TCP

@MainActor func runTransfer(
    port: Int,
    machine: Machine,
    content: String
) async -> (events: [String], sentBytes: Int) {
    let endpoint = SerialEndpoint(
        name: "Prueba",
        kind: .networkBridge,
        host: "127.0.0.1",
        port: port
    )
    let transport = NetworkBridgeTransport(endpoint: endpoint)
    let payload = GCodeSender.preparePayload(content: content, terminator: machine.lineTerminator)

    var events: [String] = []
    var sent = 0
    for await event in GCodeSender.send(payload: payload, machine: machine, transport: transport) {
        switch event {
        case .connecting: events.append("connecting")
        case .started(let total): events.append("started(\(total))")
        case .progress(let bytes): sent = bytes
        case .finishing: events.append("finishing")
        case .finished: events.append("finished")
        case .cancelled: events.append("cancelled")
        case .failed(let message): events.append("failed(\(message))")
        }
    }
    return (events, sent)
}

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    print("\nuso: harness <puertoSimple> <puertoFlujo> <archivoEsperado>")
    exit(failures > 0 ? 1 : 0)
}

let simplePort = Int(arguments[1])!
let flowPort = Int(arguments[2])!
let program = "O0001\nG21 G90\nG00 X10. Y10.\nG01 Z-5. F100\nM30\n"

print("\n[4] Envio real contra un puente TCP")

// Baudrate alto para que la prueba no tarde: el drain espera el tiempo fisico.
var fastMachine = Machine(
    name: "Prueba",
    baudRate: 115200,
    dataBits: 8,
    parity: .none,
    stopBits: 1,
    flowControl: .none,
    lineTerminator: .crlf
)

let simple = await runTransfer(port: simplePort, machine: fastMachine, content: program)
check(
    "la transferencia termina en 'finished'",
    simple.events.contains("finished"),
    detail: simple.events.joined(separator: ", ")
)
let expectedBytes = GCodeSender.preparePayload(content: program, terminator: .crlf).count
check(
    "el progreso reporta los \(expectedBytes) bytes del programa",
    simple.sentBytes == expectedBytes,
    detail: "reporto \(simple.sentBytes)"
)

// MARK: - 5. Control de flujo XON/XOFF

print("\n[5] Control de flujo: la maquina manda XOFF y el envio se pausa")

var flowMachine = fastMachine
flowMachine.flowControl = .xonXoff

// Un programa grande: con 256 bytes por bloque hacen falta muchos bloques
// para que el XOFF alcance a frenar el envio a mitad de camino.
let bigProgram = (1...400)
    .map { "N\($0 * 10) G01 X\($0).0 Y\($0).5 F120" }
    .joined(separator: "\n")

let started = Date()
let flow = await runTransfer(port: flowPort, machine: flowMachine, content: bigProgram)
let elapsed = Date().timeIntervalSince(started)

check(
    "termina bien despues del XON",
    flow.events.contains("finished"),
    detail: flow.events.joined(separator: ", ")
)
// El puente falso manda XOFF al conectar y XON 0.9 s despues. Si el envio
// respeto la pausa, el total no puede haber sido casi instantaneo.
check(
    "el envio se pauso de verdad al recibir XOFF (tardo \(String(format: "%.2f", elapsed)) s)",
    elapsed > 0.8,
    detail: "tardo \(elapsed) s, se esperaba > 0.8 s"
)

// MARK: - 6. Puerto inalcanzable

print("\n[6] Puente apagado: falla con un mensaje entendible")

let deadEndpoint = SerialEndpoint(
    name: "Apagado",
    kind: .networkBridge,
    host: "127.0.0.1",
    port: 1  // nadie escucha aqui
)
let deadTransport = NetworkBridgeTransport(endpoint: deadEndpoint)
var deadEvents: [String] = []
for await event in GCodeSender.send(
    payload: Data("M30\r\n".utf8),
    machine: fastMachine,
    transport: deadTransport
) {
    if case .failed(let message) = event { deadEvents.append(message) }
}
check(
    "reporta un error de conexion en vez de colgarse",
    deadEvents.contains { $0.contains("No se pudo conectar") },
    detail: deadEvents.joined(separator: " | ")
)

// MARK: - 7. Rutas SMB seguras

print("\n[7] Saneado de rutas (path traversal)")

check(
    "'..' no puede salirse de la carpeta compartida",
    SMBPath.sanitize("../../etc/passwd") == "etc/passwd",
    detail: SMBPath.sanitize("../../etc/passwd")
)
check(
    "se normalizan las barras invertidas de Windows",
    SMBPath.sanitize("sub\\carpeta\\O123.NC") == "sub/carpeta/O123.NC"
)
check(
    "el breadcrumb arma bien los niveles",
    SMBPath.breadcrumb(for: "torno/2026").map(\.path) == ["", "torno", "torno/2026"]
)

print("\n\(failures == 0 ? "TODO OK" : "\(failures) PRUEBAS FALLARON")")
exit(failures > 0 ? 1 : 0)
