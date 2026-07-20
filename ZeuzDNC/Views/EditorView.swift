import SwiftUI

/// Columna central: editor del programa con buscar/reemplazar, y abajo la
/// barra de envio (maquina + puerto + ENVIAR).
struct EditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(ProgramStore.self) private var programs

    @State private var showsFindBar = false
    @State private var findText = ""
    @State private var replaceText = ""
    @State private var showsLegend = false

    var body: some View {
        @Bindable var programs = programs

        Group {
            if programs.document == nil {
                EmptyStateView(
                    icon: "doc.text.magnifyingglass",
                    title: "Ningun programa abierto",
                    message: "Elige un programa de la lista para verlo y editarlo aqui."
                )
            } else {
                editor
            }
        }
        .navigationTitle(programs.document?.name ?? "Editor")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showsLegend) { GCodeLegendView() }
    }

    // MARK: - Editor

    private var editor: some View {
        @Bindable var programs = programs

        return VStack(spacing: 0) {
            if let document = programs.document, document.truncated {
                readOnlyBanner
            }

            if showsFindBar {
                findAndReplaceBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            GCodeEditor(text: $programs.draft, isEditable: programs.canEdit)

            statusStrip
        }
        .animation(.smooth(duration: 0.25), value: showsFindBar)
    }

    private var readOnlyBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
            Text("Archivo muy grande: abierto en solo lectura")
                .font(.footnote.weight(.medium))
            Spacer()
        }
        .foregroundStyle(ZeuzPalette.warning)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(ZeuzPalette.warning.opacity(0.12))
    }

    /// Pie con el conteo de lineas y el aviso de cambios sin guardar.
    private var statusStrip: some View {
        HStack(spacing: 14) {
            Label("\(lineCount) lineas", systemImage: "number")
                .font(.caption)
                .foregroundStyle(.secondary)

            if programs.hasUnsavedChanges {
                Label("Sin guardar", systemImage: "circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ZeuzPalette.warning)
            }

            Spacer()

            if programs.isSaving {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var lineCount: Int {
        programs.draft.isEmpty ? 0 : programs.draft.components(separatedBy: .newlines).count
    }

    // MARK: - Buscar y reemplazar

    private var matchCount: Int {
        guard !findText.isEmpty else { return 0 }
        return programs.draft.components(separatedBy: findText).count - 1
    }

    /// Lineas donde aparece el texto buscado, con su numero. En un G-code
    /// largo es mas util que un "siguiente/anterior" a ciegas en el telefono.
    private var matchingLines: [(number: Int, text: String)] {
        guard !findText.isEmpty else { return [] }
        return programs.draft
            .components(separatedBy: .newlines)
            .enumerated()
            .filter { $0.element.localizedCaseInsensitiveContains(findText) }
            .prefix(50)
            .map { ($0.offset + 1, $0.element.trimmingCharacters(in: .whitespaces)) }
    }

    private var findAndReplaceBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Buscar", text: $findText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)

                if !findText.isEmpty {
                    Text("\(matchCount)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(matchCount > 0 ? ZeuzPalette.accent : .secondary)
                }

                Button {
                    withAnimation { showsFindBar = false }
                    findText = ""
                    replaceText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "arrow.2.squarepath")
                    .foregroundStyle(.secondary)
                TextField("Reemplazar por", text: $replaceText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)

                Button("Uno") { replaceFirst() }
                    .buttonStyle(.glass)
                    .disabled(matchCount == 0 || !programs.canEdit)

                Button("Todos") { replaceAll() }
                    .buttonStyle(.glassProminent)
                    .disabled(matchCount == 0 || !programs.canEdit)
            }

            if !matchingLines.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(matchingLines, id: \.number) { match in
                            Text("L\(match.number)  \(match.text)")
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .glassEffect(.regular, in: .capsule)
                        }
                    }
                }
                .frame(height: 34)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func replaceFirst() {
        guard let range = programs.draft.range(of: findText) else { return }
        programs.draft.replaceSubrange(range, with: replaceText)
    }

    private func replaceAll() {
        programs.draft = programs.draft.replacingOccurrences(of: findText, with: replaceText)
    }

    // MARK: - Barra de herramientas

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                withAnimation { showsFindBar.toggle() }
            } label: {
                Image(systemName: "text.magnifyingglass")
            }
            .disabled(programs.document == nil)

            Button {
                Task { await programs.save() }
            } label: {
                if programs.isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "square.and.arrow.down")
                }
            }
            .disabled(!programs.hasUnsavedChanges || programs.isSaving)

            Menu {
                Button {
                    showsLegend = true
                } label: {
                    Label("Que significa cada color", systemImage: "paintpalette")
                }
                Divider()
                Button {
                    // Cierra el programa del todo: volver atras con el gesto
                    // lo deja abierto a proposito, para poder enviarlo desde
                    // la lista sin tener que reabrirlo.
                    programs.closeDocument()
                    model.showsEditor = false
                } label: {
                    Label("Cerrar programa", systemImage: "xmark")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .disabled(programs.document == nil)
        }
    }
}
