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
    var projectAccent: Color { color(0x6842D8, 0xC5A8FF) }

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

struct ProjectDateField: View {
    let title: String
    @Binding var value: String
    @State private var showingCalendar = false
    @State private var selectedDay = Date()

    private static let utc = TimeZone(secondsFromGMT: 0)!
    private static let storage = Date.ISO8601FormatStyle(timeZone: utc)
        .year().month().day().dateSeparator(.dash)

    static func display(_ value: String) -> String {
        guard let day = try? storage.parse(value) else { return value }
        var format = Date.FormatStyle(date: .numeric, time: .omitted)
        format.locale = .autoupdatingCurrent
        format.calendar = .autoupdatingCurrent
        format.timeZone = utc
        return format.format(day)
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Button {
                    let localFormat = Date.ISO8601FormatStyle(timeZone: .autoupdatingCurrent)
                        .year().month().day().dateSeparator(.dash)
                    selectedDay = (try? Self.storage.parse(value))
                        ?? (try? Self.storage.parse(localFormat.format(.now))) ?? .now
                    showingCalendar = true
                } label: {
                    Label(value.isEmpty ? "Выбрать дату" : Self.display(value), systemImage: "calendar")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(title + ", " + (value.isEmpty ? "выбрать дату" : Self.display(value)))
                .popover(isPresented: $showingCalendar) {
                    VStack(alignment: .trailing, spacing: 12) {
                        DatePicker(title, selection: $selectedDay, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                            .environment(\.timeZone, Self.utc)
                            .environment(\.locale, .autoupdatingCurrent)
                            .frame(minWidth: 260)
                        Button("Выбрать") {
                            value = Self.storage.format(selectedDay)
                            showingCalendar = false
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    }
                    .padding(12)
                }
                if !value.isEmpty {
                    Button { value = "" } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Очистить дату")
                    .accessibilityLabel("Очистить дату: " + title)
                }
            }
        }
    }
}

struct PanelSearchField: View {
    let placeholder: String
    @Binding var query: String
    var focus: FocusState<Bool>.Binding? = nil

    private var field: some View {
        TextField(placeholder, text: $query)
            .textFieldStyle(.plain)
            .frame(minWidth: 120)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if let focus { field.focused(focus) }
            else { field }
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
