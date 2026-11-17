import SwiftUI

struct PanelPalette {
    let dark: Bool

    var background: Color { color(0xF7F8FA, 0x171922) }
    var surface: Color { color(0xFFFFFF, 0x20222C) }
    var sidebar: Color { color(0xF0F2F6, 0x1C1E28) }
    var text: Color { color(0x1B2430, 0xF3F5F8) }
    var muted: Color { color(0x626D7C, 0xA4AEBD) }
    var border: Color { color(0xDCE0E8, 0x3B424F) }
    var accent: Color { color(0x465AC4, 0xBD9CF9) }
    var selected: Color { color(0xE8EBFC, 0x4E3E77) }
    var recordingSurface: Color { color(0xFCEFEE, 0x412830) }
    var recordingInk: Color { color(0xA52C38, 0xFFB1B5) }
    var selectedInk: Color { dark ? .white : accent }

    private func color(_ light: UInt32, _ darkValue: UInt32) -> Color {
        let rgb = dark ? darkValue : light
        return Color(red: Double(rgb >> 16) / 255, green: Double(rgb >> 8 & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}

private struct PanelCard: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let inset: CGFloat

    func body(content: Content) -> some View {
        let palette = PanelPalette(dark: scheme == .dark)
        content
            .padding(inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.border).allowsHitTesting(false))
    }
}

extension View {
    func panelCard(inset: CGFloat = 16) -> some View { modifier(PanelCard(inset: inset)) }
}

struct PanelSearchField: View {
    let placeholder: String
    @Binding var query: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .frame(minWidth: 120)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Очистить поиск")
            }
        }
        .padding(7)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
    }
}
