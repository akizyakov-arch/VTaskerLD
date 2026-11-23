import SwiftUI

struct IndustryTemplate: Decodable, Hashable {
    let rawValue: String

    static let universal = Self(rawValue: "universal")
    static let events = Self(rawValue: "events")

    init(rawValue: String) {
        self.rawValue = rawValue == "decor" ? "events" : rawValue
    }

    var parent: Self {
        Self(rawValue: rawValue.split(separator: "/", maxSplits: 1).first.map(String.init) ?? rawValue)
    }

    var eventWorkPeriodListKey: String? {
        switch rawValue {
        case "events/decor", "events/floristry", "events/scenography": return "decor"
        case "events/production": return "organization"
        default: return nil
        }
    }

    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
}

struct IndustryOption: Decodable, Identifiable {
    let id: String
    let title: String

    var template: IndustryTemplate { IndustryTemplate(rawValue: id) }

    static let legacy: [Self] = [
        .init(id: "universal", title: "Универсальный"),
        .init(id: "events", title: "Мероприятия и декор"),
        .init(id: "it", title: "ИТ"),
        .init(id: "construction", title: "Строительство"),
    ]
}

struct SpecializationOption: Decodable, Identifiable {
    let id: String
    let industryId: String
    let title: String
}

struct IndustryTemplateMenu: View {
    @ObservedObject var model: WorkspaceModel

    private var selected: IndustryTemplate {
        model.workspace?.settings.industryTemplate ?? .events
    }

    var body: some View {
        let options = model.workspace?.industryOptions ?? IndustryOption.legacy
        Menu {
            ForEach(options) { option in
                let template = option.template
                Button {
                    guard template != selected || model.workspace?.settings.industryTemplate == nil else { return }
                    Task { await model.setIndustryTemplate(template) }
                } label: {
                    if template == selected { Label(option.title, systemImage: "checkmark") }
                    else { Text(option.title) }
                }
            }
        } label: {
            Label(model.workspace?.industryTitle ?? "Мероприятия и декор", systemImage: "square.3.layers.3d")
        }
        .accessibilityLabel("Отраслевой шаблон")
        .accessibilityValue(model.workspace?.industryTitle ?? "Мероприятия и декор")
        .help("Выбрать отраслевой шаблон")
        .disabled(model.saving || model.loading)
    }
}

struct IndustrySetupView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var selected = IndustryTemplate.universal
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Выберите отрасль", systemImage: "square.3.layers.3d")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Отрасль задаёт стартовые разделы и термины Валли. Поменять её можно в настройках.")
                .foregroundStyle(.secondary)
            Picker("Отраслевой шаблон", selection: $selected) {
                ForEach(model.workspace?.industryOptions ?? IndustryOption.legacy) { option in
                    Text(option.title).tag(option.template)
                }
            }
            let topics = MeetingTopics(industry: selected).sectionTitles
            Text(topics.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Продолжить") {
                    Task { if await model.setIndustryTemplate(selected) { dismiss() } }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460, alignment: .leading)
        .disabled(model.saving)
        .interactiveDismissDisabled(model.saving)
    }
}


struct IndustrySelectionField: View {
    let options: [IndustryOption]
    let specializations: [SpecializationOption]
    let inheritedTitle: String
    @Binding var selection: [String]

    private var displayTitle: String {
        if selection.isEmpty { return inheritedTitle }
        return selection.compactMap { id in
            options.first { $0.id == id }?.title ?? specializations.first { $0.id == id }?.title
        }.joined(separator: ", ")
    }

    private func toggle(_ id: String, in industry: String) {
        if selection.contains(id) {
            selection.removeAll { $0 == id }
        } else {
            if id == industry {
                selection.removeAll { $0.hasPrefix(industry + "/") }
            } else {
                selection.removeAll { $0 == industry }
            }
            selection.append(id)
        }
    }

    private func choice(_ title: String, id: String, industry: String) -> some View {
        Button {
            toggle(id, in: industry)
        } label: {
            if selection.contains(id) { Label(title, systemImage: "checkmark") }
            else { Text(title) }
        }
    }

    var body: some View {
        LabeledContent("Словари для Валли") {
            Menu {
                Button(inheritedTitle) { selection = [] }
                    .disabled(selection.isEmpty)
                Divider()
                ForEach(options) { option in
                    let children = specializations.filter { $0.industryId == option.id }
                    if children.isEmpty {
                        choice(option.title, id: option.id, industry: option.id)
                    } else {
                        Menu {
                            choice("Вся отрасль", id: option.id, industry: option.id)
                            Divider()
                            ForEach(children) { child in
                                choice(child.title, id: child.id, industry: option.id)
                            }
                        } label: {
                            if selection.contains(where: { $0 == option.id || $0.hasPrefix(option.id + "/") }) {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                }
            } label: {
                Text(displayTitle).lineLimit(1)
            }
            .accessibilityLabel("Словари для Валли")
            .accessibilityValue(displayTitle)
        }
    }
}
