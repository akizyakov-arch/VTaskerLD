import SwiftUI

struct Proposal: Decodable, Identifiable {
    struct Source: Decodable {
        let quote: String?
        let meetingId: Int?
        let startMs: Int?
        let topic: String?
    }

    let id: Int
    let kind: String
    let status: String
    let title: String?
    let description: String?
    let projectId: Int?
    let assigneeId: Int?
    let dueDate: String?
    let dueTime: String?
    let source: Source?
    let taskId: Int?
    let proposed: Changes?

    struct Changes: Decodable {
        let dueDate: String?
        let dueTime: String?
        let assigneeId: Int?
        let stageId: String?
    }

    var presentation: (title: String, icon: String) {
        switch kind {
        case "create_task": return ("Новая задача", "plus.square")
        case "change_due": return ("Изменение срока", "calendar")
        case "change_assignee": return ("Смена исполнителя", "person.crop.circle")
        case "change_status": return ("Изменение статуса", "arrow.triangle.2.circlepath")
        case "decision": return ("Решение", "checkmark.seal")
        default: return ("Предложение", "tray")
        }
    }

    var displayTitle: String {
        let text = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? presentation.title : text
    }
}

struct Decision: Decodable, Identifiable {
    let id: Int
    let text: String
    let projectId: Int?
    let meetingId: Int?
    let source: Proposal.Source?
}

struct ApprovalsView: View {
    enum SortOrder: String, CaseIterable {
        case newest = "Сначала новые"
        case oldest = "Сначала старые"
        case title = "По названию"
        case deadline = "По ближайшему сроку"
    }

    enum ProjectFilter: Hashable {
        case all, none, project(Int)
    }

    enum AssigneeFilter: Hashable {
        case all, none, person(Int)
    }

    struct Filters {
        var query = ""
        var kind: String?
        var project = ProjectFilter.all
        var assignee = AssigneeFilter.all
        var sort = SortOrder.newest

        var isActive: Bool { kind != nil || project != .all || assignee != .all }

        mutating func reset() {
            kind = nil
            project = .all
            assignee = .all
        }
    }

    private struct Row: Identifiable {
        let proposal: Proposal
        let target: TaskItem?
        let project: Project?
        let assignee: Person?
        let meeting: Meeting?

        var id: Int { proposal.id }
        var deadline: String? {
            let changesDue = proposal.kind == "change_due"
            let date = changesDue ? proposal.proposed?.dueDate : proposal.dueDate
            let time = changesDue ? proposal.proposed?.dueTime : proposal.dueTime
            return date.map { $0 + " " + (time ?? "23:59") }
        }

        func matches(_ terms: [Substring]) -> Bool {
            guard !terms.isEmpty else { return true }
            let text = [proposal.displayTitle, proposal.presentation.title, proposal.description, proposal.source?.quote,
                        target?.title, project?.title, assignee?.speakerPickerName, meeting?.title]
                .compactMap { $0 }.joined(separator: " ")
            return terms.allSatisfy { text.localizedStandardContains(String($0)) }
        }
    }

    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: WorkspaceModel
    let workspace: Workspace
    @Binding var editing: Proposal?
    @Binding var filters: Filters
    @State private var expanded: Set<Int> = []

