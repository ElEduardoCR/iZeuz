import SwiftUI
import UIKit

/// Editor de G-code con coloreado en vivo.
///
/// Va sobre `UITextView` y no sobre `TextEditor` por dos razones concretas:
/// hace falta pintar el texto mientras se escribe sin que el cursor salte, y
/// hay que apagar la correccion "inteligente" de iOS — el guion tipografico
/// que pone en lugar de `-` corrompe el programa y la maquina lo rechaza.
struct GCodeEditor: UIViewRepresentable {
    @Binding var text: String
    var isEditable: Bool

    /// Cuerpo del editor. Monoespaciada obligatoria: en G-code las columnas
    /// alineadas son la mitad de la legibilidad.
    private var font: UIFont { .monospacedSystemFont(ofSize: 15, weight: .regular) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 24, right: 8)

        // Nada de ayudas de escritura: aqui todo caracter es significativo.
        view.autocorrectionType = .no
        view.autocapitalizationType = .allCharacters
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.keyboardType = .asciiCapable

        view.attributedText = GCodeHighlighter.attributedString(text, font: font)
        view.isEditable = isEditable
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        view.isEditable = isEditable

        // Solo se repinta entero cuando el cambio viene de fuera (abrir otro
        // programa, reemplazar todo). Si viniera de la propia escritura, aqui
        // se reemplazaria el texto y el cursor saltaria al inicio.
        guard view.text != text else { return }

        let selection = view.selectedRange
        context.coordinator.isApplyingExternalChange = true
        view.attributedText = GCodeHighlighter.attributedString(text, font: font)
        let length = (view.text as NSString).length
        view.selectedRange = NSRange(
            location: min(selection.location, length),
            length: min(selection.length, max(0, length - min(selection.location, length)))
        )
        context.coordinator.isApplyingExternalChange = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, font: font)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var text: String
        private let font: UIFont
        var isApplyingExternalChange = false

        init(text: Binding<String>, font: UIFont) {
            _text = text
            self.font = font
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingExternalChange else { return }

            repaintEditedParagraph(in: textView)

            // Se publica despues de pintar: al llegar a `updateUIView` el texto
            // ya coincide y no se dispara el repintado completo.
            text = textView.text
        }

        /// Repinta solo la linea que se esta tocando. Es lo que mantiene el
        /// editor fluido en programas de miles de lineas.
        private func repaintEditedParagraph(in textView: UITextView) {
            let ns = textView.text as NSString
            guard ns.length > 0 else { return }

            let cursor = NSRange(
                location: min(textView.selectedRange.location, ns.length),
                length: 0
            )
            let paragraph = ns.paragraphRange(for: cursor)

            let storage = textView.textStorage
            storage.beginEditing()
            GCodeHighlighter.apply(to: storage, range: paragraph, font: font)
            storage.endEditing()

            // Sin esto lo siguiente que se escriba hereda el color del ultimo
            // token pintado (escribir despues de un comentario saldria gris).
            textView.typingAttributes = [
                .font: font,
                .foregroundColor: GCodeHighlighter.plain
            ]
        }
    }
}

// MARK: - Leyenda

/// Referencia rapida de que significa cada color. En el taller se consulta una
/// vez y no se vuelve a abrir, por eso va plegada en el menu del editor.
struct GCodeLegendView: View {
    private let entries: [(String, Color, String)] = [
        ("G", Color(uiColor: GCodeHighlighter.gCode), "Movimiento y ciclos"),
        ("M", Color(uiColor: GCodeHighlighter.mCode), "Funciones de maquina"),
        ("X Y Z", Color(uiColor: GCodeHighlighter.axis), "Ejes"),
        ("I J K R", Color(uiColor: GCodeHighlighter.arc), "Arcos y radios"),
        ("F", Color(uiColor: GCodeHighlighter.feed), "Avance"),
        ("S", Color(uiColor: GCodeHighlighter.spindle), "Husillo"),
        ("T D H", Color(uiColor: GCodeHighlighter.tool), "Herramienta y correctores"),
        ("N", Color(uiColor: GCodeHighlighter.lineNo), "Numero de linea"),
        ("O", Color(uiColor: GCodeHighlighter.progNo), "Numero de programa"),
        ("( ) ;", Color(uiColor: GCodeHighlighter.comment), "Comentarios"),
        ("%", Color(uiColor: GCodeHighlighter.marker), "Inicio y fin de cinta")
    ]

    var body: some View {
        NavigationStack {
            List(entries, id: \.0) { code, color, meaning in
                HStack(spacing: 14) {
                    Text(code)
                        .font(.system(.body, design: .monospaced).weight(.bold))
                        .foregroundStyle(color)
                        .frame(width: 78, alignment: .leading)
                    Text(meaning)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Colores")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
