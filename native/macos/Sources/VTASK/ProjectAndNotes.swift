import AppKit
import SwiftUI

private let projectStatusOptions: [(id: String, title: String)] = [
    ("planned", "Запланирован"), ("active", "В работе"), ("paused", "Приостановлен"),
    ("completed", "Завершён"), ("cancelled", "Отменён")
]

private extension Project {
    var overviewDescription: String? {
        guard let text = description?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

struct ProjectStatusBadge: View {
    var archived: Bool
    var status: String
    let palette: PanelPalette

    var body: some View {
        let title = projectStatusOptions.first { $0.id == status }?.title ?? status
        let active = !archived && status == "active"
        let ink = active ? (palette.dark ? Color(red: 0.47, green: 0.90, blue: 0.65)
                                          : Color(red: 0.06, green: 0.41, blue: 0.24))
            : archived ? palette.muted : palette.projectAccent
        return Label {
            Text(archived ? "В архиве" : title)
        } icon: {
            Image(systemName: archived ? "archivebox" : "circle.fill")
                .font(archived ? .caption : .system(size: 6))
                .accessibilityHidden(true)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(ink)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(active ? ink.opacity(0.13) : archived ? palette.sidebar : palette.selected, in: Capsule())
    }
}

struct ProjectFolderIcon: View {
    let palette: PanelPalette
    let size: CGFloat

    var body: some View {
        Image(systemName: "square.3.layers.3d")
            .font(.system(size: size * 0.43, weight: .medium))
            .foregroundStyle(palette.projectAccent)
            .frame(width: size, height: size)
            .background(palette.projectAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.26))
            .accessibilityHidden(true)
    }
}

struct ProjectEditor: View {
    enum Target: Hashable {
        case details, dates, periods, team
    }

    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: WorkspaceModel
    let project: Project
    let target: Target
    let close: () -> Void

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
    @State private var industries: [String]
    @State private var board: BoardDraft
    @State private var workPeriods: [ProjectWorkPeriod]
    @State private var catalogOpen = false
    @State private var titleToSave: String?
    @FocusState private var focusedWorkPeriod: String?

    init(model: WorkspaceModel, project: Project, target: Target, close: @escaping () -> Void) {
        self.model = model
        self.project = project
        self.target = target
        self.close = close
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
        _industries = State(initialValue: project.terminologyIndustries ?? [])
        _workPeriods = State(initialValue: project.workPeriods ?? [])
        _board = State(initialValue: BoardDraft(stages: project.stages))
    }

    private var occupiedRemovedStages: [Stage] {
        let occupied = Set((model.workspace?.tasks ?? []).filter { $0.projectId == project.id }.map(\.stageId))
        return board.removedOccupiedStages(original: project.stages, occupied: occupied)
    }

    var body: some View {
        let palette = PanelPalette(dark: scheme == .dark)
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { scroll in
                fields.task(id: target) {
                    scroll.scrollTo(target, anchor: .top)
                }
            }
            Divider()
            actions
                .padding(.horizontal, 15)
                .padding(.vertical, 9)
                .background(palette.surface)
        }
        .background(palette.background.opacity(0.55))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(model.saving || model.loading)
        .sheet(isPresented: $catalogOpen) {
            WorkPeriodCatalogView(model: model, industry: workPeriodIndustry, titleToSave: titleToSave,
                                  addToProject: addWorkPeriod)
        }
    }

    private var fields: some View {
        Form {
            Section {
                TextField("Название", text: $title)
                    .multilineTextAlignment(.leading)
                TextField("Краткое описание", text: $description,
                          prompt: Text("О чём проект в одном или двух предложениях"), axis: .vertical)
                    .lineLimit(2...5)
                    .multilineTextAlignment(.leading)
                TextField("Цель", text: $goal, axis: .vertical)
                    .multilineTextAlignment(.leading)
                TextField("Материалы", text: $materials, axis: .vertical)
                    .multilineTextAlignment(.leading)
                Picker("Статус", selection: $status) {
                    ForEach(projectStatusOptions, id: \.id) { Text($0.title).tag($0.id) }
                }
            } header: {
                Label("Основное", systemImage: "info.circle")
            }
            .id(Target.details)
            if let workspace = model.workspace {
                IndustrySelectionField(options: workspace.industryOptions, specializations: workspace.specializationCatalog ?? [],
                    inheritedTitle: "Из настроек · " + workspace.industryTitle, selection: $industries)
            }
            Section {
                ProjectDateField(title: "Начало", value: $start)
                ProjectDateField(title: "Срок завершения", value: $end)
                if !start.isEmpty, !end.isEmpty, start > end {
                    Text("Дата завершения раньше начала проекта.").foregroundStyle(.red)
                }
            } header: {
                Label("Сроки", systemImage: "calendar")
            }
            .id(Target.dates)
            workPeriodFields.id(Target.periods)
            teamFields.id(Target.team)
            Section("План и риски") {
                if project.nextMilestone?.isEmpty == false || project.nextMilestoneDate?.isEmpty == false {
                    TextField("Этап из прежнего плана", text: $milestone)
                    ProjectDateField(title: "Срок этапа", value: $milestoneDate)
                }
                TextField("Что мешает работе", text: $blocker, axis: .vertical)
            }
            BoardColumnFields(draft: $board, removed: occupiedRemovedStages)
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
        .tint(PanelPalette(dark: scheme == .dark).projectAccent)
        .scrollContentBackground(.hidden)
        .frame(maxHeight: .infinity)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
            }
            HStack {
                Label("Редактирование проекта", systemImage: "pencil")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 5)
                Button("Отменить", action: close)
                Button {
                    Task {
                        if await model.updateProject(project, changes: [
                            "title": title, "description": description, "goal": goal, "materials": materials,
                            "status": status, "start_date": start.isEmpty ? NSNull() as Any : start,
                            "end_date": end.isEmpty ? NSNull() as Any : end,
                            "owner_id": ownerID.map { $0 as Any } ?? NSNull(),
                            "members": members.sorted(),
                            "next_milestone": milestone, "next_milestone_date": milestoneDate,
                            "blocker": blocker,
                            "terminology_industries": industries,
                            "work_periods": workPeriods.map { period -> [String: Any] in
                                ["id": period.id, "title": period.title,
                                 "start_date": period.startDate.map { $0 as Any } ?? NSNull(),
                                 "end_date": period.endDate.map { $0 as Any } ?? NSNull()]
                            },
                            "stages": board.payload
                        ], migrations: board.migrations) {
                            close()
                        }
                    }
                } label: {
                    Text("Сохранить")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Color(red: 0.40, green: 0.24, blue: 0.83), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .opacity(canSave ? 1 : 0.50)
                .disabled(!canSave)
            }
            .buttonStyle(.bordered)
        }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (start.isEmpty || end.isEmpty || start <= end) &&
            !workPeriods.contains { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.datesAreReversed } &&
            board.canSave(removed: occupiedRemovedStages)
    }