    var body: some View {
        let pending = pendingRows
        let shown = filteredRows(pending)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                listControls(pending, count: shown.count)
                .padding(.bottom, 4)
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                        .panelCard()
                }
                if shown.isEmpty {
                    Label(pending.isEmpty ? "Нет предложений на подтверждение" : "Предложения не найдены",
                          systemImage: pending.isEmpty ? "tray" : "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .panelCard()
                }
                ForEach(shown, content: proposalCard)
                decisions
                    .padding(.top, 6)
            }
            .padding(24)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: pending.map(\.id)) { ids in expanded.formIntersection(ids) }
        .sheet(item: $editing) { proposal in
            ProposalEditor(model: model, workspace: workspace, proposal: proposal)
                .sheetCloseButton(disabled: model.saving)
        }
    }

    private var pendingRows: [Row] {
        let tasks = Dictionary(uniqueKeysWithValues: workspace.visibleTasks.map { ($0.id, $0) })
        let projects = Dictionary(uniqueKeysWithValues: workspace.projects.map { ($0.id, $0) })
        let people = Dictionary(uniqueKeysWithValues: workspace.people.map { ($0.id, $0) })
        let meetings = Dictionary(uniqueKeysWithValues: workspace.meetings.map { ($0.id, $0) })
        return workspace.proposals.filter { $0.status == "pending" }.map { proposal in
            let target = proposal.taskId.flatMap { tasks[$0] }
            let projectID = target?.projectId ?? proposal.projectId
            let assigneeID = proposal.kind == "change_assignee"
                ? proposal.proposed?.assigneeId : (proposal.assigneeId ?? target?.assigneeId)
            return Row(proposal: proposal, target: target, project: projectID.flatMap { projects[$0] },
                       assignee: assigneeID.flatMap { people[$0] },
                       meeting: proposal.source?.meetingId.flatMap { meetings[$0] })
        }
    }

    private func filteredRows(_ rows: [Row]) -> [Row] {
        let terms = filters.query.split(whereSeparator: \.isWhitespace)
        return rows.filter { row in
            if let kind = filters.kind, row.proposal.kind != kind { return false }
            switch filters.project {
            case .all: break
            case .none: if row.project != nil { return false }
            case .project(let id): if row.project?.id != id { return false }
            }
            switch filters.assignee {
            case .all: break
            case .none: if row.assignee != nil { return false }
            case .person(let id): if row.assignee?.id != id { return false }
            }
            return row.matches(terms)
        }.sorted { left, right in
            switch filters.sort {
            case .newest: break
            case .oldest: return left.id < right.id
            case .title:
                let comparison = left.proposal.displayTitle.localizedStandardCompare(right.proposal.displayTitle)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            case .deadline:
                if let lhs = left.deadline, let rhs = right.deadline, lhs != rhs { return lhs < rhs }
                if (left.deadline == nil) != (right.deadline == nil) { return left.deadline != nil }
            }
            return left.id > right.id
        }
    }

    private func listControls(_ pending: [Row], count: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Предложения").font(.headline).accessibilityAddTraits(.isHeader)
                Text(count == pending.count ? "\(count)" : "\(count) из \(pending.count)")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Предложений: \(count) из \(pending.count)")
                Spacer()
                if filters.isActive {
                    Button("Сбросить фильтры") { filters.reset() }
                    .buttonStyle(.link)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { searchField; filterMenus(pending) }
                VStack(alignment: .leading, spacing: 8) { searchField; filterMenus(pending) }
            }
        }
        .panelCard()
    }

    private var searchField: some View {
        PanelSearchField(placeholder: "Поиск предложений", query: $filters.query)
    }

    private func filterMenus(_ pending: [Row]) -> some View {
        let kinds = Dictionary(grouping: workspace.proposals, by: \.kind)
        let pendingKinds = Set(pending.map { $0.proposal.kind }).union([filters.kind].compactMap { $0 })
        let projectIDs = Set(pending.compactMap { $0.project?.id })
        let projects = workspace.projects.filter { projectIDs.contains($0.id) || filters.project == .project($0.id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let assigneeIDs = Set(pending.compactMap { $0.assignee?.id })
        let assignees = workspace.people.filter { assigneeIDs.contains($0.id) || filters.assignee == .person($0.id) }
            .sorted { $0.speakerPickerName.localizedStandardCompare($1.speakerPickerName) == .orderedAscending }
        return HStack(spacing: 8) {
            Menu {
                Menu("Тип") {
                    Picker("Тип", selection: $filters.kind) {
                        Text("Все типы").tag(nil as String?)
                        ForEach(pendingKinds.sorted(), id: \.self) { kind in
                            Text(kinds[kind]?.first?.presentation.title ?? "Предложение").tag(Optional(kind))
                        }
                    }
                    .pickerStyle(.inline)
                }
                Menu("Проект") {
                    Picker("Проект", selection: $filters.project) {
                        Text("Все проекты").tag(ProjectFilter.all)
                        Text("Без проекта").tag(ProjectFilter.none)
                        ForEach(projects) { Text($0.title).tag(ProjectFilter.project($0.id)) }
                    }
                    .pickerStyle(.inline)
                }
                Menu("Исполнитель") {
                    Picker("Исполнитель", selection: $filters.assignee) {
                        Text("Все исполнители").tag(AssigneeFilter.all)
                        Text("Без исполнителя").tag(AssigneeFilter.none)
                        ForEach(assignees) { Text($0.speakerPickerName).tag(AssigneeFilter.person($0.id)) }
                    }
                    .pickerStyle(.inline)
                }
            } label: {
                Label("Фильтры", systemImage: filters.isActive
                      ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .accessibilityValue(filters.isActive ? "Фильтры включены" : "Нет активных фильтров")
            Menu {
                Picker("Сортировка", selection: $filters.sort) {
                    ForEach(SortOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Сортировка", systemImage: "arrow.up.arrow.down")
            }
            .accessibilityValue(filters.sort.rawValue)
        }
    }

    private func proposalCard(_ row: Row) -> some View {
        let proposal = row.proposal
        let open = expanded.contains(proposal.id)
        let kind = proposal.presentation
        let subtitle = [proposal.displayTitle == kind.title ? nil : kind.title, row.project?.title]
            .compactMap { $0 }.joined(separator: " · ")
        let palette = PanelPalette(dark: scheme == .dark)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    if open { expanded.remove(proposal.id) }
                    else { expanded.insert(proposal.id) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                            .accessibilityHidden(true)
                        Image(systemName: kind.icon)
                            .foregroundStyle(palette.selectedInk)
                            .frame(width: 34, height: 34)
                            .background(palette.selected, in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(proposal.displayTitle)
                                .font(.headline)
                                .lineLimit(open ? nil : 2)
                            if !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(open ? "Развёрнуто" : "Свёрнуто")
                Button("Проверить") { editing = proposal }
                    .buttonStyle(.bordered)
                    .disabled(model.saving || model.loading)
            }
            if open {
                Divider()
                details(proposal, target: row.target, meeting: row.meeting)
                HStack {
                    Spacer()
                    Button("Отклонить", role: .destructive) {
                        Task { await model.command(["op": "review", "id": proposal.id, "reject": true]) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.saving || model.loading)
                }
            }
        }
        .panelCard()
    }

    @ViewBuilder
    private func details(_ proposal: Proposal, target: TaskItem?, meeting: Meeting?) -> some View {
        if let description = proposal.description, !description.isEmpty {
            Text(description).textSelection(.enabled)
        }
        if let person = workspace.people.first(where: { $0.id == proposal.assigneeId }) {
            LabeledContent("Исполнитель", value: person.name)
        }
        if let date = proposal.dueDate {
            LabeledContent("Срок", value: [date, proposal.dueTime].compactMap { $0 }.joined(separator: " "))
        }
        if let target, let change = proposal.proposed {
            LabeledContent("Задача", value: target.title)
            switch proposal.kind {
            case "change_due":
                LabeledContent("Новый срок", value: change.dueDate.map { [$0, change.dueTime].compactMap { $0 }.joined(separator: " ") } ?? "Без срока")
            case "change_assignee":
                let assignee = workspace.people.first { $0.id == change.assigneeId }
                LabeledContent("Новый исполнитель", value: assignee?.name ?? "Без исполнителя")
            case "change_status":
                LabeledContent("Новый статус", value: stages(for: target.projectId).first { $0.id == change.stageId }?.title ?? "Неизвестный статус")
            default: EmptyView()
            }
        }
        if let quote = proposal.source?.quote, !quote.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                let time = proposal.source?.startMs.map(meetingTime)
                Label([meeting?.title ?? "Фрагмент протокола", time].compactMap { $0 }.joined(separator: " · "),
                      systemImage: "text.quote")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(quote).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var decisions: some View {
        MeetingDisclosure(title: "Подтверждённые решения", icon: "checkmark.seal", count: workspace.decisions.count) {
            if workspace.decisions.isEmpty {
                Text("Подтверждённых решений пока нет.").foregroundStyle(.secondary)
            }
            ForEach(workspace.decisions) { decision in
                Text(decision.text).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func stages(for projectID: Int?) -> [Stage] {
        workspace.projects.first { $0.id == projectID }?.stages ?? workspace.defaultStages
    }

}

struct ProposalEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: WorkspaceModel
    let workspace: Workspace
    let proposal: Proposal
    let fromMeeting: Bool
    @State private var confirmingRejection = false

    @State private var title: String
    @State private var description: String
    @State private var projectID: Int?
    @State private var assigneeID: Int?
    @State private var taskID: Int?
    @State private var dueDate: String
    @State private var dueTime: String
    @State private var stageID: String
    @State private var applyDue = false

    init(model: WorkspaceModel, workspace: Workspace, proposal: Proposal, fromMeeting: Bool = false) {
        self.model = model
        self.workspace = workspace
        self.proposal = proposal
        self.fromMeeting = fromMeeting
        _title = State(initialValue: proposal.title ?? "")
        _description = State(initialValue: proposal.description ?? "")
        _projectID = State(initialValue: proposal.projectId)
        _taskID = State(initialValue: workspace.visibleTasks.first { $0.id == proposal.taskId }?.id)
        _assigneeID = State(initialValue: proposal.kind == "change_assignee" ? proposal.proposed?.assigneeId : proposal.assigneeId)
        _dueDate = State(initialValue: (proposal.kind == "change_due" ? proposal.proposed?.dueDate : proposal.dueDate) ?? "")
        _dueTime = State(initialValue: (proposal.kind == "change_due" ? proposal.proposed?.dueTime : proposal.dueTime) ?? "")
        let stages = workspace.projects.first { $0.id == proposal.projectId }?.stages ?? workspace.defaultStages
        _stageID = State(initialValue: proposal.proposed?.stageId ?? stages.first { $0.kind == "active" }?.id ?? "")
    }

    private var createsTask: Bool { proposal.kind == "create_task" }
    private var isDecision: Bool { proposal.kind == "decision" }
    private var target: TaskItem? { workspace.visibleTasks.first { $0.id == taskID } }
    private var stages: [Stage] {
        let id = target == nil ? projectID : target?.projectId
        return workspace.projects.first { $0.id == id }?.stages ?? workspace.defaultStages
    }
    private var editsStage: Bool { proposal.kind == "change_status" || (createsTask && target == nil) }
    private var editsDue: Bool { proposal.kind == "change_due" || (createsTask && (target == nil || applyDue)) }

    var body: some View {
        let palette = PanelPalette(dark: scheme == .dark)
        VStack(alignment: .leading, spacing: 0) {
            Label(proposal.presentation.title, systemImage: proposal.presentation.icon)
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
        .frame(width: 560, height: 540)
        .disabled(model.saving)
        .interactiveDismissDisabled(model.saving)
        .confirmationDialog("Отклонить предложение?", isPresented: $confirmingRejection) {
            Button("Отклонить", role: .destructive) {
                Task {
                    if await model.command(["op": "review", "id": proposal.id, "reject": true]) {
                        dismiss()
                    }
                }
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    private var fields: some View {
        Form {
            if let quote = proposal.source?.quote, !quote.isEmpty {
                Section("Фрагмент протокола") { Text(quote).textSelection(.enabled) }
            }
            if !isDecision && (!createsTask || proposal.id != 0) {
                Picker("Задача", selection: $taskID) {
                    Text(createsTask ? "Создать новую" : "Выберите задачу").tag(nil as Int?)
                    ForEach(workspace.visibleTasks) { task in
                        let project = workspace.projects.first { $0.id == task.projectId }?.title
                        Text([task.title, project].compactMap { $0 }.joined(separator: " · ")).tag(Optional(task.id))
                    }
                }
                .onChange(of: taskID) { _ in resetStageIfNeeded() }
            }
            if isDecision || (createsTask && target == nil) || proposal.id == 0 {
                TextField(isDecision ? "Решение" : "Название", text: $title, axis: .vertical)
                if createsTask { TextField("Описание", text: $description, axis: .vertical) }
                if isDecision || createsTask {
                    Picker("Проект", selection: $projectID) {
                        Text("Без проекта").tag(nil as Int?)
                        ForEach(workspace.projects) { Text($0.title).tag(Optional($0.id)) }
                    }
                    .onChange(of: projectID) { _ in resetStageIfNeeded() }
                }
            }
            if createsTask && target != nil { Toggle("Изменить срок существующей задачи", isOn: $applyDue) }
            if editsDue {
                TextField("Дата (ГГГГ-ММ-ДД)", text: $dueDate)
                TextField("Время (ЧЧ:ММ)", text: $dueTime).disabled(dueDate.isEmpty)
            }
            if proposal.kind == "change_assignee" || (createsTask && target == nil) {
                Picker("Исполнитель", selection: $assigneeID) {
                    Text("Не назначен").tag(nil as Int?)
                    ForEach(workspace.people) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            if editsStage {
                Picker("Этап", selection: $stageID) {
                    Text("Выберите этап").tag("")
                    ForEach(stages) { Text($0.title).tag($0.id) }
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
                if fromMeeting && proposal.id != 0 {
                    Button("Отклонить", role: .destructive) { confirmingRejection = true }
                }
                Spacer()
                Button(fromMeeting ? "К совещанию" : "Отмена", role: .cancel) { dismiss() }
                Button(proposal.id == 0 ? "Отправить на подтверждение" : "Подтвердить") {
                    Task { if await model.command(payload) { dismiss() } }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm)
            }
            .buttonStyle(.bordered)
        }
    }

    private var canConfirm: Bool {
        if !createsTask && !isDecision && target == nil { return false }
        if (isDecision || (createsTask && target == nil) || proposal.id == 0) && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        return !editsStage || stages.contains { $0.id == stageID }
    }

    private func resetStageIfNeeded() {
        if !stages.contains(where: { $0.id == stageID }) {
            stageID = stages.first { $0.kind == "active" }?.id ?? ""
        }
    }

    private var payload: [String: Any] {
        var data: [String: Any] = [
            "title": title, "description": description, "stage_id": stageID,
            "priority": "normal", "blocked": false,
            "project_id": projectID.map { $0 as Any } ?? NSNull(),
            "assignee_id": assigneeID.map { $0 as Any } ?? NSNull()
        ]
        if editsDue {
            data["due_date"] = dueDate.isEmpty ? NSNull() as Any : dueDate
            data["due_time"] = dueDate.isEmpty || dueTime.isEmpty ? NSNull() as Any : dueTime
        }
        if proposal.id == 0, let source = proposal.source,
           let meetingID = source.meetingId, let start = source.startMs, let quote = source.quote {
            data["kind"] = proposal.kind
            data["task_id"] = taskID
            if let target { data["project_id"] = target.projectId.map { $0 as Any } ?? NSNull() }
            data["proposed"] = ["due_date": data["due_date"] ?? NSNull(), "due_time": data["due_time"] ?? NSNull(),
                                "assignee_id": data["assignee_id"] ?? NSNull(), "stage_id": stageID]
            data["source"] = ["meeting_id": meetingID, "start_ms": start, "quote": quote]
            return ["op": "propose", "data": data]
        }
        var request: [String: Any] = ["op": "review", "id": proposal.id, "data": data]
        if let target {
            request["existing_task_id"] = target.id
            request["task_revision"] = target.revision
            request["apply_due"] = applyDue
        }
        return request
    }
}
