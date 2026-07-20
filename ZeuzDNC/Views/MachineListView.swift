import SwiftUI

/// Lista de maquinas: seleccionar, editar, eliminar y dar de alta nuevas.
/// Todo desde la app, sin tocar archivos de configuracion.
struct MachineListView: View {
    @Environment(MachineStore.self) private var machines
    @Environment(\.dismiss) private var dismiss

    @State private var editing: Machine?
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(machines.machines) { machine in
                        row(machine)
                    }
                    .onDelete { machines.delete(at: $0) }
                } header: {
                    Text("Maquinas dadas de alta")
                } footer: {
                    Text(
                        "Los perfiles de Fanuc y Fadal son valores tipicos de referencia. "
                            + "Confirmalos contra el manual de cada control antes de usarlos en produccion."
                    )
                }
            }
            .navigationTitle("Maquinas")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if machines.machines.isEmpty {
                    EmptyStateView(
                        icon: "gearshape.2",
                        title: "Sin maquinas",
                        message: "Da de alta la primera maquina con su configuracion serial.",
                        actionTitle: "Agregar maquina",
                        action: { isCreating = true }
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Listo") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isCreating = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $editing) { machine in
                MachineEditorView(machine: machine)
            }
            .sheet(isPresented: $isCreating) {
                MachineEditorView(machine: nil)
            }
        }
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

            Button {
                editing = machine
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(ZeuzPalette.accent)
            }
            .buttonStyle(.plain)
        }
    }
}

/// Alta y edicion de un perfil de maquina.
struct MachineEditorView: View {
    @Environment(MachineStore.self) private var machines
    @Environment(\.dismiss) private var dismiss

    /// nil = alta nueva.
    let machine: Machine?

    @State private var draft: Machine
    @State private var errorMessage: String?

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
                    Text("Se aplica al enviar. El archivo en la carpeta compartida no se modifica.")
                }

                Section {
                    Toggle("DTR encendido", isOn: $draft.dtr)
                    Toggle("RTS encendido", isOn: $draft.rts)
                        .disabled(draft.flowControl == .rtsCts)
                } header: {
                    Text("Lineas de control")
                } footer: {
                    Text(
                        draft.flowControl == .rtsCts
                            ? "Con RTS/CTS la linea RTS la maneja el control de flujo."
                            : "Muchas configuraciones de PC que funcionan tienen DTR y RTS apagados. "
                                + "Si la maquina no acepta datos, prueba a cambiarlos."
                    )
                }

                Section {
                    Toggle("Modo goteo (drip-feed)", isOn: $draft.dripFeed)
                } footer: {
                    Text(
                        "La maquina ejecuta mientras recibe y frena el envio con el control de flujo. "
                            + "Sin limite de tiempo: solo se detiene con CANCELAR."
                    )
                }

                if !isNew {
                    Section {
                        Button("Eliminar maquina", role: .destructive) {
                            if let machine { machines.delete(machine) }
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Nueva maquina" : draft.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") { save() }
                        .fontWeight(.semibold)
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

    private func save() {
        do {
            let saved = try machines.save(draft)
            // Al dar de alta una maquina nueva, lo mas probable es que sea la
            // que se va a usar: la dejamos seleccionada.
            if isNew { machines.select(saved) }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
