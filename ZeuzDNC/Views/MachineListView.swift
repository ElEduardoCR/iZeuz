import SwiftUI

/// Selección y edición de perfiles compartidos con Agent y la pantalla táctil.
struct MachineListView: View {
    @Environment(AppModel.self) private var model
    @Environment(MachineStore.self) private var machines
    @Environment(\.dismiss) private var dismiss

    @State private var isSyncing = false
    @State private var syncError: String?
    @State private var editingMachine: Machine?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(machines.machines) { machine in
                        row(machine)
                    }
                } header: {
                    Text("Maquinas dadas de alta")
                } footer: {
                    Text("Edita los parámetros seriales aquí o en Zeuz Agent y la pantalla táctil. Los cambios se sincronizan cuando los equipos están conectados.")
                }
            }
            .navigationTitle("Maquinas")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { syncBar }
            .overlay {
                if machines.machines.isEmpty {
                    EmptyStateView(
                        icon: "gearshape.2",
                        title: "Sin maquinas",
                        message: machines.lastSync == nil
                            ? "Conecta Zeuz Agent y actualiza la lista."
                            : "Agrega la primera máquina desde Zeuz Agent y vuelve a actualizar.",
                        actionTitle: "Actualizar desde Zeuz Agent",
                        action: { Task { await sync() } }
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Listo") { dismiss() }
                }
            }
            .sheet(item: $editingMachine) { MachineEditorView(machine: $0) }
            .task {
                await sync()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    if Task.isCancelled { break }
                    await model.checkMachineSynchronization()
                }
            }
            .alert("No se pudo sincronizar", isPresented: Binding(
                get: { syncError != nil },
                set: { if !$0 { syncError = nil } }
            )) {
                Button("Entendido", role: .cancel) { syncError = nil }
            } message: {
                Text(syncError ?? "")
            }
        }
    }

    // MARK: - Sincronizacion

    private var syncBar: some View {
        VStack(spacing: 8) {
            Button {
                Task { await sync() }
            } label: {
                HStack(spacing: 8) {
                    if isSyncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text(isSyncing ? L10n.text("Actualizando…") : "Actualizar desde Zeuz Agent")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .disabled(isSyncing)

            Text(syncStatus)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var syncStatus: String {
        guard let last = machines.lastSync else {
            return L10n.text("iZeuz mostrará las máquinas configuradas en Zeuz Agent.")
        }
        return L10n.format(
            "Ultima sincronizacion: %@",
            last.formatted(date: .omitted, time: .shortened)
        )
    }

    private func sync() async {
        isSyncing = true
        defer { isSyncing = false }
        syncError = await model.syncMachinesFromZeuzDNC()
    }

    private func row(_ machine: Machine) -> some View {
        HStack(spacing: 12) {
            Button {
                machines.select(machine)
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: machines.selectedID == machine.id
                        ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(machines.selectedID == machine.id ? ZeuzPalette.ready : .secondary)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(machine.name)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                            if machines.isZeuzBacked(machine) {
                                Text("ZEUZ")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(ZeuzPalette.accent.opacity(0.2), in: .capsule)
                                    .foregroundStyle(ZeuzPalette.accent)
                            }
                            if machine.dripFeed {
                                Text("GOTEO")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(ZeuzPalette.warning.opacity(0.2), in: .capsule)
                                    .foregroundStyle(ZeuzPalette.warning)
                            }
                        }
                        Text(machine.summary)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Button("Editar", systemImage: "slider.horizontal.3") {
                editingMachine = machine
            }
            .labelStyle(.iconOnly)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("Editar \(machine.name)")
            .buttonStyle(.borderless)
            .disabled(!machines.isZeuzBacked(machine))
        }
    }
}

/// Alta y edicion de un perfil de maquina.
struct MachineEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(MachineStore.self) private var machines
    @Environment(\.dismiss) private var dismiss

    /// nil = alta nueva.
    let machine: Machine?

    @State private var draft: Machine
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var confirmsDelete = false

    init(machine: Machine?) {
        self.machine = machine
        _draft = State(initialValue: machine ?? Machine(name: ""))
    }

    private var isNew: Bool { machine == nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identificacion") {
                    TextField("Nombre de la maquina", text: $draft.name)
                        .autocorrectionDisabled()
                }

                Section {
                    Picker("Baudrate", selection: $draft.baudRate) {
                        ForEach(Machine.baudRateOptions, id: \.self) { rate in
                            Text("\(rate)").tag(rate)
                        }
                    }

                    Picker("Bits de datos", selection: $draft.dataBits) {
                        ForEach([5, 6, 7, 8], id: \.self) { bits in
                            Text("\(bits)").tag(bits)
                        }
                    }

                    Picker("Paridad", selection: $draft.parity) {
                        ForEach(Machine.Parity.allCases, id: \.self) { parity in
                            Text(parity.label).tag(parity)
                        }
                    }

                    Picker("Bits de stop", selection: $draft.stopBits) {
                        Text("1").tag(1)
                        Text("2").tag(2)
                    }
                } header: {
                    Text("Puerto serial")
                } footer: {
                    Text("Actual: \(draft.summary)")
                        .font(.caption.monospaced())
                }

                Section("Control de flujo") {
                    Picker("Control de flujo", selection: $draft.flowControl) {
                        ForEach(Machine.FlowControl.allCases, id: \.self) { flow in
                            Text(flow.label).tag(flow)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section {
                    Picker("Fin de linea", selection: $draft.lineTerminator) {
                        ForEach(Machine.LineTerminator.allCases, id: \.self) { term in
                            Text(term.label).tag(term)
                        }
                    }
                } header: {
                    Text("Fin de linea")
                } footer: {
                    Text("Se aplica al enviar. El archivo del programa no se modifica.")
                }

                Section {
                    Toggle("DTR encendido", isOn: $draft.dtr)
                    Toggle("RTS encendido", isOn: $draft.rts)
                        .disabled(draft.flowControl == .rtsCts)
                } header: {
                    Text("Lineas de control")
                } footer: {
                    Text(L10n.text(
                        draft.flowControl == .rtsCts
                            ? "Con RTS/CTS la linea RTS la maneja el control de flujo."
                            : "Muchas configuraciones de PC que funcionan tienen DTR y RTS apagados. Si la maquina no acepta datos, prueba a cambiarlos."
                    ))
                }

                Section {
                    Toggle("Modo goteo (drip-feed)", isOn: $draft.dripFeed)
                } footer: {
                    Text(L10n.text(
                        "La maquina ejecuta mientras recibe y frena el envio con el control de flujo. Sin limite de tiempo: solo se detiene con CANCELAR."
                    ))
                }

                if !isNew {
                    Section {
                        Button("Eliminar maquina", role: .destructive) {
                            confirmsDelete = true
                        }
                        .disabled(isSaving)
                    }
                }
            }
            .interactiveDismissDisabled(isSaving)
            .confirmationDialog("¿Eliminar esta máquina de los equipos sincronizados?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Eliminar máquina", role: .destructive) { Task { await delete() } }
                Button("Cancelar", role: .cancel) {}
            }
            .navigationTitle(isNew ? L10n.text("Nueva maquina") : draft.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Guardar") { Task { await save() } }
                            .fontWeight(.semibold)
                    }
                }
            }
            .alert("Revisa el perfil", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("Entendido", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            guard let client = model.dncClient else {
                throw ZeuzAgentError.unreachable(
                    L10n.text("Conecta Zeuz Agent antes de modificar las máquinas.")
                )
            }
            let saved = try await machines.saveToZeuzDNC(draft, using: client)
            // Al dar de alta una maquina nueva, lo mas probable es que sea la
            // que se va a usar: la dejamos seleccionada.
            if isNew { machines.select(saved) }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete() async {
        guard let machine else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            guard let client = model.dncClient else {
                throw ZeuzAgentError.unreachable(
                    L10n.text("Conecta Zeuz Agent antes de modificar las máquinas.")
                )
            }
            try await machines.deleteFromZeuzDNC(machine, using: client)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