    private var workPeriodIndustry: String {
        if model.workspace?.eventWorkPeriodLists != nil,
           let key = industries.first.flatMap({ IndustryTemplate(rawValue: $0).eventWorkPeriodListKey }) {
            return "events/" + key
        }
        let industry = industries.first.map { IndustryTemplate(rawValue: $0).parent.rawValue }
            ?? model.workspace?.settings.industryTemplate?.rawValue ?? "universal"
        return industry == "events" && model.workspace?.eventWorkPeriodLists != nil ? "" : industry
    }

    private var workPeriodFields: some View {
        Section("Этапы работ") {
            ForEach($workPeriods) { $period in
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        TextField("Название этапа работ", text: $period.title)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedWorkPeriod, equals: period.id)
                        Menu {
                            Button("Сохранить в справочник") {
                                openWorkPeriodCatalog(title: period.title)
                            }
                            .disabled(period.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("Убрать этап работ", role: .destructive) {
                                let id = period.id
                                workPeriods.removeAll { $0.id == id }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .accessibilityLabel("Действия этапа работ")
                        }
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                    ProjectDateField(title: "Начало работ", value: optionalWorkDate($period.startDate))
                    ProjectDateField(title: "Окончание работ", value: optionalWorkDate($period.endDate))
                    if period.datesAreReversed {
                        Text("Окончание этапа раньше его начала.").font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(.vertical, 4)
            }
            HStack {
                Button {
                    addWorkPeriod("")
                } label: {
                    Label("Добавить этап работ", systemImage: "plus")
                }
                Button {
                    openWorkPeriodCatalog()
                } label: {
                    Label("Из справочника", systemImage: "books.vertical")
                }
            }
            .buttonStyle(.borderless)
        }
    }

    private func addWorkPeriod(_ title: String) {
        let period = ProjectWorkPeriod(id: UUID().uuidString, title: title)
        workPeriods.append(period)
        focusedWorkPeriod = period.id
    }

    private func openWorkPeriodCatalog(title: String? = nil) {
        titleToSave = title
        catalogOpen = true
    }

    private func optionalWorkDate(_ date: Binding<String?>) -> Binding<String> {
        Binding(get: { date.wrappedValue ?? "" }, set: { date.wrappedValue = $0.isEmpty ? nil : $0 })
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
    let openDecisions: () -> Void
    let photoURL: (Person) -> URL?
    let openBoard: () -> Void
    let editProject: (ProjectEditor.Target) -> Void
    let editingDisabled: Bool
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
        let tasks = workspace.tasks.filter { $0.projectId == project.id && $0.stageKind != "cancelled" }
        let active = tasks.filter { $0.stageKind == "active" }
        let critical = tasks.filter { $0.priority == "critical" }
        let risks = active.filter { $0.overdue || $0.blocked == true || ($0.priority == "critical" && $0.dueDate == nil) }
        let decisions = workspace.decisions.filter { $0.projectId == project.id && $0.active }.count
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                overviewPair {
                    progressCard(tasks)
                    counters(tasks: tasks.count, decisions: decisions, risks: risks)
                }
                overviewPair {
                    summaryCard
                    datesCard
                }
                overviewPair {
                    teamCard
                    terminologyCard
                }
                if project.archived != true {
                    criticalTasksCard(critical)
                    if tracksSchedule {
                        riskChart(active)
                        if let selectedMetric {
                            metricDetails(selectedMetric.rawValue, tasks: active.filter {
                                selectedMetric.matches($0, today: workspace.today)
                            })
                        } else if !risks.isEmpty {
                            metricDetails("Требуют внимания", tasks: risks)
                        }
                    }
                }
                if !(project.goal ?? "").isEmpty || !(project.blocker ?? "").isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        overviewHeading("Детали проекта", icon: "info.circle")
                        detail("Цель", project.goal)
                        detail("Блокировка проекта", project.blocker)
                    }
                    .panelCard()
                }
            }
            .padding(14)
            .frame(maxWidth: 960)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private func overviewPair<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 11, content: content)
            VStack(alignment: .leading, spacing: 11, content: content)
        }
    }

    private func overviewHeading(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.headline)
            .foregroundStyle(palette.text)
            .accessibilityAddTraits(.isHeader)
    }

    private func progressCard(_ tasks: [TaskItem]) -> some View {
        let percent = ProjectProgress.percent(tasks)
        return VStack(alignment: .leading, spacing: 7) {
            overviewHeading("Прогресс проекта", icon: "chart.bar")
            Text(tasks.isEmpty ? "Нет задач" : "\(percent)%")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
            ProjectProgress(value: percent)
            if project.archived != true {
                Button(action: openBoard) {
                    Label("Доска задач", systemImage: "rectangle.split.3x1")
                }
                .buttonStyle(.link)
            }
        }
        .frame(minWidth: 176, alignment: .leading)
        .panelCard(inset: 13)
    }

    private func counters(tasks: Int, decisions: Int, risks: [TaskItem]) -> some View {
        HStack(spacing: 9) {
            counter("Задачи", value: tasks, icon: "checkmark.square",
                    action: project.archived == true ? nil : openTasks)
            Divider().frame(height: 37)
            counter("Решения", value: decisions, icon: "bolt", action: openDecisions)
            Divider().frame(height: 37)
            counter("Риски", value: risks.count, icon: "exclamationmark.triangle", tint: .orange)
        }
        .frame(minWidth: 208, minHeight: 88)
        .panelCard(inset: 13)
    }

    private func counter(_ title: String, value: Int, icon: String,
                         tint: Color? = nil, action: (() -> Void)? = nil) -> some View {
        let content = VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon).font(.callout.weight(.semibold))
                .foregroundStyle(tint ?? palette.accent).accessibilityHidden(true)
            Text(value.formatted()).font(.title3.bold()).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(palette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        return Group {
            if let action { Button(action: action) { content.contentShape(Rectangle()) }.buttonStyle(.plain) }
            else { content }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            overviewHeading("Краткое описание", icon: "doc.text")
            if let description = project.overviewDescription {
                Text(description).lineSpacing(3).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button("Добавить описание") { editProject(.details) }.buttonStyle(.link).disabled(editingDisabled)
            }
        }
        .frame(minWidth: 176, alignment: .topLeading)
        .panelCard(inset: 13)
    }

    private var datesCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            overviewHeading("Ключевые даты", icon: "calendar")
            dateRow("Начало", project.startDate)
            if let milestone = project.nextMilestone, !milestone.isEmpty {
                dateRow(milestone, project.nextMilestoneDate)
            }
            dateRow("Завершение", project.endDate)
            Button("Изменить сроки") { editProject(.dates) }
                .buttonStyle(.link).disabled(editingDisabled)
            Divider()
            ForEach(project.workPeriods ?? []) { period in
                keyDateRow(period.title, value: workPeriodLabel(period), icon: "calendar")
            }
            Button(project.workPeriods?.isEmpty != false ? "Добавить этап работ" : "Редактировать этапы работ") {
                editProject(.periods)
            }
            .buttonStyle(.link)
            .disabled(editingDisabled)
        }
        .frame(minWidth: 178, alignment: .topLeading)
        .panelCard(inset: 13)
    }

    private func dateRow(_ title: String, _ date: String?) -> some View {
        keyDateRow(title, value: date.map(ProjectDateField.display) ?? "Без даты", icon: "circle")
    }

    private func keyDateRow(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.caption)
                .foregroundStyle(palette.accent).accessibilityHidden(true)
            Text(title).lineLimit(2)
            Spacer(minLength: 5)
            Text(value).font(.caption).foregroundStyle(palette.muted)
                .multilineTextAlignment(.trailing)
        }
    }

    private func workPeriodLabel(_ period: ProjectWorkPeriod) -> String {
        switch (period.startDate.map(ProjectDateField.display), period.endDate.map(ProjectDateField.display)) {
        case let (.some(start), .some(end)): return start == end ? start : start + " – " + end
        case let (.some(start), .none): return "с " + start
        case let (.none, .some(end)): return "до " + end
        case (.none, .none): return "Без дат"
        }
    }

    private var teamCard: some View {
        let memberIDs = Set((project.members ?? []) + [project.ownerId].compactMap { $0 })
        let members = workspace.people.filter { memberIDs.contains($0.id) }
        let owner = members.first { $0.id == project.ownerId }
        return VStack(alignment: .leading, spacing: 9) {
            overviewHeading("Команда · \(members.count)", icon: "person.2")
            if !members.isEmpty {
                HStack(spacing: -3) {
                    ForEach(members.prefix(5)) { person in
                        PersonAvatar(person: person, url: photoURL(person), size: 30)
                            .overlay { Circle().strokeBorder(palette.surface, lineWidth: 1.5) }
                            .help(person.speakerPickerName)
                    }
                    if members.count > 5 {
                        Text("+\(members.count - 5)").font(.caption.weight(.medium))
                            .frame(width: 30, height: 30).background(palette.selected, in: Circle())
                            .help(members.dropFirst(5).map(\.speakerPickerName).joined(separator: ", "))
                    }
                }
            }
            Text(owner.map { "Владелец · " + $0.speakerPickerName } ?? "Владелец не назначен")
                .font(.callout).foregroundStyle(palette.muted)
            Button("Изменить команду") { editProject(.team) }
                .buttonStyle(.link).disabled(editingDisabled)
        }
        .frame(minWidth: 158, alignment: .topLeading)
        .panelCard(inset: 13)
    }

    private var terminologyCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            overviewHeading("Направления", icon: "tag")
            Text(workspace.terminologyTitles(project.terminologyIndustries ?? []))
                .font(.callout)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(palette.selected, in: RoundedRectangle(cornerRadius: 6))
        }
        .frame(minWidth: 155, alignment: .topLeading)
        .panelCard(inset: 13)
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

