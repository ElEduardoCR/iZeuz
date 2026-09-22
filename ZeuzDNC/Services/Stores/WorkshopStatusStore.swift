import Foundation

/// Un Zeuz fisico y las maquinas que Zeuz Agent dirige hacia el. El `id` es
/// el destino de red, no la maquina seleccionada, para que una sola consulta
/// represente correctamente a una Raspberry con varios perfiles.
struct ZeuzMachineGroup: Identifiable, Sendable {
    let id: String
    let host: String?
    let port: Int?
    let machines: [ZeuzBridgeClient.PiMachine]

    var displayName: String {
        guard let host else { return L10n.text("Zeuz") }
        let clean = host.lowercased().hasSuffix(".local")
            ? String(host.dropLast(".local".count))
            : host
        if clean.caseInsensitiveCompare("zeuz") == .orderedSame {
            return L10n.text("Zeuz")
        }
        let prefix = "zeuz-dnc-"
        if clean.lowercased().hasPrefix(prefix) {
            return "Zeuz \(clean.dropFirst(prefix.count).uppercased())"
        }
        return clean
    }

    var address: String? {
        guard let host else { return nil }
        return port.map { "\(host):\($0)" } ?? host
    }

    var machineNames: [String] {
        machines.map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var representativeMachineID: String { machines[0].id }
}

struct ZeuzWorkshopStatus: Identifiable, Sendable {
    let group: ZeuzMachineGroup
    var transfer: ZeuzBridgeClient.PiTransfer?
    var errorMessage: String?
    var lastUpdated: Date?
    var update: ZeuzUpdateState?
    var updateError: String?

    var id: String { group.id }
    var isSending: Bool { transfer?.status == "sending" }
}

/// Monitor de solo lectura para todos los Zeuz configurados en el taller.
///
/// Al regresar del bloqueo de pantalla se crea un sondeo nuevo y el avance se
/// reconstruye desde cada Pi. Nada de este tipo inicia, selecciona o cancela
/// una transferencia.
@MainActor
@Observable
final class WorkshopStatusStore {
    private(set) var zeuz: [ZeuzWorkshopStatus] = []
    private(set) var isRefreshing = false
    private(set) var discoveryError: String?
    private(set) var lastRefresh: Date?

    private(set) var updateActions: Set<String> = []

    private var monitoringTask: Task<Void, Never>?

    var hasActiveTransfers: Bool { zeuz.contains(where: \.isSending) }
    var activeTransferCount: Int { zeuz.count(where: \.isSending) }

    static func groups(from machines: [ZeuzBridgeClient.PiMachine]) -> [ZeuzMachineGroup] {
        let grouped = Dictionary(grouping: machines) { machine in
            guard let host = machine.dncHost?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !host.isEmpty
            else {
                // Una conexion directa recibe todas las maquinas de una sola
                // Pi y no trae campos dnc_host/dnc_port.
                return "direct-zeuz"
            }
            return "\(host.lowercased()):\(machine.dncPort ?? 5000)"
        }

        return grouped.map { key, values in
            let first = values[0]
            return ZeuzMachineGroup(
                id: key,
                host: first.dncHost,
                port: first.dncPort,
                machines: values.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func start(client: any ZeuzDNCClient) {
        stop()
        monitoringTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refresh(client: client)
                guard !Task.isCancelled else { return }
                let interval: Duration = self.hasActiveTransfers ? .seconds(1) : .seconds(4)
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    func updateDevice(_ item: ZeuzWorkshopStatus, client: any ZeuzDNCClient, action: String, autoInstall: Bool? = nil) async {
        guard !updateActions.contains(item.id) else { return }
        updateActions.insert(item.id)
        defer { updateActions.remove(item.id) }
        do {
            let value = try await client.update(machineID: item.group.representativeMachineID, action: action,
                revision: action == "install" ? item.update?.latest_revision : nil,
                requestID: action == "install" ? UUID().uuidString : nil, autoInstall: autoInstall)
            if let index = zeuz.firstIndex(where: { $0.id == item.id }) {
                zeuz[index].update = value
                zeuz[index].updateError = nil
            }
        } catch {
            if let index = zeuz.firstIndex(where: { $0.id == item.id }) { zeuz[index].updateError = error.localizedDescription }
        }
    }

    func refresh(client: any ZeuzDNCClient) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let groups: [ZeuzMachineGroup]
        do {
            groups = Self.groups(from: try await client.machines())
            discoveryError = nil
        } catch {
            guard !Task.isCancelled else { return }
            discoveryError = error.localizedDescription
            return
        }

        struct Probe: Sendable {
            let group: ZeuzMachineGroup
            let transfer: ZeuzBridgeClient.PiTransfer?
            let errorMessage: String?
            let update: ZeuzUpdateState?
            let updateError: String?
        }

        let probes = await withTaskGroup(of: Probe.self, returning: [Probe].self) { taskGroup in
            for group in groups {
                taskGroup.addTask {
                    var update: ZeuzUpdateState?
                    var updateError: String?
                    do { update = try await client.update(machineID: group.representativeMachineID, action: "status") }
                    catch { updateError = error.localizedDescription }
                    do {
                        let transfer = try await client.status(
                            machineID: group.representativeMachineID
                        )
                        return Probe(group: group, transfer: transfer, errorMessage: nil, update: update, updateError: updateError)
                    } catch {
                        return Probe(
                            group: group,
                            transfer: nil,
                            errorMessage: error.localizedDescription, update: update, updateError: updateError
                        )
                    }
                }
            }

            var values: [Probe] = []
            for await probe in taskGroup { values.append(probe) }
            return values
        }

        guard !Task.isCancelled else { return }
        let previous = Dictionary(uniqueKeysWithValues: zeuz.map { ($0.id, $0) })
        let now = Date()
        zeuz = probes.map { probe in
            if let transfer = probe.transfer {
                return ZeuzWorkshopStatus(
                    group: probe.group,
                    transfer: transfer,
                    errorMessage: nil,
                    lastUpdated: now,
                    update: probe.update ?? previous[probe.group.id]?.update, updateError: probe.updateError
                )
            }

            // No conviertas una pausa breve del Wi-Fi en un falso "detenido":
            // se conserva el ultimo avance y se marca como ultimo dato conocido.
            return ZeuzWorkshopStatus(
                group: probe.group,
                transfer: previous[probe.group.id]?.transfer,
                errorMessage: probe.errorMessage,
                lastUpdated: previous[probe.group.id]?.lastUpdated,
                update: probe.update ?? previous[probe.group.id]?.update, updateError: probe.updateError
            )
        }
        .sorted {
            if $0.isSending != $1.isSending { return $0.isSending }
            return $0.group.displayName.localizedCaseInsensitiveCompare($1.group.displayName)
                == .orderedAscending
        }
        lastRefresh = now
    }
}
