import SwiftUI

struct Proposal: Decodable, Identifiable {
    struct Source: Decodable {
        let quote: String?
        let meetingId: Int?
        let startMs: Int?
        let topic: String?
        var segmentTimesMs: [Int]?
        var materialLinks: [AnalysisMaterialLink]?
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
    var baseTask: Changes?
    var candidateTaskIds: [Int]?
    var candidateBaselines: [CandidateBaseline]?
    var reviewDraft: ReviewDraft?
    var needsClarification: Bool?
    var clarification: String?
    var projectRequired: Bool?
    var decisionTaskIds: [Int]?
    var relatedTaskId: Int?
    var replacesDraftId: Int?
    var supersededByAnalysisId: Int?

    struct ReviewDraft: Decodable {
        struct Fields: Decodable {
            let title: String?
            let description: String?
            let projectId: Int?
            let assigneeId: Int?
            let dueDate: String?
            let dueTime: String?
            let stageId: String?
            let blocked: Bool?
            let blockedReason: String?
            let reason: String?
            let supersedesId: Int?
            let taskIds: [Int]?
            let relatedTaskId: Int?
        }

        let existingTaskId: Int?
        let relatedProposalIds: [Int]?
        let applyDue: Bool?
        let applyAssignee: Bool?
        let confirmSeparateTask: Bool?
        let data: Fields
    }

    struct Changes: Decodable {
        let dueDate: String?
        let dueTime: String?
        let assigneeId: Int?
        let stageId: String?
        let stageTitle: String?
        let blocked: Bool?
        let blockedReason: String?
    }

    struct CandidateBaseline: Decodable {
        let taskId: Int
        let base: Changes
    }

    var presentation: (title: String, icon: String) {
        switch kind {
        case "create_task": return ("Новая задача", "plus.square")
        case "change_task": return ("Изменение задачи", "arrow.left.arrow.right")
        case "change_due": return ("Изменение срока", "calendar")
        case "change_assignee": return ("Смена исполнителя", "person.crop.circle")
        case "change_status": return ("Изменение статуса", "arrow.triangle.2.circlepath")
        case "change_blocked": return ("Блокировка задачи", "exclamationmark.circle")
        case "decision": return ("Решение", "checkmark.seal")
        default: return ("Предложение", "tray")
        }
    }

    var displayTitle: String {
        let text = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? presentation.title : text
    }

    var editsAssignee: Bool { kind == "change_task" || kind == "change_assignee" }
    var editsDeadline: Bool { kind == "change_task" || kind == "change_due" }
    var reviewAssigneeId: Int? {
        if let reviewDraft { return reviewDraft.data.assigneeId }
        return editsAssignee ? proposed?.assigneeId : assigneeId
    }

    var reviewDeadline: (date: String?, time: String?) {
        if let reviewDraft { return (reviewDraft.data.dueDate, reviewDraft.data.dueTime) }
        return editsDeadline ? (proposed?.dueDate, proposed?.dueTime) : (dueDate, dueTime)
    }
}

struct Decision: Decodable, Identifiable {
    let id: Int
    let text: String
    let projectId: Int?
    let meetingId: Int?
    let source: Proposal.Source?
    let status: String?
    let reason: String?
    let taskIds: [Int]?
    let supersedesId: Int?
    let reviewerId: Int?
    let approvedAt: String?

    var active: Bool { status != "superseded" && status != "cancelled" }
    var statusLabel: String {
        switch status {
        case "superseded": return "Заменено"
        case "cancelled": return "Отменено"
        default: return "Утверждено"
        }
    }
}

struct ApprovalsView: View {
    struct ProjectList {
        enum Kind: String, CaseIterable {
            case all = "Все"
            case tasks = "Задачи"
            case decisions = "Решения"
        }

        enum Status: String, CaseIterable {
            case all = "Все"
            case approved = "Согласовано"
            case pending = "На согласовании"
        }

        let project: Project
        let kind: Kind
        let status: Status
        let openTask: (Int) -> Void
        let openMeeting: (Int) -> Void

        func includesDecision(_ isDecision: Bool) -> Bool {
            kind == .all || (kind == .decisions) == isDecision
        }
    }

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
        var meetingId: Int?
        var project = ProjectFilter.all
        var assignee = AssigneeFilter.all
        var sort = SortOrder.newest

        var isActive: Bool { kind != nil || meetingId != nil || project != .all || assignee != .all }