struct ProjectProgress: View {
    let value: Int

    static func percent(_ tasks: [TaskItem]) -> Int {
        guard !tasks.isEmpty else { return 0 }
        return Int((100 * Double(tasks.filter { $0.stageKind == "done" }.count) / Double(tasks.count)).rounded())
    }

    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(Color.secondary.opacity(0.16))
                .overlay(alignment: .leading) {
                    Capsule().fill(LinearGradient(colors: [
                        Color(red: 0.68, green: 0.41, blue: 1),
                        Color(red: 0.43, green: 0.29, blue: 0.91)
                    ], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geometry.size.width * CGFloat(value) / 100)
                }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

struct ProjectDetailHeader: View {
    @Environment(\.colorScheme) private var scheme
    let project: Project
    let direction: String
    let actionsDisabled: Bool
    let editing: Bool
    let edit: () -> Void
    let changeStatus: (String) -> Void
    let archive: () -> Void
    let createMeeting: () -> Void
    let createTask: () -> Void
    let createDecision: () -> Void

    private static let ribbon: NSImage? = {
        let url = Bundle.main.url(forResource: "settings-ribbon", withExtension: "png")
            ?? Bundle.module.url(forResource: "settings-ribbon", withExtension: "png")
        return url.flatMap(NSImage.init(contentsOf:))
    }()

    var body: some View {
        let palette = PanelPalette(dark: scheme == .dark)
        HStack(alignment: .top, spacing: 11) {
            ProjectFolderIcon(palette: palette, size: 50)
            VStack(alignment: .leading, spacing: 5) {
                Text(project.title).font(.system(size: 24, weight: .bold))
                    .lineLimit(2).accessibilityAddTraits(.isHeader)
                Text(direction).font(.callout).foregroundStyle(palette.muted).lineLimit(1)
                statusControl(palette)
            }
            Spacer(minLength: 4)
            if !editing {
                Button(action: edit) {
                    Label("Редактировать", systemImage: "pencil")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(palette.projectAccent)
                        .fixedSize()
                }
                .buttonStyle(.bordered)
                .disabled(actionsDisabled)
            }
            Menu {
                if project.archived != true {
                    Button("Новое совещание", action: createMeeting)
                    Button("Новая задача", action: createTask)
                    Button("Новое решение", action: createDecision)
                }
                Divider()
                Button(project.archived == true ? "Восстановить проект" : "Перенести в архив", action: archive)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline)
                    .accessibilityLabel("Действия проекта")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(actionsDisabled)
        }
        .padding(13)
        .background(alignment: .trailing) {
            if let ribbon = Self.ribbon {
                Image(nsImage: ribbon).resizable().scaledToFit()
                    .frame(maxWidth: 280, maxHeight: 88)
                    .opacity(scheme == .dark ? 0.2 : 0.7)
                    .mask(LinearGradient(colors: [.clear, .white, .white], startPoint: .leading, endPoint: .trailing))
                    .accessibilityHidden(true)
            }
        }
        .background(palette.selected.opacity(scheme == .dark ? 0.24 : 0.42))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .padding(8)
    }

    @ViewBuilder
    private func statusControl(_ palette: PanelPalette) -> some View {
        let badge = ProjectStatusBadge(archived: project.archived == true, status: project.status, palette: palette)
        if project.archived == true || editing {
            badge
        } else {
            Menu {
                ForEach(projectStatusOptions, id: \.id) { option in
                    Button { changeStatus(option.id) } label: {
                        if option.id == project.status { Label(option.title, systemImage: "checkmark") }
                        else { Text(option.title) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    badge
                    Image(systemName: "chevron.down").font(.caption2).foregroundStyle(palette.projectAccent)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Статус проекта")
            .accessibilityValue(projectStatusOptions.first { $0.id == project.status }?.title ?? project.status)
            .disabled(actionsDisabled)
        }
    }
}

struct ProjectDirectoryFilters {
    enum Section: String, CaseIterable {
        case current = "Актуальные"
        case all = "Все проекты"
        case archive = "Архив"
        case favorites = "Избранные"
    }

    enum Sort: String, CaseIterable {
        case recent = "По обновлению"
        case title = "По названию"
        case deadline = "По сроку"
    }

    var query = ""
    var status = ""
    var owner = ""
    var cards = true
    var section = Section.current
    var sort = Sort.recent

    var isActive: Bool { !status.isEmpty || !owner.isEmpty }
}

struct ProjectDirectory<Detail: View>: View {
    @Environment(\.colorScheme) private var scheme
    @AppStorage("favoriteProjectIDs") private var savedFavorites = ""
    let workspace: Workspace
    @Binding var filters: ProjectDirectoryFilters
    let selected: Project?
    let allowsSplit: Bool
    let openProject: (Int) -> Void
    let closeProject: () -> Void
    let createProject: () -> Void
    let openTask: (Int) -> Void
    let editProject: (Project) -> Void
    let changeArchive: (Project) -> Void
    let actionsDisabled: Bool
    @ViewBuilder let detail: () -> Detail
    @State private var expandedProjects: Set<Int> = []

    private var palette: PanelPalette { PanelPalette(dark: scheme == .dark) }
    private var favorites: Set<Int> { Set(savedFavorites.split(separator: ",").compactMap { Int($0) }) }

    private func includes(_ project: Project, in section: ProjectDirectoryFilters.Section) -> Bool {
        switch section {
        case .all: return project.archived != true
        case .current: return project.isCurrent
        case .archive: return project.archived == true
        case .favorites: return project.archived != true && favorites.contains(project.id)
        }
    }

    private var projects: [Project] {
        let search = filters.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = workspace.projects.filter { project in
            includes(project, in: filters.section)
            && (filters.status.isEmpty || filters.status == project.status)
            && (filters.owner.isEmpty || filters.owner == (project.ownerId.map(String.init) ?? "none"))
            && (search.isEmpty || [project.title, project.description, project.goal, project.materials,
                                   project.nextMilestone, project.blocker].compactMap { $0 }
                .joined(separator: " ").localizedCaseInsensitiveContains(search))
        }
        return filtered.sorted { first, second in
            switch filters.sort {
            case .recent:
                let left = first.updatedAt ?? ""
                let right = second.updatedAt ?? ""
                return left == right ? first.id > second.id : left > right
            case .title:
                let order = first.title.localizedStandardCompare(second.title)
                return order == .orderedSame ? first.id < second.id : order == .orderedAscending
            case .deadline:
                let left = first.endDate ?? "9999"
                let right = second.endDate ?? "9999"
                return left == right ? first.id > second.id : left < right
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let results = projects
            let split = allowsSplit && filters.cards && geometry.size.width >= 750
            VStack(alignment: .leading, spacing: 12) {
                if selected == nil || split {
                    toolbar
                } else {
                    Button(action: closeProject) { Label("Все проекты", systemImage: "chevron.left") }
                        .buttonStyle(.link)
                }
                if split {
                    let width = min(330, max(255, geometry.size.width * 0.34))
                    HStack(alignment: .top, spacing: 12) {
                        directory(results, singleColumn: true).frame(width: width)
                        details
                    }
                } else if selected != nil {
                    details
                } else {
                    directory(results, singleColumn: !filters.cards)
                }
            }
            .padding(.horizontal, 15)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var details: some View {
        Group {
            if selected != nil {
                detail()
            } else {
                VStack(spacing: 10) {
                    ProjectFolderIcon(palette: palette, size: 54)
                    Text("Выберите проект").font(.headline)
                    Text("Здесь появятся обзор, задачи и совещания.").font(.callout).foregroundStyle(palette.muted)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(palette.border).allowsHitTesting(false) }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 9) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { sectionPicker; Spacer(minLength: 0); createButton }
                VStack(alignment: .leading, spacing: 9) { sectionPicker; createButton }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { search; filterMenu; sortMenu; viewPicker }
                VStack(alignment: .leading, spacing: 8) {
                    search
                    HStack { filterMenu; sortMenu; viewPicker }
                }
            }
        }
        .padding(.top, 12)
    }

    private var search: some View {
        PanelSearchField(placeholder: "Поиск по проектам…", query: $filters.query)
    }

    private var createButton: some View {
        Button(action: createProject) {
            Label("Создать проект", systemImage: "plus")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color(red: 0.40, green: 0.24, blue: 0.83), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(actionsDisabled ? 0.55 : 1)
        .disabled(actionsDisabled)
    }

    private var sectionPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(ProjectDirectoryFilters.Section.allCases, id: \.self) { section in
                    let count = workspace.projects.filter { includes($0, in: section) }.count
                    Button {
                        filters.section = section
                    } label: {
                        HStack(spacing: 6) {
                            Text(section.rawValue).font(.callout.weight(.semibold))
                            Text(count.formatted()).font(.caption.monospacedDigit())
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(palette.accent.opacity(0.12), in: Capsule())
                        }
                        .padding(.vertical, 6).padding(.horizontal, 8)
                        .foregroundStyle(section == filters.section ? palette.projectAccent : palette.text)
                        .background(section == filters.section ? palette.projectAccent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(section == filters.section ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(ProjectDirectoryFilters.Sort.allCases, id: \.self) { option in
                Button {
                    filters.sort = option
                } label: {
                    if filters.sort == option {
                        Label(option.rawValue, systemImage: "checkmark")
                    } else {
                        Text(option.rawValue)
                    }
                }
            }
        } label: {
            Label(filters.sort.rawValue, systemImage: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Сортировка проектов")
        .accessibilityValue(filters.sort.rawValue)
        .fixedSize()
    }

    private func directory(_ results: [Project], singleColumn: Bool) -> some View {
        ScrollView {
            if results.isEmpty {
                Label(filters.section == .archive ? "В архиве нет подходящих проектов" : "Проекты не найдены",
                      systemImage: "folder").foregroundStyle(palette.muted).panelCard()
            } else {
                LazyVGrid(columns: singleColumn ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 235))],
                          alignment: .leading, spacing: 8) {
                    ForEach(results) { project in
                        if filters.cards { projectCard(project) }
                        else { projectListRow(project) }
                    }
                }
            }
        }
        .padding(1)
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
                        ProjectStatusBadge(archived: project.archived == true, status: project.status, palette: palette)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "Развёрнуто" : "Свёрнуто")
                projectActions(project, includesEdit: true)
            }
            if expanded {
                if let description = project.overviewDescription {
                    Text(description).font(.callout).foregroundStyle(palette.muted).lineLimit(3)
                }
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
        .contextMenu { projectMenuItems(project, includesEdit: true) }
    }

    private func projectActions(_ project: Project, includesEdit: Bool = false) -> some View {
        Menu {
            projectMenuItems(project, includesEdit: includesEdit)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Действия проекта «\(project.title)»")
        .fixedSize()
        .disabled(actionsDisabled)
    }

    @ViewBuilder
    private func projectMenuItems(_ project: Project, includesEdit: Bool) -> some View {
        Button { openProject(project.id) } label: {
            Label("Открыть проект", systemImage: "folder")
        }
        if includesEdit {
            Button { editProject(project) } label: {
                Label("Редактировать карточку", systemImage: "square.and.pencil")
            }
            .disabled(actionsDisabled)
        }
        Button { toggleFavorite(project.id) } label: {
            let favorite = favorites.contains(project.id)
            Label(favorite ? "Убрать из избранного" : "В избранное",
                  systemImage: favorite ? "star.slash" : "star")
        }
        Divider()
        Button { changeArchive(project) } label: {
            Label(project.archived == true ? "Восстановить проект" : "Перенести в архив",
                  systemImage: project.archived == true ? "arrow.uturn.backward" : "archivebox")
        }
        .disabled(actionsDisabled)
    }

    private func toggleFavorite(_ id: Int) {
        var ids = favorites
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        savedFavorites = ids.sorted().map(String.init).joined(separator: ",")
    }

    private func projectCard(_ project: Project) -> some View {
        let tasks = workspace.tasks.filter { $0.projectId == project.id && $0.stageKind != "cancelled" }
        let progress = ProjectProgress.percent(tasks)
        let memberIDs = Set((project.members ?? []) + [project.ownerId].compactMap { $0 })
        let isSelected = selected?.id == project.id
        let isFavorite = favorites.contains(project.id)
        let shape = RoundedRectangle(cornerRadius: 11)
        return HStack(alignment: .top, spacing: 8) {
            Button {
                openProject(project.id)
            } label: {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .top, spacing: 8) {
                        ProjectFolderIcon(palette: palette, size: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(project.title).font(.headline).lineLimit(2)
                            Text(workspace.terminologyTitles(project.terminologyIndustries ?? []))
                                .font(.caption).foregroundStyle(palette.muted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 7) {
                        ProjectProgress(value: progress)
                        Text("\(progress)%").font(.caption.weight(.semibold)).monospacedDigit()
                    }
                    HStack(spacing: 9) {
                        Label(project.endDate.map(ProjectDateField.display) ?? "Без срока", systemImage: "calendar")
                        Label(memberIDs.count.formatted(), systemImage: "person.2")
                        Label(tasks.count.formatted(), systemImage: "checkmark.square")
                    }
                    .font(.caption)
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            VStack(alignment: .trailing, spacing: 8) {
                Button { toggleFavorite(project.id) } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .foregroundStyle(isFavorite ? palette.accent : palette.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isFavorite ? "Убрать из избранного" : "В избранное")
                ProjectStatusBadge(archived: project.archived == true, status: project.status, palette: palette)
                if !isSelected {
                    projectActions(project, includesEdit: true)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(10)
        .background(isSelected ? palette.projectAccent.opacity(0.09) : palette.surface, in: shape)
        .overlay { shape.strokeBorder(isSelected ? palette.projectAccent : palette.border, lineWidth: isSelected ? 1.5 : 1)
            .allowsHitTesting(false) }
        .contextMenu { projectMenuItems(project, includesEdit: true) }
    }
}
