import SwiftUI

struct PersonDirectory: View {
    struct Filters {
        var query = ""
        var department = ""
        var organization = ""
        var projectID: Int?

        var isActive: Bool { !department.isEmpty || !organization.isEmpty || projectID != nil }
    }

    @ObservedObject var model: WorkspaceModel
    @Binding var selection: Int?
    @Binding var filters: Filters

    var body: some View {
        let people = model.workspace?.people ?? []
        let projects = model.workspace?.projects ?? []
        let project = projects.first { $0.id == filters.projectID }
        let needle = filters.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let results = people.filter { person in
            (filters.department.isEmpty || person.department == filters.department) &&
            (filters.organization.isEmpty || person.organization == filters.organization) &&
            (project == nil || project?.ownerId == person.id || project?.members?.contains(person.id) == true) &&
            (needle.isEmpty || [person.speakerPickerName, person.nickname, person.role, person.department,
                                person.organization, person.email, person.phone]
                .compactMap { $0 }.joined(separator: " ").localizedStandardContains(needle))
        }

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                PanelSearchField(placeholder: "Поиск участников", query: $filters.query)
                    .help("Поиск по ФИО, псевдониму, должности и контактам")
                filterMenu(people, projects: projects)
            }
            .panelCard()
            Text(results.count == people.count ? "Участников: \(results.count)" : "Участников: \(results.count) из \(people.count)")
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
            if results.isEmpty {
                Label(people.isEmpty ? "Участников пока нет" : "Участники не найдены",
                      systemImage: people.isEmpty ? "person.2" : "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .panelCard()
            } else {
                table(results)
                    .panelCard(inset: 1)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private func table(_ results: [Person]) -> some View {
        Table(results, selection: $selection) {
            TableColumn("Участник") { person in
                HStack(spacing: 8) {
                    PersonAvatar(person: person, url: model.personPhotoURL(person), size: 24)
                    Text(person.speakerPickerName).font(.callout.weight(.semibold))
                }
            }
            .width(min: 130, ideal: 185)
            TableColumn("Псевдоним") { person in cell(person.nickname) }
                .width(min: 70, ideal: 95)
            TableColumn("Должность") { person in cell(person.role) }
                .width(min: 76, ideal: 105)
            TableColumn("Подразделение") { person in cell(person.department) }
                .width(min: 94, ideal: 115)
            TableColumn("Организация") { person in cell(person.organization) }
                .width(min: 86, ideal: 110)
            TableColumn("Контакты") { person in
                cell([person.email, person.phone].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
            }
            .width(min: 90, ideal: 150)
        }
        .scrollContentBackground(.hidden)
    }

    private func filterMenu(_ people: [Person], projects: [Project]) -> some View {
        Menu {
            Menu("Подразделение") {
                Picker("Подразделение", selection: $filters.department) {
                    Text("Все подразделения").tag("")
                    ForEach(Set(people.compactMap(\.department).filter { !$0.isEmpty }).sorted(), id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .pickerStyle(.inline)
            }
            Menu("Организация") {
                Picker("Организация", selection: $filters.organization) {
                    Text("Все организации").tag("")
                    ForEach(Set(people.compactMap(\.organization).filter { !$0.isEmpty }).sorted(), id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .pickerStyle(.inline)
            }
            Menu("Проект") {
                Picker("Проект", selection: $filters.projectID) {
                    Text("Все проекты").tag(nil as Int?)
                    ForEach(projects) { Text($0.title).tag(Optional($0.id)) }
                }
                .pickerStyle(.inline)
            }
            if filters.isActive {
                Divider()
                Button("Сбросить фильтры") { filters = Filters(query: filters.query) }
            }
        } label: {
            Label("Фильтры", systemImage: filters.isActive
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityValue(filters.isActive ? "Фильтры включены" : "Все участники")
    }

    private func cell(_ value: String?) -> some View {
        let text = value ?? ""
        return Text(text.isEmpty ? "—" : text)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(text)
    }
}
