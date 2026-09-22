import Foundation

/// Perfil de una maquina CNC: como hay que abrir el puerto serial para que
/// acepte el programa. Los valores replican los de `config/machines.json`
/// del ZeuzDNC de la Raspberry Pi para que los perfiles sean intercambiables.
struct Machine: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var revision: Int?
    var name: String
    var baudRate: Int
    var dataBits: Int
    var parity: Parity
    var stopBits: Int
    var flowControl: FlowControl
    var lineTerminator: LineTerminator
    /// pyserial ENCIENDE DTR/RTS al abrir; muchas configuraciones de PC que
    /// funcionan las tienen apagadas y algunas maquinas no aceptan datos si no
    /// coinciden. Por eso el default es apagado, igual que en la Pi.
    var dtr: Bool
    var rts: Bool
    /// Goteo: la maquina ejecuta mientras recibe y frena con el control de
    /// flujo. En ese modo no se aplican timeouts de escritura.
    var dripFeed: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        baudRate: Int = 9600,
        dataBits: Int = 8,
        parity: Parity = .none,
        stopBits: Int = 1,
        flowControl: FlowControl = .xonXoff,
        lineTerminator: LineTerminator = .crlf,
        dtr: Bool = false,
        rts: Bool = false,
        dripFeed: Bool = false,
        revision: Int? = nil
    ) {
        self.id = id
        self.revision = revision
        self.name = name
        self.baudRate = baudRate
        self.dataBits = dataBits
        self.parity = parity
        self.stopBits = stopBits
        self.flowControl = flowControl
        self.lineTerminator = lineTerminator
        self.dtr = dtr
        self.rts = rts
        self.dripFeed = dripFeed
    }
}

extension Machine {
    enum Parity: String, Codable, CaseIterable, Hashable, Sendable {
        case none = "N"
        case even = "E"
        case odd = "O"
        case mark = "M"
        case space = "S"

        var label: String {
            switch self {
            case .none: L10n.text("Ninguna")
            case .even: L10n.text("Par")
            case .odd: L10n.text("Impar")
            case .mark: L10n.text("Mark")
            case .space: L10n.text("Space")
            }
        }
    }

    enum FlowControl: String, Codable, CaseIterable, Hashable, Sendable {
        case xonXoff = "xonxoff"
        case rtsCts = "rtscts"
        case none = "none"

        var label: String {
            switch self {
            case .xonXoff: L10n.text("XON/XOFF (software)")
            case .rtsCts: L10n.text("RTS/CTS (hardware)")
            case .none: L10n.text("Ninguno")
            }
        }
    }

    enum LineTerminator: String, Codable, CaseIterable, Hashable, Sendable {
        case cr = "CR"
        case crlf = "CRLF"
        case lf = "LF"

        var bytes: String {
            switch self {
            case .cr: "\r"
            case .crlf: "\r\n"
            case .lf: "\n"
            }
        }

        var label: String {
            switch self {
            case .cr: L10n.text("CR (retorno de carro)")
            case .crlf: L10n.text("CRLF (retorno + salto)")
            case .lf: L10n.text("LF (salto de linea)")
            }
        }
    }

    /// Resumen corto para mostrar en la lista: "9600 8N1 · XON/XOFF · CRLF".
    var summary: String {
        let frame = "\(dataBits)\(parity.rawValue)\(stopBits)"
        let flow: String = switch flowControl {
        case .xonXoff: "XON/XOFF"
        case .rtsCts: "RTS/CTS"
        case .none: L10n.text("sin flujo")
        }
        return "\(baudRate) \(frame) · \(flow) · \(lineTerminator.rawValue)"
    }

    /// Valores tipicos de referencia, iguales a los del proyecto de la Pi.
    /// CONFIRMALOS contra el manual de cada control antes de produccion.
    static let defaults: [Machine] = [
        Machine(
            id: "fanuc",
            name: "Fanuc",
            baudRate: 4800,
            dataBits: 7,
            parity: .even,
            stopBits: 2,
            flowControl: .xonXoff,
            lineTerminator: .cr
        ),
        Machine(
            id: "fadal",
            name: "Fadal",
            baudRate: 9600,
            dataBits: 8,
            parity: .none,
            stopBits: 1,
            flowControl: .xonXoff,
            lineTerminator: .crlf
        ),
    ]

    static let baudRateOptions = [
        110, 300, 600, 1200, 2400, 4800, 9600, 14400,
        19200, 38400, 57600, 115200, 128000, 256000,
    ]
}

/// Errores de validacion al dar de alta o editar una maquina.
enum MachineValidationError: LocalizedError {
    case emptyName
    case invalidBaudRate
    case invalidDataBits
    case invalidStopBits

    var errorDescription: String? {
        switch self {
        case .emptyName: L10n.text("El nombre es obligatorio")
        case .invalidBaudRate: L10n.text("El baudrate debe ser mayor que cero")
        case .invalidDataBits: L10n.text("Los bits de datos deben ser 5, 6, 7 u 8")
        case .invalidStopBits: L10n.text("Los bits de stop deben ser 1 o 2")
        }
    }
}

extension Machine {
    func validated() throws -> Machine {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.name.isEmpty else { throw MachineValidationError.emptyName }
        guard baudRate > 0 else { throw MachineValidationError.invalidBaudRate }
        guard (5...8).contains(dataBits) else { throw MachineValidationError.invalidDataBits }
        guard (1...2).contains(stopBits) else { throw MachineValidationError.invalidStopBits }
        return copy
    }
}
