import SwiftUI

struct WindowCloseButton: View {
    var label = "Закрыть окно"
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(enabled ? Color(red: 1, green: 0.37, blue: 0.34) : Color.secondary.opacity(0.25))
                .overlay {
                    if hovering && enabled {
                        Image(systemName: "xmark")
                            .font(.system(size: 6, weight: .heavy))
                            .foregroundStyle(.black.opacity(0.7))
                    }
                }
                .frame(width: 12, height: 12)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

struct NavigationBackButton: View {
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        let palette = PanelPalette(dark: scheme == .dark)
        Button(action: action) {
            DrawnBackArrow()
                .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                .frame(width: 18, height: 15)
                .foregroundStyle(enabled ? (hovering ? palette.selectedInk : palette.accent) : palette.muted.opacity(0.65))
                .frame(width: 34, height: 28)
                .background(enabled && hovering ? palette.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Назад")
        .accessibilityLabel("Назад")
    }
}

private struct DrawnBackArrow: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }

        return Path { path in
            path.move(to: point(0.91, 0.76))
            path.addQuadCurve(to: point(0.12, 0.52), control: point(0.63, 0.35))
            path.move(to: point(0.42, 0.19))
            path.addQuadCurve(to: point(0.12, 0.52), control: point(0.27, 0.31))
            path.addQuadCurve(to: point(0.46, 0.84), control: point(0.26, 0.69))
        }
    }
}

private struct SheetCloseBar: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    let disabled: Bool

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            HStack {
                WindowCloseButton { dismiss() }
                    .disabled(disabled)
                NavigationBackButton { dismiss() }
                    .disabled(disabled)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            Divider()
            content
        }
    }
}

extension View {
    func sheetCloseButton(disabled: Bool = false) -> some View {
        modifier(SheetCloseBar(disabled: disabled))
    }
}
