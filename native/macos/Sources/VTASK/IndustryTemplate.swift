import SwiftUI

enum IndustryTemplate: String, Decodable, CaseIterable, Identifiable {
    case universal, decor, it, construction

    var id: String { rawValue }

    var title: String {
        switch self {
        case .universal: return "Универсальный"
        case .decor: return "Декор"
        case .it: return "IT"
        case .construction: return "Строительство"
        }
    }
}

struct IndustryTemplateMenu: View {
    @ObservedObject var model: WorkspaceModel

    private var selected: IndustryTemplate {
        model.workspace?.settings.industryTemplate ?? .decor
    }

    var body: some View {
        Menu {
            ForEach(IndustryTemplate.allCases) { template in
                Button {
                    guard template != selected || model.workspace?.settings.industryTemplate == nil else { return }
                    Task { await model.setIndustryTemplate(template) }
                } label: {
                    if template == selected { Label(template.title, systemImage: "checkmark") }
                    else { Text(template.title) }
                }
            }
        } label: {
            Label(selected.title, systemImage: "square.3.layers.3d")
        }
        .accessibilityLabel("Отраслевой шаблон")
        .accessibilityValue(selected.title)
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
                ForEach(IndustryTemplate.allCases) { template in
                    Text(template.title).tag(template)
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
