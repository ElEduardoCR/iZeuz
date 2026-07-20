import SwiftUI

// MARK: - Paleta

/// Colores de estado pensados para un taller: se leen de un vistazo desde
/// lejos y con la pantalla sucia o a contraluz.
enum ZeuzPalette {
    static let ready = Color.green
    static let warning = Color.orange
    static let danger = Color.red
    static let active = Color.blue
    static let accent = Color(red: 0.35, green: 0.62, blue: 1.0)
}

// MARK: - Semaforo de estado

/// Pastilla de estado con punto de color. Es el equivalente de la "alarma"
/// roja/verde del cable RS232 en la version de la Raspberry Pi.
struct StatusPill: View {
    enum Level {
        case ready, warning, danger, neutral

        var color: Color {
            switch self {
            case .ready: ZeuzPalette.ready
            case .warning: ZeuzPalette.warning
            case .danger: ZeuzPalette.danger
            case .neutral: .secondary
            }
        }
    }

    let level: Level
    let text: String
    var icon: String?

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
            } else {
                Circle()
                    .fill(level.color)
                    .frame(width: 9, height: 9)
            }
            Text(text)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(level == .neutral ? Color.secondary : level.color)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(.regular.tint(level.color.opacity(0.16)), in: .capsule)
    }
}

// MARK: - Tarjeta

/// Contenedor de vidrio para agrupar controles relacionados.
struct GlassCard<Content: View>: View {
    var tint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(
                tint.map { .regular.tint($0.opacity(0.18)) } ?? .regular,
                in: .rect(cornerRadius: 22)
            )
    }
}

// MARK: - Fila seleccionable

/// Fila grande con icono, titulo y subtitulo. Los objetivos tactiles son
/// amplios a proposito: se usa con guantes.
struct SelectableRow: View {
    let icon: String
    let title: String
    let subtitle: String
    var isSelected: Bool = false
    var tint: Color = ZeuzPalette.accent
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 32)
                    .foregroundStyle(isSelected ? tint : .secondary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(tint)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(
            isSelected ? .regular.tint(tint.opacity(0.2)) : .regular,
            in: .rect(cornerRadius: 18)
        )
    }
}

// MARK: - Estado vacio

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 46))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Progreso de transferencia

struct TransferProgressView: View {
    let state: TransferState

    private var level: StatusPill.Level {
        switch state.status {
        case .success: .ready
        case .error: .danger
        case .cancelled: .warning
        default: .neutral
        }
    }

    private var barColor: Color {
        switch state.status {
        case .success: ZeuzPalette.ready
        case .error: ZeuzPalette.danger
        case .cancelled: ZeuzPalette.warning
        default: ZeuzPalette.active
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if state.status.isActive {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(state.status.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(level == .neutral ? .primary : level.color)
                Spacer()
                if state.totalBytes > 0 {
                    Text("\(state.percent)%")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(barColor)
                }
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(barColor.gradient)
                        .frame(width: max(0, geometry.size.width * state.fraction))
                }
            }
            .frame(height: 10)
            .animation(.easeOut(duration: 0.25), value: state.fraction)

            HStack {
                if let fileName = state.fileName {
                    Text(fileName)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(state.progressLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if !state.message.isEmpty {
                Text(state.message)
                    .font(.caption)
                    .foregroundStyle(state.status == .error ? ZeuzPalette.danger : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Etiqueta de campo

struct FieldLabel: View {
    let text: String
    var help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(.subheadline.weight(.medium))
            if let help {
                Text(help)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
