import SwiftUI

private let projectStatusOptions: [(id: String, title: String)] = [
    ("planned", "Запланирован"), ("active", "В работе"), ("paused", "Приостановлен"),
    ("completed", "Завершён"), ("cancelled", "Отменён")
]

struct ProjectEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: WorkspaceModel
    let project: Project

    @State private var title: String
    @State private var description: String
    @State private var goal: String
    @State private var materials: String
    @State private var start: String
    @State private var end: String
    @State private var status: String
    @State private var ownerID: Int?
    @State private var members: Set<Int>
    @State private var milestone: String
    @State private var milestoneDate: String
    @State private var blocker: String
    @State private var stages: [EditableStage]
    @State private var migrations: [String: String] = [:]

    private struct EditableStage: Identifiable {
        var id: String
        var title: String
        let kind: String
    }

    init(model: WorkspaceModel, project: Project) {
        self.model = model
        self.project = project
        _title = State(initialValue: project.title)
        _description = State(initialValue: project.description ?? "")
        _goal = State(initialValue: project.goal ?? "")
        _materials = State(initialValue: project.materials ?? "")
        _start = State(initialValue: project.startDate ?? "")
        _end = State(initialValue: project.endDate ?? "")
        _status = State(initialValue: project.status)
        _ownerID = State(initialValue: project.ownerId)
        _members = State(initialValue: Set(project.members ?? []))
        _milestone = State(initialValue: project.nextMilestone ?? "")
        _milestoneDate = State(initialValue: project.nextMilestoneDate ?? "")
        _blocker = State(initialValue: project.blocker ?? "")
        _stages = State(initialValue: project.stages.map { EditableStage(id: $0.id, title: $0.title, kind: $0.kind) })
    }

    private var occupiedRemovedStages: [Stage] {
        let retained = Set(stages.map(\.id))
        let occupied = Set((model.workspace?.tasks ?? []).filter { $0.projectId == project.id }.map(\.stageId))
        return project.stages.filter { !retained.contains($0.id) && occupied.contains($0.id) }
    }

    private func moveStage(_ id: String, by offset: Int) {
        guard let index = stages.firstIndex(where: { $0.id == id }), stages.indices.contains(index + offset) else { return }
        stages.swapAt(index, index + offset)
    }

    var body: some View {
        let palette = PanelPalette(dark: scheme == .dark)
        VStack(alignment: .leading, spacing: 0) {
            Label(project.title, systemImage: "folder")
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            Divider()
            fields
            Divider()
            actions
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(palette.surface)
        }
        .background(palette.background)
        .frame(width: 560, height: 560)
        .disabled(model.saving || model.loading)
        .interactiveDismissDisabled(model.saving)
    }

    private var fields: some View {
        Form {
            Section("Основное") {
                TextField("Название", text: $title)
                TextField("Описание", text: $description, axis: .vertical)
                TextField("Цель", text: $goal, axis: .vertical)
                TextField("Материалы", text: $materials, axis: .vertical)
                Picker("Статус", selection: $status) {
                    ForEach(projectStatusOptions, id: \.id) { Text($0.title).tag($0.id) }
                }
            }
            Section("Сроки") {
                TextField("Начало (ГГГГ-ММ-ДД)", text: $start)
                TextField("Срок (ГГГГ-ММ-ДД)", text: $end)
            }
            teamFields
            Section("План и риски") {
                TextField("Ближайший этап", text: $milestone)
                TextField("Срок этапа (ГГГГ-ММ-ДД)", text: $milestoneDate)
                TextField("Что мешает работе", text: $blocker, axis: .vertical)
            }
            Section("Этапы проекта") {
                ForEach($stages) { $stage in
                    HStack {
                        TextField("Название этапа", text: $stage.title)
                        Button { moveStage(stage.id, by: -1) } label: { Image(systemName: "chevron.up") }
                            .accessibilityLabel("Поднять этап")
                            .disabled(stages.first?.id == stage.id)
                        Button { moveStage(stage.id, by: 1) } label: { Image(systemName: "chevron.down") }
                            .accessibilityLabel("Опустить этап")
                            .disabled(stages.last?.id == stage.id)
                        Button(role: .destructive) {
                            let id = stage.id
                            stages.removeAll { $0.id == id }
                            migrations = migrations.filter { $0.value != id }
                        } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Удалить этап")
                        .disabled(stages.filter { $0.kind == stage.kind }.count <= 1)
                    }
                    .buttonStyle(.borderless)
                }
                Button("Добавить рабочий этап") {
                    stages.append(EditableStage(id: UUID().uuidString, title: "", kind: "active"))
                }
                .disabled(stages.count >= 30)
            }
            if !occupiedRemovedStages.isEmpty {
                Section("Перенос задач") {
                    ForEach(occupiedRemovedStages) { stage in
                        Picker("Из этапа «" + stage.title + "»", selection: Binding(
                            get: { migrations[stage.id] ?? "" },
                            set: { migrations[stage.id] = $0 }
                        )) {
                            Text("Выберите этап").tag("")
                            ForEach(stages) { destination in
                                Text(destination.title.isEmpty ? "Новый этап" : destination.title).tag(destination.id)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(maxHeight: .infinity)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
            }
            HStack {
                Button {
                    Task {
                        if await model.command(["op": "archive_project", "id": project.id,
                                                "revision": project.revision, "archived": project.archived != true]) {
                            dismiss()
                        }
                    }
                } label: {
                    Label(project.archived == true ? "Восстановить" : "В архив",
                          systemImage: project.archived == true ? "arrow.uturn.backward" : "archivebox")
                }
                Spacer()
                Button("Закрыть") { dismiss() }
                Button("Сохранить") {
                    Task {
                        if await model.updateProject(project, changes: [
                            "title": title, "description": description, "goal": goal, "materials": materials,
                            "status": status, "start_date": start.isEmpty ? NSNull() as Any : start,
                            "end_date": end.isEmpty ? NSNull() as Any : end,
                            "owner_id": ownerID.map { $0 as Any } ?? NSNull(),
                            "members": members.sorted(),
                            "next_milestone": milestone, "next_milestone_date": milestoneDate,
                            "blocker": blocker,
                            "stages": stages.map { ["id": $0.id, "title": $0.title.trimmingCharacters(in: .whitespacesAndNewlines), "kind": $0.kind] }
                        ], migrations: migrations) {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          stages.contains { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ||
                          occupiedRemovedStages.contains { (migrations[$0.id] ?? "").isEmpty })
            }
            .buttonStyle(.bordered)
        }
    }

    private var teamFields: some View {
        Section("Команда") {
            let people = model.workspace?.people ?? []
            Picker("Владелец проекта", selection: $ownerID) {
                Text("Не назначен").tag(nil as Int?)
                ForEach(people) { person in Text(person.name).tag(Optional(person.id)) }
            }
            ForEach(people) { person in
                Toggle(person.name, isOn: Binding(
                    get: { members.contains(person.id) },
                    set: { selected in
                        if selected { members.insert(person.id) }
                        else { members.remove(person.id) }
                    }
                ))
            }
        }
    }
}

struct MeetingNotes: Decodable {
    let revision: Int
    let summary: String
    let openQuestions: String
}

struct MeetingNotesEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: WorkspaceModel
    let meetingID: Int
    let notes: MeetingNotes
    @State private var summary: String
    @State private var questions: String

    init(model: WorkspaceModel, meetingID: Int, notes: MeetingNotes) {
        self.model = model
        self.meetingID = meetingID
        self.notes = notes
        _summary = State(initialValue: notes.summary)
        _questions = State(initialValue: notes.openQuestions)
    }

    var body: some View {
        Form {
            Section("Ручные итоги встречи") {
                TextField("Резюме", text: $summary, axis: .vertical).lineLimit(2...8)
                TextField("Открытые вопросы", text: $questions,
                          prompt: Text("Что осталось уточнить или обсудить"), axis: .vertical)
                    .lineLimit(2...8)
            }
            if let error = model.error {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Button("Отмена", role: .cancel) { dismiss() }.buttonStyle(.bordered)
                Spacer()
                Button("Сохранить") {
                    Task {
                        if await model.command(["op": "save_meeting_notes", "meeting_id": meetingID,
                                                "revision": notes.revision, "summary": summary, "open_questions": questions]) {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(summary == notes.summary && questions == notes.openQuestions)
            }
            .disabled(model.saving || model.loading)
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 290)
        .interactiveDismissDisabled(model.saving)
    }
}

struct ProjectOverview: View {
    let project: Project
    let workspace: Workspace
    let openMeeting: (Int) -> Void

    var body: some View {
        MeetingDisclosure(title: "Обзор проекта", icon: "folder", count: nil) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    let owner = workspace.people.first { $0.id == project.ownerId }
                    LabeledContent("Владелец", value: owner?.name ?? "Не назначен")
                    let team = workspace.people.filter { (project.members ?? []).contains($0.id) }
                    LabeledContent("Команда", value: team.isEmpty ? "Без участников" : team.map(\.name).joined(separator: ", "))
                    LabeledContent("Начало и срок", value: [project.startDate ?? "—", project.endDate ?? "—"].joined(separator: " / "))
                    detail("Описание", project.description)
                    detail("Цель", project.goal)
                    detail("Материалы", project.materials)
                    detail("Ближайший этап", project.nextMilestone)
                    detail("Срок этапа", project.nextMilestoneDate)
                    detail("Что мешает работе", project.blocker)
                    Divider()
                    Text("Встречи").font(.headline)
                    let meetings = workspace.meetings.filter { $0.projectId == project.id }
                    if meetings.isEmpty { Text("Встреч пока нет").foregroundStyle(.secondary) }
                    ForEach(meetings) { meeting in
                        Button(meeting.title) { openMeeting(meeting.id) }.buttonStyle(.link)
                    }
                    Divider()
                    Text("Решения").font(.headline)
                    let decisions = workspace.decisions.filter { $0.projectId == project.id }
                    if decisions.isEmpty { Text("Подтверждённых решений пока нет").foregroundStyle(.secondary) }
                    ForEach(decisions) { decision in
                        HStack {
                            Text(decision.text).textSelection(.enabled)
                            if let id = decision.meetingId {
                                Button("К встрече") { openMeeting(id) }.buttonStyle(.link)
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 250)
        }
    }

    @ViewBuilder
    private func detail(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).textSelection(.enabled)
            }
        }
    }
}

struct ProjectDirectory: View {
    struct Filters {
        var query = ""
        var status = ""
        var owner = ""
        var cards = true

        var isActive: Bool { !status.isEmpty || !owner.isEmpty }
    }

    @Environment(\.colorScheme) private var scheme
    let workspace: Workspace
    @Binding var archived: Bool
    @Binding var filters: Filters
    let openProject: (Int) -> Void
    let openTask: (Int) -> Void
    @State private var expandedProjects: Set<Int> = []

    private var palette: PanelPalette { PanelPalette(dark: scheme == .dark) }

    private var projects: [Project] {
        let search = filters.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return workspace.projects.filter { project in
            (project.archived == true) == archived
            && (filters.status.isEmpty || filters.status == project.status)
            && (filters.owner.isEmpty || filters.owner == (project.ownerId.map(String.init) ?? "none"))
            && (search.isEmpty || [project.title, project.description, project.goal, project.materials,
                                   project.nextMilestone, project.blocker].compactMap { $0 }
                .joined(separator: " ").localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        let results = projects
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { sectionPicker; Spacer(minLength: 8); viewPicker }
                        VStack(alignment: .leading, spacing: 8) { sectionPicker; viewPicker }
                    }
                    HStack(spacing: 8) {
                        PanelSearchField(placeholder: "Поиск проектов", query: $filters.query)
                        filterMenu
                    }
                }
                .panelCard()
                Text("Проектов: \(results.count)").font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(palette.muted)
                if results.isEmpty {
                    Label(archived ? "В архиве нет подходящих проектов" : "Проекты не найдены",
                          systemImage: archived ? "archivebox" : "folder")
                        .foregroundStyle(.secondary).panelCard()
                } else {
                    LazyVGrid(columns: filters.cards ? [GridItem(.adaptive(minimum: 240), spacing: 12, alignment: .top)]
                              : [GridItem(.flexible())], alignment: .leading, spacing: 12) {
                        ForEach(results) { project in
                            if filters.cards {
                                Button { openProject(project.id) } label: { projectRow(project) }
                                    .buttonStyle(.plain)
                            } else {
                                projectListRow(project)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1360)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var sectionPicker: some View {
        Picker("Раздел", selection: $archived) {
            Label("Рабочие проекты", systemImage: "folder").tag(false)
            Label("Архив", systemImage: "archivebox").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var viewPicker: some View {
        Picker("Вид проектов", selection: $filters.cards) {
            Label("Карточки", systemImage: "square.grid.2x2").tag(true)
            Label("Список", systemImage: "list.bullet").tag(false)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var filterMenu: some View {
        Menu {
            Menu("Статус") {
                Picker("Статус", selection: $filters.status) {
                    Text("Все статусы").tag("")
                    ForEach(projectStatusOptions, id: \.id) { Text($0.title).tag($0.id) }
                }
                .pickerStyle(.inline)
            }
            Menu("Владелец") {
                Picker("Владелец", selection: $filters.owner) {
                    Text("Все владельцы").tag("")
                    Text("Не назначен").tag("none")
                    ForEach(workspace.people) { Text($0.speakerPickerName).tag(String($0.id)) }
                }
                .pickerStyle(.inline)
            }
            if filters.isActive {
                Divider()
                Button("Сбросить фильтры") {
                    filters.status = ""
                    filters.owner = ""
                }
            }
        } label: {
            Label("Фильтры", systemImage: filters.isActive
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityValue(filters.isActive ? "Фильтры включены" : "Нет активных фильтров")
    }

    private func statusBadge(_ project: Project) -> some View {
        Text(projectStatusOptions.first { $0.id == project.status }?.title ?? project.status)
            .font(.caption.weight(.medium))
            .foregroundStyle(palette.selectedInk)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(palette.selected, in: Capsule())
    }

    private func projectListRow(_ project: Project) -> some View {
        let expanded = expandedProjects.contains(project.id)
        let tasks = workspace.visibleTasks.filter { $0.projectId == project.id }
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                if expanded { expandedProjects.remove(project.id) }
                else { expandedProjects.insert(project.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(project.title).font(.headline)
                    Spacer(minLength: 8)
                    statusBadge(project)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Развёрнуто" : "Свёрнуто")
            if expanded {
                Button("Открыть проект") { openProject(project.id) }
                    .buttonStyle(.link)
                if project.archived != true {
                    if tasks.isEmpty {
                        Text("В проекте пока нет задач.").foregroundStyle(.secondary)
                    }
                    ForEach(tasks) { task in
                        Button { openTask(task.id) } label: {
                            Label(task.title, systemImage: "doc.text")
                        }
                        .buttonStyle(.link)
                    }
                }
            }
        }
        .panelCard()
    }

    private func projectRow(_ project: Project) -> some View {
        let tasks = workspace.visibleTasks.filter { $0.projectId == project.id }
        let person = workspace.people.first { $0.id == project.ownerId }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: project.archived == true ? "archivebox" : "folder")
                    .foregroundStyle(palette.selectedInk)
                    .frame(width: 30, height: 30)
                    .background(palette.selected, in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityHidden(true)
                Spacer()
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.muted).accessibilityHidden(true)
            }
            Text(project.title).font(.headline).lineLimit(2)
            statusBadge(project)
            if let goal = project.goal, !goal.isEmpty { Text(goal).font(.callout).lineLimit(2) }
            Label(person?.speakerPickerName ?? "Владелец не назначен", systemImage: "person")
                .font(.caption).foregroundStyle(palette.muted).lineLimit(1)
            let dates = [project.startDate, project.endDate].compactMap { $0 }.joined(separator: " – ")
            if !dates.isEmpty {
                Label(dates, systemImage: "calendar").font(.caption.monospacedDigit())
                    .foregroundStyle(palette.muted)
            }
            if project.archived != true {
                Text("\(tasks.filter { $0.stageKind == "active" }.count) текущих · \(tasks.filter(\.overdue).count) просроченных")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .panelCard()
        .contentShape(Rectangle())
    }
}
