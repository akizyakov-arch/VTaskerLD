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
                ProjectDateField(title: "Начало", value: $start)
                ProjectDateField(title: "Срок завершения", value: $end)
            }
            teamFields
            Section("План и риски") {
                if project.nextMilestone?.isEmpty == false || project.nextMilestoneDate?.isEmpty == false {
                    TextField("Этап из прежнего плана", text: $milestone)
                    ProjectDateField(title: "Срок этапа", value: $milestoneDate)
                }
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
                        if await model.setProjectArchived(project.archived != true, project: project) {
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
    @Environment(\.colorScheme) private var scheme
    let project: Project
    let workspace: Workspace
    let openTask: (Int) -> Void
    let openTasks: () -> Void
    @State private var selectedMetric: Metric?

    private enum Metric: String, CaseIterable {
        case dueSoon = "Срок в ближайшие 7 дней"
        case overdue = "Просрочено"
        case blocked = "Заблокировано"
        case undated = "Без срока"

        var icon: String {
            switch self {
            case .dueSoon: return "calendar"
            case .overdue: return "exclamationmark.clock"
            case .blocked: return "hand.raised"
            case .undated: return "calendar.badge.exclamationmark"
            }
        }

        func matches(_ task: TaskItem, today: String) -> Bool {
            switch self {
            case .dueSoon: return TaskFilter.dueSoon.matches(task, today: today)
            case .overdue: return TaskFilter.overdue.matches(task, today: today)
            case .blocked: return task.blocked == true
            case .undated: return TaskFilter.undated.matches(task, today: today)
            }
        }
    }

    private var palette: PanelPalette { PanelPalette(dark: scheme == .dark) }
    private var tracksSchedule: Bool {
        project.archived != true && project.status != "completed" && project.status != "cancelled"
    }

    var body: some View {
        let projectTasks = workspace.visibleTasks.filter { $0.projectId == project.id }
        let active = projectTasks.filter { $0.stageKind == "active" }
        let critical = projectTasks.filter { $0.priority == "critical" && $0.stageKind != "cancelled" }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if project.archived != true {
                    criticalTasksCard(critical)
                    if tracksSchedule {
                        riskChart(active)
                        if let selectedMetric {
                            metricDetails(selectedMetric.rawValue, tasks: active.filter {
                                selectedMetric.matches($0, today: workspace.today)
                            })
                        } else {
                            let risks = active.filter { $0.overdue || $0.blocked == true || ($0.priority == "critical" && $0.dueDate == nil) }
                            if !risks.isEmpty { metricDetails("Требуют внимания", tasks: risks) }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    let owner = workspace.people.first { $0.id == project.ownerId }
                    LabeledContent("Владелец", value: owner?.name ?? "Не назначен")
                    let team = workspace.people.filter { (project.members ?? []).contains($0.id) }
                    LabeledContent("Команда", value: team.isEmpty ? "Без участников" : team.map(\.name).joined(separator: ", "))
                    LabeledContent("Начало и срок", value: [project.startDate, project.endDate]
                        .map { $0.map(ProjectDateField.display) ?? "—" }.joined(separator: " / "))
                    detail("Описание", project.description)
                    detail("Цель", project.goal)
                    detail("Материалы", project.materials)
                    detail("Блокировка проекта", project.blocker)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelCard()
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func criticalTasksCard(_ tasks: [TaskItem]) -> some View {
        let done = tasks.filter { $0.stageKind == "done" }.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Вехи проекта", systemImage: "flag.fill").font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if tracksSchedule {
                    Button("К задачам", action: openTasks).buttonStyle(.link)
                }
            }
            if tasks.isEmpty {
                Text("Задачи с приоритетом «Критический» появятся здесь.").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().stroke(palette.border, lineWidth: 4)
                        Circle().trim(from: 0, to: CGFloat(done) / CGFloat(tasks.count))
                            .stroke(palette.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(done)/\(tasks.count)").font(.caption2.weight(.semibold)).monospacedDigit()
                    }
                    .frame(width: 42, height: 42)
                    .accessibilityHidden(true)
                    Text("Выполнено критичных задач: \(done) из \(tasks.count)")
                        .font(.callout).foregroundStyle(palette.muted)
                }
                ForEach(orderedByDeadline(tasks)) { task in
                    scheduleRow(task)
                }
            }
        }
        .panelCard()
    }

    private func riskChart(_ tasks: [TaskItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Сроки и блокировки").font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(Metric.allCases, id: \.self) { metric in
                let count = tasks.filter { metric.matches($0, today: workspace.today) }.count
                let color = metric == .overdue || metric == .blocked ? palette.recordingInk : palette.accent
                Button {
                    selectedMetric = selectedMetric == metric ? nil : metric
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Label(metric.rawValue, systemImage: metric.icon)
                            Spacer()
                            Text(count, format: .number).monospacedDigit()
                            Image(systemName: selectedMetric == metric ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold)).accessibilityHidden(true)
                        }
                        GeometryReader { bar in
                            Capsule().fill(palette.border.opacity(0.55))
                            Capsule().fill(color)
                                .frame(width: bar.size.width * CGFloat(count) / CGFloat(max(1, tasks.count)))
                        }
                        .frame(height: 5)
                        .accessibilityHidden(true)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedMetric == metric ? .isSelected : [])
            }
        }
        .panelCard()
    }

    private func metricDetails(_ title: String, tasks: [TaskItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            if tasks.isEmpty {
                Text("Подходящих задач нет.").foregroundStyle(.secondary)
            }
            ForEach(orderedByDeadline(tasks)) { task in
                scheduleRow(task)
            }
        }
        .panelCard()
    }

    private func orderedByDeadline(_ tasks: [TaskItem]) -> [TaskItem] {
        tasks.sorted { ($0.dueDate ?? "9999", $0.dueTime ?? "23:59", $0.id) <
            ($1.dueDate ?? "9999", $1.dueTime ?? "23:59", $1.id) }
    }

    private func scheduleRow(_ task: TaskItem) -> some View {
        let done = task.stageKind == "done"
        let blocked = !done && task.blocked == true
        let overdue = !done && task.overdue
        let noDeadline = !done && task.dueDate == nil
        let risk = blocked || overdue
        let color = done ? Color.green : risk ? palette.recordingInk : noDeadline ? palette.muted : palette.accent
        let state = done ? "Выполнено" : [blocked ? "Заблокировано" : nil, overdue ? "Просрочено" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        let owner = workspace.people.first { $0.id == task.assigneeId }?.speakerPickerName
        let date = task.dueDate.map { [ProjectDateField.display($0), task.dueTime].compactMap { $0 }.joined(separator: " ") }
        return Button { openTask(task.id) } label: {
            HStack(spacing: 10) {
                Image(systemName: done ? "checkmark.circle.fill" : risk ? "exclamationmark.circle.fill" : "circle.fill")
                    .font(.system(size: risk || done ? 15 : 9)).foregroundStyle(color)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title).font(.callout.weight(.semibold)).foregroundStyle(risk ? color : palette.text)
                    Text([date ?? "Без срока", owner ?? "Без исполнителя", state.isEmpty ? nil : state,
                          blocked ? task.blockedReason : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(palette.muted)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(palette.muted).accessibilityHidden(true)
            }
            .padding(8)
            .background(risk ? palette.recordingSurface : palette.sidebar, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

struct ProjectDecisionDetails: View {
    @ObservedObject var model: WorkspaceModel
    let workspace: Workspace
    let decision: Decision
    let prior: Decision?
    let openMeeting: (Int) -> Void
    let openTask: (Int) -> Void
    @State private var confirmingCancellation = false

    var body: some View {
        let project = workspace.projects.first { $0.id == decision.projectId }
        let linkedTasks = workspace.visibleTasks.filter { (decision.taskIds ?? []).contains($0.id) }
        Form {
            Section {
                Text(decision.text).font(.headline).textSelection(.enabled)
                LabeledContent("Статус", value: decision.active ? "Согласовано" : decision.statusLabel)
                if let project { LabeledContent("Проект", value: project.title) }
            }
            if decision.reason != nil || prior != nil {
                Section("Контекст решения") {
                    if let reason = decision.reason {
                        LabeledContent("Обоснование", value: reason).textSelection(.enabled)
                    }
                    if let prior {
                        LabeledContent("Заменяет решение", value: prior.text).textSelection(.enabled)
                    }
                }
            }
            if !linkedTasks.isEmpty {
                Section("Связанные задачи") {
                    ForEach(linkedTasks) { task in
                        Button(task.title) { openTask(task.id) }.buttonStyle(.link)
                    }
                }
            }
            if decision.meetingId != nil || decision.source != nil {
                Section("Источник") {
                    if let id = decision.meetingId {
                        Button(workspace.meetings.first { $0.id == id }?.visibleTitle ?? "Открыть совещание") {
                            openMeeting(id)
                        }
                        .buttonStyle(.link)
                    }
                    if let quote = decision.source?.quote, !quote.isEmpty {
                        Text(quote).textSelection(.enabled)
                    }
                    ForEach(decision.source?.materialLinks ?? []) { link in
                        if let target = link.target { Link(link.label, destination: target) }
                    }
                }
            }
            if decision.active {
                Section {
                    Button("Отменить решение", role: .destructive) { confirmingCancellation = true }
                        .disabled(model.saving)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(maxHeight: .infinity)
        .confirmationDialog("Отменить решение?", isPresented: $confirmingCancellation) {
            Button("Отменить решение", role: .destructive) {
                Task { await model.command(["op": "cancel_decision", "id": decision.id]) }
            }
        } message: { Text(decision.text) }
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
    let editProject: (Project) -> Void
    let changeArchive: (Project) -> Void
    let actionsDisabled: Bool
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
                                VStack(alignment: .leading, spacing: 8) {
                                    Button { openProject(project.id) } label: { projectRow(project) }
                                        .buttonStyle(.plain)
                                    Divider()
                                    HStack {
                                        Button { editProject(project) } label: {
                                            Label("Карточка проекта", systemImage: "square.and.pencil")
                                        }
                                        .buttonStyle(.link)
                                        .disabled(actionsDisabled)
                                        Spacer(minLength: 4)
                                        projectActions(project)
                                    }
                                }
                                .panelCard()
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
        let tasks = workspace.visibleTasks.filter { $0.projectId == project.id && $0.stageKind != "cancelled" }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
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
                projectActions(project, includesEdit: true)
            }
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

    private func projectActions(_ project: Project, includesEdit: Bool = false) -> some View {
        Menu {
            if includesEdit {
                Button("Карточка проекта") { editProject(project) }
            }
            Button {
                changeArchive(project)
            } label: {
                Label(project.archived == true ? "Восстановить проект" : "Перенести в архив",
                      systemImage: project.archived == true ? "arrow.uturn.backward" : "archivebox")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Действия проекта «\(project.title)»")
        .fixedSize()
        .disabled(actionsDisabled)
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
            if let dates = project.startDate.map(ProjectDateField.display) ?? project.endDate.map(ProjectDateField.display) {
                let end = project.startDate == nil ? nil : project.endDate.map(ProjectDateField.display)
                Label([dates, end].compactMap { $0 }.joined(separator: " – "), systemImage: "calendar")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(palette.muted)
            }
            if project.archived != true {
                Text("\(tasks.filter { $0.stageKind == "active" }.count) текущих · \(tasks.filter(\.overdue).count) просроченных")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
