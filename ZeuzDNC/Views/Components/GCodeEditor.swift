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
    @Binding var scrollProgress: Double
    @Binding var visibleFraction: Double
    var scrollRequest: GCodeScrollRequest?

    /// Cuerpo del editor. Monoespaciada obligatoria: en G-code las columnas
    /// alineadas son la mitad de la legibilidad.
    private var font: UIFont { .monospacedSystemFont(ofSize: 15, weight: .regular) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.showsVerticalScrollIndicator = false
        // El margen derecho evita que el codigo quede debajo del navegador.
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 24, right: 42)

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
        DispatchQueue.main.async {
            context.coordinator.publishScrollMetrics(from: view)
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        view.isEditable = isEditable

        // Solo se repinta entero cuando el cambio viene de fuera (abrir otro
        // programa, reemplazar todo). Si viniera de la propia escritura, aqui
        // se reemplazaria el texto y el cursor saltaria al inicio.
        if view.text != text {
            let selection = view.selectedRange
            let contentOffset = view.contentOffset
            context.coordinator.isApplyingExternalChange = true
            view.attributedText = GCodeHighlighter.attributedString(text, font: font)
            let length = (view.text as NSString).length
            view.selectedRange = NSRange(
                location: min(selection.location, length),
                length: min(selection.length, max(0, length - min(selection.location, length)))
            )
            view.layoutIfNeeded()
            context.coordinator.restore(contentOffset: contentOffset, in: view)
            context.coordinator.isApplyingExternalChange = false
            context.coordinator.publishScrollMetrics(from: view)
        }

        if let scrollRequest {
            context.coordinator.apply(scrollRequest: scrollRequest, to: view)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            scrollProgress: $scrollProgress,
            visibleFraction: $visibleFraction,
            font: font
        )
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var text: String
        @Binding private var scrollProgress: Double
        @Binding private var visibleFraction: Double
        private let font: UIFont
        var isApplyingExternalChange = false
        private var lastScrollRequestID: UUID?
        private var metricsUpdateScheduled = false

        init(
            text: Binding<String>,
            scrollProgress: Binding<Double>,
            visibleFraction: Binding<Double>,
            font: UIFont
        ) {
            _text = text
            _scrollProgress = scrollProgress
            _visibleFraction = visibleFraction
            self.font = font
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingExternalChange else { return }

            // Pintar atributos puede invalidar el layout del UITextView. Se
            // conserva el offset ya ajustado por iOS para que el cursor no de
            // un salto brusco en archivos largos.
            let contentOffset = textView.contentOffset
            let selection = textView.selectedRange
            repaintEditedParagraph(in: textView)
            textView.selectedRange = selection
            textView.layoutIfNeeded()
            restore(contentOffset: contentOffset, in: textView)

            // Se publica despues de pintar: al llegar a `updateUIView` el texto
            // ya coincide y no se dispara el repintado completo.
            text = textView.text
            publishScrollMetrics(from: textView)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let textView = scrollView as? UITextView else { return }
            publishScrollMetrics(from: textView)
        }

        func apply(scrollRequest: GCodeScrollRequest, to textView: UITextView) {
            guard lastScrollRequestID != scrollRequest.id else { return }
            lastScrollRequestID = scrollRequest.id

            textView.layoutIfNeeded()
            let limits = verticalLimits(of: textView)
            let progress = min(1, max(0, scrollRequest.progress))
            let y = limits.minimum + (limits.maximum - limits.minimum) * progress
            textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: y), animated: false)
            publishScrollMetrics(from: textView)
        }

        func restore(contentOffset: CGPoint, in textView: UITextView) {
            let limits = verticalLimits(of: textView)
            let y = min(limits.maximum, max(limits.minimum, contentOffset.y))
            textView.setContentOffset(CGPoint(x: contentOffset.x, y: y), animated: false)
        }

        func publishScrollMetrics(from textView: UITextView) {
            // Puede llamarse desde `updateUIView`; publicar el Binding en el
            // siguiente ciclo evita modificar estado durante una actualizacion
            // de SwiftUI y agrupa los muchos eventos que produce un arrastre.
            guard !metricsUpdateScheduled else { return }
            metricsUpdateScheduled = true
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self else { return }
                self.metricsUpdateScheduled = false
                guard let textView else { return }
                self.updateScrollMetrics(from: textView)
            }
        }

        private func updateScrollMetrics(from textView: UITextView) {
            textView.layoutIfNeeded()
            let limits = verticalLimits(of: textView)
            let distance = limits.maximum - limits.minimum
            let nextProgress = distance > 0
                ? min(1, max(0, (textView.contentOffset.y - limits.minimum) / distance))
                : 0
            let nextVisibleFraction = textView.contentSize.height > 0
                ? min(1, max(0.04, textView.bounds.height / textView.contentSize.height))
                : 1

            if abs(scrollProgress - nextProgress) > 0.001 {
                scrollProgress = nextProgress
            }
            if abs(visibleFraction - nextVisibleFraction) > 0.001 {
                visibleFraction = nextVisibleFraction
            }
        }

        private func verticalLimits(of scrollView: UIScrollView) -> (minimum: CGFloat, maximum: CGFloat) {
            let minimum = -scrollView.adjustedContentInset.top
            let maximum = max(
                minimum,
                scrollView.contentSize.height - scrollView.bounds.height
                    + scrollView.adjustedContentInset.bottom
            )
            return (minimum, maximum)
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

// MARK: - Navegacion rapida

/// Una orden explicita de desplazamiento. El identificador evita que cambios
/// de layout (por ejemplo, mostrar el teclado) vuelvan a aplicar una posicion
/// antigua y provoquen un salto inesperado.
struct GCodeScrollRequest: Equatable {
    let id = UUID()
    let progress: Double
}

/// Barra vertical siempre visible para recorrer un programa largo sin tener
/// que hacer muchos gestos. Incluye accesos directos al inicio y al final.
struct GCodeScrollNavigator: View {
    @Binding var progress: Double
    let visibleFraction: Double
    let lineCount: Int
    let onScrollRequest: (Double) -> Void

    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 4) {
            jumpButton(icon: "arrow.up.to.line", label: "Ir al inicio", progress: 0)

            GeometryReader { geometry in
                let height = geometry.size.height
                let thumbHeight = min(height, max(48, height * visibleFraction))
                let travel = max(0, height - thumbHeight)

                ZStack(alignment: .top) {
                    Capsule()
                        .fill(.secondary.opacity(0.18))
                        .frame(width: 5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Capsule()
                        .fill(isDragging ? ZeuzPalette.accent : Color.secondary.opacity(0.65))
                        .frame(width: isDragging ? 12 : 8, height: thumbHeight)
                        .offset(y: travel * min(1, max(0, progress)))
                        .shadow(color: .black.opacity(isDragging ? 0.18 : 0), radius: 3)
                }
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            let next = travel > 0
                                ? (value.location.y - thumbHeight / 2) / travel
                                : 0
                            requestScroll(to: next)
                        }
                        .onEnded { _ in isDragging = false }
                )
                .overlay(alignment: .leading) {
                    if isDragging, lineCount > 0 {
                        Text("L\(currentLine)")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(.regularMaterial, in: .capsule)
                            .offset(x: -52)
                            .allowsHitTesting(false)
                    }
                }
            }

            jumpButton(icon: "arrow.down.to.line", label: "Ir al final", progress: 1)
        }
        .frame(width: 34)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: .capsule)
        .accessibilityElement(children: .contain)
    }

    private var currentLine: Int {
        min(lineCount, max(1, Int((Double(max(1, lineCount)) - 1) * progress) + 1))
    }

    private func jumpButton(icon: String, label: String, progress: Double) -> some View {
        Button {
            requestScroll(to: progress)
        } label: {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func requestScroll(to value: Double) {
        let clamped = min(1, max(0, value))
        progress = clamped
        onScrollRequest(clamped)
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
