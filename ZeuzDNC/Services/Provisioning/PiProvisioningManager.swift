import Foundation
import Observation
@preconcurrency import CoreBluetooth

struct NearbyZeuzPi: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var rssi: Int
}

struct ProvisionedZeuzPi: Equatable, Sendable {
    let id: UUID
    let name: String
    let host: String
    let ip: String
    let port: Int
    let machine: Machine
}

@MainActor
@Observable
final class PiProvisioningManager: NSObject,
    @preconcurrency CBCentralManagerDelegate,
    @preconcurrency CBPeripheralDelegate
{
    enum Stage: Equatable {
        case idle
        case scanning
        case connecting
        case readyForCredentials
        case joiningWiFi
        case completed
        case failed(String)
    }

    static let serviceUUID = CBUUID(string: "7C1E0001-7A6B-4F8A-9D0E-5E7A45555A31")
    static let statusUUID = CBUUID(string: "7C1E0002-7A6B-4F8A-9D0E-5E7A45555A31")
    static let commandUUID = CBUUID(string: "7C1E0003-7A6B-4F8A-9D0E-5E7A45555A31")

    private(set) var nearby: [NearbyZeuzPi] = []
    private(set) var stage: Stage = .idle
    private(set) var selectedID: UUID?
    private(set) var provisionedPi: ProvisionedZeuzPi?
    private(set) var bluetoothAvailable = false

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var activePeripheral: CBPeripheral?
    @ObservationIgnored private var statusCharacteristic: CBCharacteristic?
    @ObservationIgnored private var commandCharacteristic: CBCharacteristic?
    @ObservationIgnored private var pendingWrites: [Data] = []
    @ObservationIgnored private var pendingMachine: Machine?
    @ObservationIgnored private var networkConfirmationTask: Task<Void, Never>?

    private static let pendingMachineKey = "zeuzdnc.pendingProvisionedMachine"

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: Self.pendingMachineKey) {
            pendingMachine = try? JSONDecoder().decode(Machine.self, from: data)
        }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startScanning() {
        guard provisionedPi == nil else { return }
        if central.state == .poweredOn {
            scan()
        } else if central.state == .unauthorized || central.state == .unsupported {
            stage = .failed("Bluetooth no está disponible o no tiene permiso")
        }
    }

    func stopScanning() {
        central.stopScan()
        if stage == .scanning { stage = .idle }
    }

    func reset() {
        networkConfirmationTask?.cancel()
        networkConfirmationTask = nil
        if let activePeripheral {
            central.cancelPeripheralConnection(activePeripheral)
        }
        activePeripheral = nil
        selectedID = nil
        statusCharacteristic = nil
        commandCharacteristic = nil
        pendingWrites = []
        pendingMachine = nil
        UserDefaults.standard.removeObject(forKey: Self.pendingMachineKey)
        provisionedPi = nil
        nearby = []
        startScanning()
    }

    func connect(to id: UUID) {
        guard let peripheral = peripherals[id] else { return }
        central.stopScan()
        selectedID = id
        activePeripheral = peripheral
        peripheral.delegate = self
        stage = .connecting
        central.connect(peripheral)
    }

    func configureWiFi(ssid: String, password: String, machine: Machine) {
        let cleanSSID = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSSID.isEmpty else {
            stage = .failed("Escribe el nombre de la red Wi-Fi")
            return
        }
        guard let peripheral = activePeripheral, let commandCharacteristic else {
            stage = .failed("Zeuz perdió la conexión Bluetooth")
            return
        }
        do {
            let cleanMachine = try machine.validated()
            let commands = [
                try JSONEncoder().encode(MachineCommand(machine: cleanMachine)),
                try JSONEncoder().encode(WiFiCommand(ssid: cleanSSID, password: password)),
            ]
            let maximum = peripheral.maximumWriteValueLength(for: .withResponse)
            guard commands.allSatisfy({ $0.count <= maximum }) else {
                stage = .failed("La configuración es demasiado larga para esta conexión Bluetooth")
                return
            }
            pendingMachine = cleanMachine
            if let data = try? JSONEncoder().encode(cleanMachine) {
                UserDefaults.standard.set(data, forKey: Self.pendingMachineKey)
            }
            pendingWrites = commands
            stage = .joiningWiFi
            writeNextCommand(peripheral, characteristic: commandCharacteristic)
        } catch let error as MachineValidationError {
            stage = .failed(error.localizedDescription)
        } catch {
            stage = .failed("No se pudo preparar la configuración inicial")
        }
    }

    /// Recupera un alta cuyo ultimo aviso BLE se perdio al encender el Wi-Fi.
    /// Tambien permite reconocer una Orange que ya quedo configurada antes de
    /// actualizar la app. La API HTTP es la confirmacion autoritativa: si
    /// responde y devuelve el perfil, Wi-Fi y la maquina quedaron guardados.
    func recoverConfiguredZeuz() async -> Bool {
        if provisionedPi != nil { return true }
        return await completeFromLocalNetwork(preferredMachine: pendingMachine)
    }

    /// Se llama despues de que EndpointStore y MachineStore guardaron el alta.
    /// Hasta entonces conservamos el perfil para poder recuperar un cierre de
    /// iOS entre la conexion al Wi-Fi y la pantalla de confirmacion.
    func markConfigurationSaved() {
        UserDefaults.standard.removeObject(forKey: Self.pendingMachineKey)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothAvailable = central.state == .poweredOn
        switch central.state {
        case .poweredOn:
            scan()
        case .unauthorized:
            stage = .failed("Autoriza Bluetooth para configurar Zeuz")
        case .unsupported:
            stage = .failed("Este iPhone no admite Bluetooth LE")
        case .poweredOff:
            stage = .failed("Activa Bluetooth para buscar Zeuz")
        default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertisedName ?? peripheral.name ?? "Zeuz DNC"
        let advertisedServices =
            advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isZeuzName = normalizedName == "zeuz" || normalizedName.hasPrefix("zeuz-dnc")
        let isZeuzService = advertisedServices.contains(Self.serviceUUID)
        guard isZeuzName || isZeuzService else { return }

        peripherals[peripheral.identifier] = peripheral
        let item = NearbyZeuzPi(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        if let index = nearby.firstIndex(where: { $0.id == item.id }) {
            nearby[index] = item
        } else {
            nearby.append(item)
            nearby.sort { $0.rssi > $1.rssi }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        stage = .failed(error?.localizedDescription ?? "No se pudo conectar con Zeuz")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard stage != .completed else { return }
        // En las Orange con radio Wi-Fi/Bluetooth compartido es normal perder
        // el enlace BLE justo al asociarse a la red. La confirmacion HTTP que
        // ya esta corriendo decide si el alta termino o fallo.
        if stage == .joiningWiFi {
            beginNetworkConfirmation()
            return
        }
        stage = .failed(error?.localizedDescription ?? "Zeuz se desconectó")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            stage = .failed(error.localizedDescription)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            stage = .failed("El dispositivo no ofrece el servicio de configuración Zeuz")
            return
        }
        peripheral.discoverCharacteristics([Self.statusUUID, Self.commandUUID], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            stage = .failed(error.localizedDescription)
            return
        }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case Self.statusUUID: statusCharacteristic = characteristic
            case Self.commandUUID: commandCharacteristic = characteristic
            default: break
            }
        }
        guard let statusCharacteristic, commandCharacteristic != nil else {
            stage = .failed("El servicio Bluetooth de Zeuz está incompleto")
            return
        }
        peripheral.setNotifyValue(true, for: statusCharacteristic)
        peripheral.readValue(for: statusCharacteristic)
        stage = .readyForCredentials
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            stage = .failed(error.localizedDescription)
            return
        }
        guard characteristic.uuid == Self.statusUUID, let data = characteristic.value else { return }
        do {
            let status = try JSONDecoder().decode(PiStatus.self, from: data)
            switch status.state {
            case "ready":
                if stage != .joiningWiFi { stage = .readyForCredentials }
            case "connecting":
                stage = .joiningWiFi
            case "connected":
                guard !status.ip.isEmpty else {
                    stage = .failed("Zeuz se conectó, pero todavía no obtuvo una dirección IP")
                    return
                }
                guard var machine = pendingMachine else {
                    stage = .failed("Zeuz no confirmó la configuración de la máquina")
                    return
                }
                if let machineID = status.machineID, !machineID.isEmpty {
                    machine.id = machineID
                }
                provisionedPi = ProvisionedZeuzPi(
                    id: peripheral.identifier,
                    name: "zeuz",
                    host: SerialEndpoint.zeuzServiceHost(
                        deviceName: status.deviceName,
                        fallback: status.ip
                    ),
                    ip: status.ip,
                    port: status.apiPort,
                    machine: machine
                )
                networkConfirmationTask?.cancel()
                stage = .completed
            case "error":
                stage = .failed(status.error.isEmpty ? "No se pudo conectar al Wi-Fi" : status.error)
            default:
                break
            }
        } catch {
            stage = .failed("Zeuz respondió un estado de configuración inválido")
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            stage = .failed("No se pudieron enviar las credenciales: \(error.localizedDescription)")
            pendingWrites = []
            return
        }
        writeNextCommand(peripheral, characteristic: characteristic)
    }

    private func scan() {
        guard central.state == .poweredOn,
              !central.isScanning,
              provisionedPi == nil
        else { return }
        stage = .scanning
        // BlueZ puede repartir el nombre local y el UUID de servicio entre el
        // anuncio y la scan response. Un filtro previo por UUID hace que iOS
        // descarte el periférico antes de entregar ambas partes. Se escanea sin
        // filtro y didDiscover conserva solamente dispositivos Zeuz.
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    private func writeNextCommand(_ peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        guard !pendingWrites.isEmpty else {
            if stage == .joiningWiFi { beginNetworkConfirmation() }
            return
        }
        let data = pendingWrites.removeFirst()
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
    }

    private func beginNetworkConfirmation() {
        guard networkConfirmationTask == nil, let pendingMachine else { return }
        networkConfirmationTask = Task { [weak self] in
            guard let self else { return }
            for attempt in 0..<30 {
                guard !Task.isCancelled, self.stage == .joiningWiFi else { return }
                if attempt > 0 {
                    try? await Task.sleep(for: .seconds(2))
                }
                guard !Task.isCancelled else { return }
                if await self.completeFromLocalNetwork(preferredMachine: pendingMachine) {
                    return
                }
            }
            guard !Task.isCancelled, self.stage == .joiningWiFi else { return }
            self.stage = .failed(
                "Zeuz no confirmó la conexión. Revisa que el iPhone esté en la misma red Wi-Fi."
            )
            self.networkConfirmationTask = nil
        }
    }

    private func completeFromLocalNetwork(preferredMachine: Machine?) async -> Bool {
        guard let url = URL(string: "http://zeuz.local:5000/api/machines") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.5

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200
            else { return false }
            let remote = try JSONDecoder().decode([ZeuzBridgeClient.PiMachine].self, from: data)
            let selected: Machine?
            if let preferredMachine {
                selected = remote.first {
                    $0.id == preferredMachine.id
                    || $0.name.caseInsensitiveCompare(preferredMachine.name) == .orderedSame
                }?.asMachine
            } else {
                // machines.json conserva el orden de alta. Esto recupera el
                // perfil creado mas recientemente por una version anterior de
                // iZeuz que no alcanzó a guardar su confirmacion local.
                selected = remote.last?.asMachine
            }
            guard let selected else { return false }

            central.stopScan()
            provisionedPi = ProvisionedZeuzPi(
                id: selectedID ?? UUID(),
                name: "zeuz",
                host: "zeuz.local",
                ip: "",
                port: 5000,
                machine: selected
            )
            pendingMachine = selected
            stage = .completed
            return true
        } catch {
            return false
        }
    }

    /// Claves cortas para que cada orden quepa incluso con un MTU BLE de 185.
    private struct WiFiCommand: Encodable {
        let action = "wifi"
        let ssid: String
        let password: String

        enum CodingKeys: String, CodingKey {
            case action
            case ssid = "s"
            case password = "p"
        }
    }

    private struct MachineCommand: Encodable {
        let action = "machine"
        let machine: MachinePayload

        init(machine: Machine) {
            self.machine = MachinePayload(machine)
        }

        enum CodingKeys: String, CodingKey {
            case action
            case machine = "m"
        }
    }

    private struct MachinePayload: Encodable {
        let name: String
        let baudRate: Int
        let dataBits: Int
        let parity: String
        let stopBits: Int
        let flowControl: String
        let lineTerminator: String
        let dtr: Bool
        let rts: Bool
        let dripFeed: Bool

        init(_ machine: Machine) {
            name = machine.name
            baudRate = machine.baudRate
            dataBits = machine.dataBits
            parity = machine.parity.rawValue
            stopBits = machine.stopBits
            flowControl = machine.flowControl.rawValue
            lineTerminator = machine.lineTerminator.rawValue
            dtr = machine.dtr
            rts = machine.rts
            dripFeed = machine.dripFeed
        }

        enum CodingKeys: String, CodingKey {
            case name = "n"
            case baudRate = "b"
            case dataBits = "d"
            case parity = "p"
            case stopBits = "s"
            case flowControl = "f"
            case lineTerminator = "l"
            case dtr = "t"
            case rts = "r"
            case dripFeed = "g"
        }
    }

    private struct PiStatus: Decodable {
        let deviceName: String
        let state: String
        let ip: String
        let apiPort: Int
        let error: String
        let machineID: String?

        enum CodingKeys: String, CodingKey {
            case state, ip, error
            case deviceName = "device_name"
            case apiPort = "api_port"
            case machineID = "machine_id"
        }
    }
}