        mutating func reset() {
            kind = nil
            meetingId = nil
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
            let (date, time) = proposal.reviewDeadline
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
    var projectList: ProjectList? = nil
    @State private var expanded: Set<Int> = []
    @State private var prepared: [Int: [String: Any]] = [:]
    @State private var batchResult: String?


    var body: some View {
        let pending = pendingRows
        let shown = filteredRows(pending).filter { row in
            projectList?.status != .approved && (projectList?.includesDecision(row.proposal.kind == "decision") ?? true)
        }
        let search = filters.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let acceptedTasks = projectTasks(matching: search)
        let projectDecisions = projectList.map { list in
            workspace.decisions.filter { $0.projectId == list.project.id }
        } ?? []
        let shownDecisions = projectDecisions.filter { decision in
            guard let projectList, projectList.status != .pending, projectList.includesDecision(true) else { return false }
            return (projectList.status == .all || decision.active) &&
                (search.isEmpty || decision.text.localizedStandardContains(search) ||
                    decision.reason?.localizedStandardContains(search) == true)
        }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if projectList != nil {
                    PanelSearchField(placeholder: "Поиск по задачам и решениям", query: $filters.query)
                } else {
                    listControls(pending, count: shown.count).padding(.bottom, 4)
                }
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                        .panelCard()
                }
                if shown.isEmpty && acceptedTasks.isEmpty && shownDecisions.isEmpty {
                    Label(projectList != nil ? "По выбранным фильтрам ничего нет" :
                            pending.isEmpty ? "Нет предложений на подтверждение" : "Предложения не найдены",
                          systemImage: pending.isEmpty ? "tray" : "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .panelCard()
                }
                if let batchResult { Text(batchResult).foregroundStyle(.secondary) }
                let selected = shown.filter { prepared[$0.id] != nil }
                if !selected.isEmpty {
                    let decisionsInBatch = selected.filter { $0.proposal.kind == "decision" }
                    let canLink = selected.count > 1 && decisionsInBatch.count == 1 &&
                        selected.allSatisfy { $0.meeting?.id == decisionsInBatch[0].meeting?.id &&
                            $0.project?.id == decisionsInBatch[0].project?.id }
                    HStack {
                        Text("К применению: \(selected.count)")
                        Spacer()
                        Button(canLink ? "Утвердить решение и правки" : "Применить выбранные") {
                            let items = selected.compactMap { prepared[$0.id] }
                            Task {
                                if await model.command(["op": "review_batch", "items": items, "associate_decision": canLink]) {
                                    batchResult = "Применено предложений: \(items.count)"
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.saving || selected.count > 100)
                    }
                    .panelCard()
                }
                if let projectList {
                    ForEach(acceptedTasks) { task in
                        acceptedTaskRow(task, open: projectList.openTask)
                    }
                    ForEach(shownDecisions) { decision in
                        ProjectDecisionCard(model: model, workspace: workspace, decision: decision,
                                            prior: projectDecisions.first { $0.id == decision.supersedesId },
                                            openMeeting: projectList.openMeeting, openTask: projectList.openTask)
                    }
                    ForEach(shown, content: proposalCard)
                } else {
                    let groups = Dictionary(grouping: shown) { $0.project?.id }
                    let groupIDs = shown.map { $0.project?.id }.reduce(into: [Int?]()) { ids, id in
                        if !ids.contains(id) { ids.append(id) }
                    }
                    ForEach(groupIDs, id: \.self) { id in
                        if let rows = groups[id] {
                            Text(rows.first?.project?.title ?? "Без проекта")
                                .font(.headline).accessibilityAddTraits(.isHeader)
                                .padding(.top, 8)
                            ForEach(rows, content: proposalCard)
                        }
                    }
                    decisions.padding(.top, 6)
                    archivedDrafts
                }
            }
            .padding(24)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: pending.map(\.id)) { ids in
            expanded.formIntersection(ids)
            prepared = prepared.filter { ids.contains($0.key) }
        }
        .sheet(item: $editing) { proposal in
            ProposalEditor(model: model, workspace: workspace, proposal: proposal, prepare: { payload in
                prepared[proposal.id] = payload
                batchResult = nil
            })
                .sheetCloseButton(disabled: model.saving)
        }
    }

    private func projectTasks(matching search: String) -> [TaskItem] {
        guard let projectList, projectList.project.archived != true,
              projectList.status != .pending, projectList.includesDecision(false) else { return [] }
        return workspace.visibleTasks.filter { task in
            task.projectId == projectList.project.id &&
                (search.isEmpty || task.title.localizedStandardContains(search) ||
                    task.description?.localizedStandardContains(search) == true)
        }
    }

    private func acceptedTaskRow(_ task: TaskItem, open: @escaping (Int) -> Void) -> some View {
        let palette = PanelPalette(dark: scheme == .dark)
        let assignee = workspace.people.first { $0.id == task.assigneeId }?.speakerPickerName
        let due = task.dueDate.map { [ProjectDateField.display($0), task.dueTime].compactMap { $0 }.joined(separator: " ") }
        return Button { open(task.id) } label: {
            HStack(spacing: 10) {
                Image(systemName: "checklist")
                    .foregroundStyle(palette.selectedInk)
                    .frame(width: 34, height: 34)
                    .background(palette.selected, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title).font(.headline)
                        .foregroundStyle(task.overdue ? palette.recordingInk : palette.text)
                    Text(["Задача · Согласовано", task.stageTitle, assignee ?? "Без исполнителя", due ?? "Без срока"]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .panelCard()
    }

    private var pendingRows: [Row] {
        let tasks = Dictionary(uniqueKeysWithValues: workspace.visibleTasks.map { ($0.id, $0) })
        let projects = Dictionary(uniqueKeysWithValues: workspace.projects.map { ($0.id, $0) })
        let people = Dictionary(uniqueKeysWithValues: workspace.people.map { ($0.id, $0) })
        let meetings = Dictionary(uniqueKeysWithValues: workspace.meetings.map { ($0.id, $0) })
        return workspace.proposals.filter { $0.status == "pending" }.compactMap { proposal in
            let target = proposal.taskId.flatMap { tasks[$0] }
            let projectID = target?.projectId ?? proposal.projectId
            if let projectList, projectID != projectList.project.id { return nil }
            let assigneeID = proposal.editsAssignee || proposal.reviewDraft != nil
                ? proposal.reviewAssigneeId : (proposal.assigneeId ?? target?.assigneeId)
            return Row(proposal: proposal, target: target, project: projectID.flatMap { projects[$0] },
                       assignee: assigneeID.flatMap { people[$0] },
                       meeting: proposal.source?.meetingId.flatMap { meetings[$0] })
        }
    }

    private func filteredRows(_ rows: [Row]) -> [Row] {
        let terms = filters.query.split(whereSeparator: \.isWhitespace)
        return rows.filter { row in
            if let kind = filters.kind, row.proposal.kind != kind { return false }
            if let meetingId = filters.meetingId, row.meeting?.id != meetingId { return false }
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
                Text("Предложения")
                    .font(.headline).accessibilityAddTraits(.isHeader)
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
        let meetingIDs = Set(pending.compactMap { $0.meeting?.id })
        let meetings = workspace.meetings.filter { meetingIDs.contains($0.id) || $0.id == filters.meetingId }
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
                Menu("Совещание") {
                    Picker("Совещание", selection: $filters.meetingId) {
                        Text("Все совещания").tag(nil as Int?)
                        ForEach(meetings) { Text($0.title).tag(Optional($0.id)) }
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
        let subtitle = [proposal.displayTitle == kind.title && projectList == nil ? nil : kind.title,
                        projectList == nil ? row.project?.title : "На согласовании"]
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
                if prepared[proposal.id] != nil {
                    Button { prepared.removeValue(forKey: proposal.id) } label: {
                        Label("Убрать из пакета", systemImage: "checkmark.circle.fill")
                            .labelStyle(.iconOnly)
                    }
                    .help("Убрать из пакета")
                    .disabled(model.saving)
                }
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
        if proposal.kind == "create_task" {
            if let person = workspace.people.first(where: { $0.id == proposal.reviewAssigneeId }) {
                LabeledContent("Исполнитель", value: person.name)
            }
            if let date = proposal.reviewDeadline.date {
                LabeledContent("Срок", value: [date, proposal.reviewDeadline.time].compactMap { $0 }.joined(separator: " "))
            }
        }
        if let target, let change = proposal.proposed {
            LabeledContent("Задача", value: target.title)
            switch proposal.kind {
            case "change_task":
                LabeledContent("Срок", value: [change.dueDate, change.dueTime].compactMap { $0 }.joined(separator: " "))
                LabeledContent("Исполнитель", value: workspace.people.first { $0.id == change.assigneeId }?.name ?? "Уточнить")
            case "change_due":
                LabeledContent("Новый срок", value: change.dueDate.map { [$0, change.dueTime].compactMap { $0 }.joined(separator: " ") } ?? "Без срока")
            case "change_assignee":
                let assignee = workspace.people.first { $0.id == change.assigneeId }
                LabeledContent("Новый исполнитель", value: assignee?.name ?? "Без исполнителя")
            case "change_blocked":
                LabeledContent("Блокировка", value: change.blocked == true ? change.blockedReason ?? "Установлена" : "Снять")
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
        MeetingDisclosure(title: "История решений", icon: "checkmark.seal", count: workspace.decisions.count) {
            if workspace.decisions.isEmpty {
                Text("Подтверждённых решений пока нет.").foregroundStyle(.secondary)
            }
            ForEach(workspace.decisions) { decision in
                VStack(alignment: .leading) {
                    Text(decision.text).textSelection(.enabled)
                    Text(decision.statusLabel).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var archivedDrafts: some View {
        let drafts = workspace.proposals.filter { proposal in
            proposal.status == "rejected" && proposal.supersededByAnalysisId != nil && proposal.reviewDraft != nil &&
                (filters.meetingId == nil || filters.meetingId == proposal.source?.meetingId)
        }
        if !drafts.isEmpty {
            MeetingDisclosure(title: "Прежние черновики", icon: "archivebox", count: drafts.count) {
                ForEach(drafts) { proposal in
                    if let fields = proposal.reviewDraft?.data {
                        DisclosureGroup(fields.title ?? proposal.displayTitle) {
                            if let description = fields.description, !description.isEmpty {
                                Text(description).textSelection(.enabled)
                            }
                            if let date = fields.dueDate {
                                LabeledContent("Срок", value: [date, fields.dueTime].compactMap { $0 }.joined(separator: " "))
                            }
                            if let person = workspace.people.first(where: { $0.id == fields.assigneeId }) {
                                LabeledContent("Исполнитель", value: person.name)
                            }
                            if let quote = proposal.source?.quote {
                                Text(quote).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
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
    let prepare: (([String: Any]) -> Void)?
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
    @State private var applyAssignee = false
    @State private var createSeparateTask = false
    @State private var confirmUnassigned = false
    @State private var acknowledgeTaskConflict = false
    @State private var blocked: Bool
    @State private var blockedReason: String
    @State private var showingSource = false
    @State private var selectedSourceTime: Int?
    @State private var relatedIDs: Set<Int> = []
    @State private var decisionReason = ""
    @State private var supersedesDecisionID: Int?
    @State private var decisionTaskIDs: Set<Int> = []
    @State private var decisionTasksExpanded = false
    @State private var relatedTaskID: Int?

    init(model: WorkspaceModel, workspace: Workspace, proposal: Proposal, fromMeeting: Bool = false,
         prepare: (([String: Any]) -> Void)? = nil) {
        self.model = model
        self.workspace = workspace
        self.proposal = proposal
        self.fromMeeting = fromMeeting
        self.prepare = prepare
        _blocked = State(initialValue: proposal.proposed?.blocked ?? true)
        _blockedReason = State(initialValue: proposal.proposed?.blockedReason ?? "")
        _title = State(initialValue: proposal.title ?? "")
        _description = State(initialValue: proposal.description ?? "")
        _projectID = State(initialValue: proposal.projectId)
        _taskID = State(initialValue: workspace.visibleTasks.first { $0.id == proposal.taskId }?.id)
        _assigneeID = State(initialValue: proposal.editsAssignee ? proposal.proposed?.assigneeId : proposal.assigneeId)
        _dueDate = State(initialValue: (proposal.editsDeadline ? proposal.proposed?.dueDate : proposal.dueDate) ?? "")
        _dueTime = State(initialValue: (proposal.editsDeadline ? proposal.proposed?.dueTime : proposal.dueTime) ?? "")
        let stages = workspace.projects.first { $0.id == proposal.projectId }?.stages ?? workspace.defaultStages
        let defaultStage = proposal.kind == "create_task" ? stages.first { $0.kind == "active" }?.id : nil
        _stageID = State(initialValue: proposal.proposed?.stageId ?? defaultStage ?? "")
        _decisionTaskIDs = State(initialValue: Set(proposal.decisionTaskIds ?? []))
        _relatedTaskID = State(initialValue: proposal.relatedTaskId)
        if let draft = proposal.reviewDraft {
            let fields = draft.data
            _title = State(initialValue: fields.title ?? "")
            _description = State(initialValue: fields.description ?? "")
            _projectID = State(initialValue: fields.projectId)
            _taskID = State(initialValue: workspace.visibleTasks.first { $0.id == draft.existingTaskId }?.id)
            _applyDue = State(initialValue: draft.applyDue ?? false)
            _applyAssignee = State(initialValue: draft.applyAssignee ?? false)
            _createSeparateTask = State(initialValue: draft.confirmSeparateTask ?? false)
            _relatedIDs = State(initialValue: Set(draft.relatedProposalIds ?? []))
            _assigneeID = State(initialValue: fields.assigneeId)
            _dueDate = State(initialValue: fields.dueDate ?? "")
            _dueTime = State(initialValue: fields.dueTime ?? "")
            _stageID = State(initialValue: fields.stageId ?? "")
            _blocked = State(initialValue: fields.blocked ?? true)
            _blockedReason = State(initialValue: fields.blockedReason ?? "")
            _decisionReason = State(initialValue: fields.reason ?? "")
            _supersedesDecisionID = State(initialValue: fields.supersedesId)
            _decisionTaskIDs = State(initialValue: Set(fields.taskIds ?? []))
            _relatedTaskID = State(initialValue: fields.relatedTaskId)
        }
    }

    private var createsTask: Bool { proposal.kind == "create_task" }
    private var isDecision: Bool { proposal.kind == "decision" }
    private var bundlesChanges: Bool { proposal.kind == "change_task" }
    private var target: TaskItem? { workspace.visibleTasks.first { $0.id == taskID } }
    private var taskChoices: [TaskItem] {
        let scopedProject = createsTask ? projectID : proposal.projectId
        return workspace.visibleTasks.filter { task in
            if task.id == taskID { return true }
            if bundlesChanges { return task.projectId == scopedProject && task.stageKind == "active" }
            return scopedProject == nil || task.projectId == scopedProject
        }
    }
    private var taskConflict: Bool {
        guard let task = target else { return false }
        let baseline = task.id == proposal.taskId ? proposal.baseTask
            : proposal.candidateBaselines?.first(where: { $0.taskId == task.id })?.base
        guard let base = baseline else { return false }
        let deadlineChanged = base.dueDate != task.dueDate || base.dueTime != task.dueTime
        switch proposal.kind {
        case "change_task": return deadlineChanged || base.assigneeId != task.assigneeId
        case "change_due": return deadlineChanged
        case "change_assignee": return base.assigneeId != task.assigneeId
        case "change_status": return base.stageId != task.stageId
        case "change_blocked": return base.blocked != task.blocked || base.blockedReason != task.blockedReason
        default: return false
        }
    }
    private var stages: [Stage] {
        let id = target == nil ? projectID : target?.projectId
        return workspace.projects.first { $0.id == id }?.stages ?? workspace.defaultStages
    }
    private var editsStage: Bool { proposal.kind == "change_status" || (createsTask && target == nil) }
    private var editsDue: Bool { proposal.editsDeadline || (createsTask && (target == nil || applyDue)) }

    private var matchingTasks: [TaskItem] {
        if let candidates = proposal.candidateTaskIds, !candidates.isEmpty {
            let selected = candidates.compactMap { id in
                taskChoices.first { $0.id == id && (!createsTask || $0.projectId == projectID) }
            }
            if !selected.isEmpty { return selected }
        }
        let name = normalizedTitle(createsTask ? title : proposal.title ?? "")
        guard !name.isEmpty else { return [] }
        let matches = taskChoices.filter {
            normalizedTitle($0.title) == name
        }
        let meetingProject = workspace.meetings.first { $0.id == proposal.source?.meetingId }?.projectId
        if let explicit = createsTask ? projectID : proposal.projectId {
            return matches.filter { $0.projectId == explicit }
        }
        guard let meetingProject else { return matches }
        return matches.filter { $0.projectId == meetingProject } +
            matches.filter { $0.projectId != meetingProject }
    }

    private func normalizedTitle(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "ё", with: "е")
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }

    private var relatedItems: [Proposal] {
        guard createsTask, proposal.id != 0, target == nil, let meeting = proposal.source?.meetingId else { return [] }
        return workspace.proposals.filter { item in
            item.id != proposal.id && item.source?.meetingId == meeting && item.projectId == projectID &&
                ((item.kind == "decision" && item.status == "accepted") ||
                 (item.status == "pending" && item.taskId == nil &&
                    ["create_task", "change_due", "change_assignee"].contains(item.kind)))
        }
    }

    private func suggestedAssignee(_ item: Proposal) -> Int? {
        if let id = item.proposed?.assigneeId ?? item.assigneeId { return id }
        guard item.kind == "decision" else { return nil }
        let words = normalizedTitle(item.title ?? "").split(separator: " ").map(String.init)
        guard let verb = words.first, ["назначить", "назначили", "назначаем"].contains(verb) else { return nil }
        let names = workspace.people.filter { person in
            let name = normalizedTitle(person.name)
            guard !name.isEmpty, !name.contains(" ") else { return false }
            return words.dropFirst().contains { word in
                word == name || word == name + "а" || word == name + "я"
                    || (name.hasSuffix("а") && word == name.dropLast() + "у")
                    || (name.hasSuffix("я") && word == name.dropLast() + "ю")
            }
        }
        return names.count == 1 ? names.first?.id : nil
    }

    private func includeRelated(_ item: Proposal) {
        relatedIDs.insert(item.id)
        if let date = item.proposed?.dueDate ?? item.dueDate {
            dueDate = date
            dueTime = item.proposed?.dueTime ?? item.dueTime ?? ""
        }
        if let id = suggestedAssignee(item) { assigneeID = id }
    }

    @ViewBuilder
    private var relatedSection: some View {
        let items = relatedItems
        if !items.isEmpty {
            Section("Объединить с поручением") {
                Menu("Добавить связанный пункт") {
                    ForEach(items.filter { !relatedIDs.contains($0.id) }) { item in
                        Button(item.displayTitle) { includeRelated(item) }
                    }
                }
                .disabled(items.allSatisfy { relatedIDs.contains($0.id) })
                ForEach(items.filter { relatedIDs.contains($0.id) }) { item in
                    HStack {
                        Text(item.displayTitle)
                        Spacer()
                        Button("Убрать источник") { relatedIDs.remove(item.id) }
                            .buttonStyle(.link)
                    }
                }
                if !relatedIDs.isEmpty {
                    Text("Проверьте итоговый срок и исполнителя. Подтверждение создаст одну задачу со всеми выбранными источниками.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func taskLabel(_ task: TaskItem) -> String {
        let project = workspace.projects.first { $0.id == task.projectId }?.title ?? "Без проекта"
        return "\(task.title) · \(project) · #\(task.id)"
    }

    private func deadline(_ date: String?, time: String?) -> String {
        guard let date, !date.isEmpty else { return "Без срока" }
        return [date, time].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func assigneeName(_ id: Int?) -> String {
        workspace.people.first { $0.id == id }?.speakerPickerName ?? "Не назначен"
    }

    @ViewBuilder
    private var decisionTaskPicker: some View {
        let tasks = workspace.visibleTasks.filter { $0.projectId == projectID }
        let selectedCount = tasks.filter { decisionTaskIDs.contains($0.id) }.count
        Button {
            decisionTasksExpanded.toggle()
        } label: {
            HStack {
                Text("Связанные задачи")
                Spacer()
                Text("Выбрано: \(selectedCount)")
                    .foregroundStyle(.secondary)
                Image(systemName: decisionTasksExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(decisionTasksExpanded ? "Развёрнуто" : "Свёрнуто")

        if decisionTasksExpanded {
            Text(tasks.isEmpty ? "В проекте пока нет задач." : "Отметьте задачи, которые относятся к решению.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(tasks) { task in
                Toggle(task.title, isOn: Binding(get: { decisionTaskIDs.contains(task.id) }, set: { selected in
                    if selected { decisionTaskIDs.insert(task.id) } else { decisionTaskIDs.remove(task.id) }
                }))
            }
        }
    }

    @ViewBuilder
    private func changePreview(_ task: TaskItem) -> some View {
        Section("Изменения в задаче") {
            if bundlesChanges {
                LabeledContent("Задача", value: "#\(task.id) · \(task.title)")
            }
            if editsDue {
                LabeledContent("Текущий срок", value: deadline(task.dueDate, time: task.dueTime))
                LabeledContent("Предлагаемый срок", value: deadline(dueDate, time: dueTime))
            }
            if proposal.editsAssignee || applyAssignee {
                LabeledContent("Текущий исполнитель", value: assigneeName(task.assigneeId))
                LabeledContent("Предлагаемый исполнитель", value: assigneeName(assigneeID))
            } else if proposal.kind == "change_status" {
                LabeledContent("Текущий статус", value: task.stageTitle)
                LabeledContent("Предлагаемый статус", value: stages.first { $0.id == stageID }?.title ?? "Выберите этап")
            } else if proposal.kind == "change_blocked" {
                LabeledContent("Текущая блокировка", value: task.blocked == true ? task.blockedReason ?? "Установлена" : "Нет")
                LabeledContent("Предлагаемая блокировка", value: blocked ? blockedReason : "Нет")
            } else if createsTask && !editsDue {
                Text("Фрагмент протокола будет добавлен к существующей задаче.")
                    .foregroundStyle(.secondary)
            }
        }
    }

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
        .sheet(isPresented: $showingSource) {
            if let meeting = workspace.meetings.first(where: { $0.id == proposal.source?.meetingId }),
               let start = selectedSourceTime ?? proposal.source?.startMs {
                ProposalTranscriptSource(model: model, meeting: meeting, start: start)
                    .sheetCloseButton()
            }
        }
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
            if proposal.replacesDraftId != nil {
                Text("Повторный анализ предложил другие значения. Прежний черновик сохранён в истории.")
                    .foregroundStyle(.secondary)
            }
            if proposal.needsClarification == true,
               let clarification = proposal.clarification, !clarification.isEmpty {
                Section("Нужно уточнение") {
                    Label(clarification, systemImage: "questionmark.bubble")
                }
            }
            if let materials = proposal.source?.materialLinks, !materials.isEmpty {
                Section("Материалы проекта") {
                    ForEach(materials) { item in
                        if let target = item.target { Link(item.label, destination: target) }
                    }
                }
            }
            if let quote = proposal.source?.quote, !quote.isEmpty {
                Section("Фрагмент протокола") {
                    if let meeting = workspace.meetings.first(where: { $0.id == proposal.source?.meetingId }) {
                        Label([meeting.title, proposal.source?.startMs.map(meetingTime)].compactMap { $0 }.joined(separator: " · "),
                              systemImage: "video")
                            .foregroundStyle(.secondary)
                        let times = proposal.source?.segmentTimesMs ?? [proposal.source?.startMs].compactMap { $0 }
                        ForEach(Array(Set(times)).sorted(), id: \.self) { start in
                            Button("Открыть реплику · \(meetingTime(start))") {
                                selectedSourceTime = start
                                showingSource = true
                            }
                            .buttonStyle(.link)
                        }
                    }
                    Text(quote).textSelection(.enabled)
                }
            }
            if !isDecision && (!createsTask || proposal.id != 0) {
                let matches = matchingTasks
                if target == nil, !matches.isEmpty {
                    Section(matches.count == 1 ? "Найдена похожая задача" : "Уточните, о какой задаче речь") {
                        ForEach(matches) { task in
                            Button(taskLabel(task)) { taskID = task.id }
                                .buttonStyle(.link)
                        }
                        if createsTask {
                            Toggle("Создать отдельную задачу", isOn: $createSeparateTask)
                        }
                    }
                }
                Picker("Задача", selection: $taskID) {
                    Text(createsTask ? "Создать новую" : "Выберите задачу").tag(nil as Int?)
                    ForEach(taskChoices) { task in
                        Text(taskLabel(task)).tag(Optional(task.id))
                    }
                }
                .onChange(of: taskID) { _ in
                    createSeparateTask = false
                    acknowledgeTaskConflict = false
                    applyDue = false
                    applyAssignee = false
                    relatedIDs.removeAll()
                    resetStageIfNeeded()
                }
            }
            if isDecision || (createsTask && target == nil) || proposal.id == 0 {
                TextField(isDecision ? "Решение" : "Название", text: $title, axis: .vertical)
                    .onChange(of: title) { _ in createSeparateTask = false }
                if createsTask { TextField("Описание", text: $description, axis: .vertical) }
                if isDecision || createsTask {
                    Picker("Проект", selection: $projectID) {
                        Text("Без проекта").tag(nil as Int?)
                        ForEach(workspace.projects) { Text($0.title).tag(Optional($0.id)) }
                    }
                    .onChange(of: projectID) { _ in
                        createSeparateTask = false
                        relatedIDs.removeAll()
                        supersedesDecisionID = nil
                        decisionTaskIDs.removeAll()
                        relatedTaskID = nil
                        resetStageIfNeeded()
                    }
                }
            }
            if isDecision {
                Section("Контекст решения") {
                    TextField("Обоснование", text: $decisionReason, axis: .vertical)
                    if projectID != nil {
                        Picker("Заменяет решение", selection: $supersedesDecisionID) {
                            Text("Не выбрано").tag(nil as Int?)
                            ForEach(workspace.decisions.filter { $0.projectId == projectID && $0.active }) { decision in
                                Text(decision.text).tag(Optional(decision.id))
                            }
                        }
                        decisionTaskPicker
                    }
                }
            }
            relatedSection
            if createsTask && target == nil && projectID != nil {
                Picker("Связать с задачей", selection: $relatedTaskID) {
                    Text("Без связи").tag(nil as Int?)
                    ForEach(workspace.visibleTasks.filter { $0.projectId == projectID }) { candidate in
                        Text(candidate.title).tag(Optional(candidate.id))
                    }
                }
            }
            if createsTask && target != nil {
                Toggle("Изменить срок существующей задачи", isOn: $applyDue)
                Toggle("Назначить исполнителя существующей задачи", isOn: $applyAssignee)
            }
            if editsDue {
                TextField("Дата (ГГГГ-ММ-ДД)", text: $dueDate)
                TextField("Время (ЧЧ:ММ)", text: $dueTime).disabled(dueDate.isEmpty)
            }
            if proposal.editsAssignee, let description = proposal.description, !description.isEmpty {
                Text(description).foregroundStyle(.secondary)
            }
            if proposal.editsAssignee || (createsTask && target == nil) || applyAssignee {
                Picker("Исполнитель", selection: $assigneeID) {
                    Text("Не назначен").tag(nil as Int?)
                    ForEach(workspace.people) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            if proposal.kind == "change_assignee", assigneeID == nil {
                Toggle("Оставить задачу без исполнителя", isOn: $confirmUnassigned)
            }
            if editsStage {
                if let stageTitle = proposal.proposed?.stageTitle {
                    LabeledContent("Статус из протокола", value: stageTitle)
                }
                Picker("Этап", selection: $stageID) {
                    Text("Выберите этап").tag("")
                    ForEach(stages) { Text($0.title).tag($0.id) }
                }
            }
            if proposal.kind == "change_blocked" {
                Toggle("Задача заблокирована", isOn: $blocked)
                if blocked { TextField("Причина блокировки", text: $blockedReason, axis: .vertical) }
            }
            if let target { changePreview(target) }
            if taskConflict {
                Section("Задача изменилась после анализа") {
                    Toggle("Проверил текущие значения и подтверждаю замену", isOn: $acknowledgeTaskConflict)
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
                if proposal.id != 0 {
                    Button(prepare == nil ? "Сохранить черновик" : "В пакет") {
                        let draft = payload
                        Task {
                            if await model.command(["op": "save_review_draft", "id": proposal.id, "draft": draft]) {
                                if canConfirm { prepare?(draft) }
                                dismiss()
                            }
                        }
                    }
                    .disabled(prepare != nil && !canConfirm)
                }
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
        if proposal.projectRequired == true && (isDecision || (createsTask && target == nil)) && projectID == nil { return false }
        if taskConflict && !acknowledgeTaskConflict { return false }
        if applyAssignee && assigneeID == nil { return false }
        if bundlesChanges && (assigneeID == nil || dueDate.isEmpty) { return false }
        if proposal.kind == "change_assignee" && assigneeID == nil && !confirmUnassigned { return false }
        if proposal.kind == "change_blocked" && blocked && blockedReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if createsTask && proposal.id != 0 && target == nil && !createSeparateTask && !matchingTasks.isEmpty { return false }
        if (isDecision || (createsTask && target == nil)) && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        return !editsStage || stages.contains { $0.id == stageID }
    }

    private func resetStageIfNeeded() {
        if !stages.contains(where: { $0.id == stageID }) {
            stageID = createsTask ? stages.first { $0.kind == "active" }?.id ?? "" : ""
        }
    }

    private var payload: [String: Any] {
        var data: [String: Any] = [
            "title": title, "description": description, "stage_id": stageID,
            "priority": "normal", "blocked": false,
            "project_id": projectID.map { $0 as Any } ?? NSNull(),
            "assignee_id": assigneeID.map { $0 as Any } ?? NSNull()
        ]
        if proposal.kind == "change_blocked" {
            data["blocked"] = blocked
            data["blocked_reason"] = blocked ? blockedReason : ""
        }
        if isDecision {
            data["reason"] = decisionReason
            data["supersedes_id"] = supersedesDecisionID
            data["task_ids"] = decisionTaskIDs.sorted()
        }
        if createsTask && target == nil {
            data["related_task_id"] = relatedTaskID.map { $0 as Any } ?? NSNull()
        }
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
                                "assignee_id": data["assignee_id"] ?? NSNull(), "stage_id": stageID,
                                "blocked": data["blocked"] ?? NSNull(), "blocked_reason": data["blocked_reason"] ?? NSNull()]
            data["source"] = ["meeting_id": meetingID, "start_ms": start, "quote": quote]
            return ["op": "propose", "data": data]
        }
        var request: [String: Any] = ["op": "review", "id": proposal.id, "data": data]
        if createsTask && target == nil && createSeparateTask {
            request["confirm_separate_task"] = true
        }
        if createsTask && target == nil && !relatedIDs.isEmpty {
            request["related_proposal_ids"] = relatedIDs.sorted()
        }
        if let target {
            request["existing_task_id"] = target.id
            request["task_revision"] = target.revision
            request["apply_due"] = applyDue
            if applyAssignee { request["apply_assignee"] = true }
            if taskConflict { request["acknowledge_task_conflict"] = acknowledgeTaskConflict }
        }
        return request
    }
}

private struct ProposalTranscriptSource: View {
    @ObservedObject var model: WorkspaceModel
    let meeting: Meeting
    let start: Int
    @State private var segment: Transcript.Segment?
    @State private var message: String?

    var body: some View {
        Group {
            if let segment {
                MeetingAudioPreview(model: model, meetingID: meeting.id, segment: segment)
            } else if let message {
                Text(message).padding(20)
            } else {
                ProgressView().padding(20)
            }
        }
        .frame(minWidth: 420)
        .task {
            do {
                let transcript = try await model.transcript(for: meeting)
                segment = transcript?.segments.first { $0.startMs <= start && start < $0.endMs }
                if segment == nil { message = "В текущей версии протокола нет реплики с этим временем." }
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
