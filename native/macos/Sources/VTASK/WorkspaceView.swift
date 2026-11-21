import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceView: View {
    enum Selection: Hashable {
        case processing
        case projectList
        case dashboard
        case settings
        case tasks
        case meetings
        case people
        case glossary
        case project(Int)
    }

    @StateObject private var model = WorkspaceModel(launchesLocalCore: true)
    @State private var selection: Selection = .dashboard
    @State private var history: [NavigationEntry] = []
    @Environment(\.colorScheme) private var colorScheme
    @State private var navigationVisible = true
    @State private var assistantVisible = false
    @State private var showingIndustrySetup = false
    @State private var offeredIndustrySetup = false
    @State private var valliButtonHovered = false
    @State private var taskDraftID: Int?
    @State private var assistantLive: LiveTranscript?
    @State private var liveAssistantRequests: [String] = []
    @State private var archivedProjects = false
    @State private var projectDirectoryFilters = ProjectDirectory.Filters()
    @State private var personDirectoryFilters = PersonDirectory.Filters()
    @State private var meetingQuery = ""
    @State private var meetingProjectFilter: Int?
    @State private var meetingPersonFilter: Int?
    private var companyGlossary: CompanyGlossary {
        CompanyGlossary(model.workspace?.glossaryTerms ?? model.workspace?.companyTerms ?? [])
    }

    private var meetingTopics: MeetingTopics {
        MeetingTopics(industry: model.workspace?.settings.industryTemplate ?? .decor)
    }

    private var palette: PanelPalette {
        PanelPalette(dark: (model.workspace?.settings.colorScheme ?? colorScheme) == .dark)
    }

    @State private var editingMeeting: Meeting?
    @State private var importingAudio = false
    @State private var importMeetingID: Int?
    @State private var meetingTab: MeetingTab = .protocolText
    @State private var projectSections = ProjectSections()

    private enum MeetingTab: String, CaseIterable {
        case protocolText = "Протокол"
        case audio = "Аудио"
    }

    private enum TaskTab: String, CaseIterable {
        case items = "Задачи и решения"
        case board = "Доска"
    }

    private enum ProjectTab: String, CaseIterable {
        case overview = "Обзор"
        case items = "Задачи и решения"
        case meetings = "Совещания"
    }

    private struct ProjectSections {
        var tab: ProjectTab = .overview
        var kind: ApprovalsView.ItemList.Kind = .all
        var status: ApprovalsView.ItemList.Status = .all
        var filters = ApprovalsView.Filters()
    }

    private struct NavigationEntry {
        let section: Selection
        let itemID: Int?
        let approval: ApprovalsView.InspectedItem?
        let meetingTab: MeetingTab
        let projectSections: ProjectSections
        let taskFilters: TaskFilterSnapshot
    }

    private struct TaskFilterSnapshot {
        let savedView: SavedTaskView?
        let tab: TaskTab
        let kind: ApprovalsView.ItemList.Kind
        let approvals: ApprovalsView.ItemList.Status
        let query: String
        let status: TaskFilter
        let project: Int?
        let assignee: Int?
        let unassigned: Bool
    }

    private enum MeetingFollowUp: Identifiable {
        case task(Int)
        case proposal(Proposal)

        var id: String {
            switch self {
            case .task(let id): return "task-\(id)"
            case .proposal(let proposal): return "proposal-\(proposal.id)"
            }
        }
    }

    @State private var meetingFollowUp: MeetingFollowUp?

    @State private var selectedItemID: Int?
    @State private var inspectedApproval: ApprovalsView.InspectedItem?
    @State private var approvalAfterDiscard: ApprovalsView.InspectedItem?
    @State private var approvalFilters = ApprovalsView.Filters()
    @State private var recoveringRecording = false
    @State private var editingProject: Project?
    @State private var projectArchiveRequest: Project?
    @State private var creation: Creation?
    @State private var savedView: SavedTaskView?
    @AppStorage("workItems.groupByTopic") private var groupByTopic = false
    @State private var taskTab: TaskTab = .items
    @State private var taskKind: ApprovalsView.ItemList.Kind = .all
    @State private var taskApprovalStatus: ApprovalsView.ItemList.Status = .all
    @State private var savingView = false
    @State private var viewName = ""
    @State private var deletingView: SavedTaskView?
    @State private var query = ""
    @State private var taskStatus: TaskFilter = .all
    @State private var projectFilter: Int?
    @State private var assigneeFilter: Int?
    @State private var unassignedOnly = false
    @State private var newTitle = ""
    @State private var newMeetingDate = Date()
    @State private var usesCustomMeetingDate = false
    @State private var newParticipants: Set<Int> = []
    @State private var newParticipantName = ""
    @State private var newMeetingPerson: Person?

    @State private var creationProjectID: Int?
    @State private var creationNewProjectName: String?
    @State private var creationNeedsProject = false
    @State private var newProjectOwnerID: Int?
    @State private var unresolvedProjectOwner: String?
    @State private var newProjectDescription = ""
    @State private var newProjectStart = ""
    @State private var newProjectEnd = ""
    @State private var newTaskAssigneeID: Int?
    @State private var unresolvedTaskAssignee: String?
    @State private var newTaskDescription = ""
    @State private var newTaskDueDate = ""
    @State private var newTaskDueTime = ""
    @State private var newTaskPriority = "normal"

    private func addMeetingParticipant() async {
        let name = newParticipantName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard let id = await model.createEntity(["op": "add_person", "name": name]) else { return }
        newParticipants.insert(id)
        newParticipantName = ""
        newMeetingPerson = model.workspace?.people.first { $0.id == id }
    }

    private var meetingTimeZone: TimeZone {
        model.workspace.flatMap { TimeZone(identifier: $0.settings.timezone) } ?? .current
    }

    private func create(_ kind: Creation) async {
        guard !model.saving && !model.loading else { return }
        let enteredTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = kind == .meeting && enteredTitle.isEmpty ? "Совещание" : enteredTitle
        if let name = creationNewProjectName {
            let projectPayload: [String: Any] = ["op": "save_project", "data": ["title": name, "status": "planned"]]
            guard let id = await model.createEntity(projectPayload) else { return }
            creationProjectID = id
            creationNewProjectName = nil
        }
        let selectedProject = projects.first { $0.id == creationProjectID }
        guard creationProjectID == nil || selectedProject != nil else { return }
        let projectID: Any = selectedProject.map { $0.id as Any } ?? NSNull()
        let payload: [String: Any]
        switch kind {
        case .project:
            payload = ["op": "save_project", "data": [
                "title": title, "status": "planned",
                "description": newProjectDescription.trimmingCharacters(in: .whitespacesAndNewlines),
                "owner_id": newProjectOwnerID.map { $0 as Any } ?? NSNull(),
                "start_date": newProjectStart.isEmpty ? NSNull() as Any : newProjectStart,
                "end_date": newProjectEnd.isEmpty ? NSNull() as Any : newProjectEnd
            ]]
        case .person:
            payload = ["op": "add_person", "name": title]
        case .decision:
            guard let selectedProject else { return }
            payload = ["op": "save_project_decision", "project_id": selectedProject.id, "text": title]
        case .meeting:
            payload = ["op": "save_meeting", "data": [
                "title": title, "project_id": projectID, "participants": newParticipants.sorted(),
                "scheduled_at": ISO8601DateFormatter().string(from: usesCustomMeetingDate ? newMeetingDate : .now)
            ]]
        case .task:
            let stages = selectedProject?.stages ?? model.workspace?.defaultStages ?? []
            guard let stage = stages.first(where: { $0.kind == "active" }) else { return }
            payload = ["op": "save_task", "data": [
                "title": title, "project_id": projectID, "stage_id": stage.id,
                "priority": newTaskPriority, "blocked": false, "description": newTaskDescription,
                "assignee_id": newTaskAssigneeID.map { $0 as Any } ?? NSNull(),
                "due_date": newTaskDueDate.isEmpty ? NSNull() as Any : newTaskDueDate,
                "due_time": newTaskDueTime.isEmpty || newTaskDueDate.isEmpty ? NSNull() as Any : newTaskDueTime
            ]]
        }
        if kind == .meeting {
            guard let id = await model.createEntity(payload) else { return }
            creation = nil
            assistantVisible = false
            openMeeting(id)
        } else if kind == .person {
            guard let id = await model.createEntity(payload) else { return }
            creation = nil
            navigate(.people, itemID: id)
        } else if await model.command(payload) {
            creation = nil
        }
    }

    @ViewBuilder
    private func recoveryControls(for meeting: Meeting) -> some View {
        if model.capture?.active != nil {
            Text("Запись идёт в другом совещании").foregroundStyle(.secondary)
        } else if model.capture != nil && ["recording", "failed"].contains(meeting.status) {
            Button("Восстановить запись") { recoveringRecording = true }
                .confirmationDialog("Предыдущий процесс записи остановлен?", isPresented: $recoveringRecording) {
                    Button("Подтвердить и восстановить") {
                        Task {
                            await model.command(["meeting_id": meeting.id, "confirmed_stopped": true], path: "api/recover")
                        }
                    }
                }
        }
    }

    private var sectionTitle: String {
        switch selection {
        case .processing: return "Обработка"
        case .projectList: return "Проекты"
        case .dashboard: return "Сегодня"
        case .settings: return "Настройки"
        case .meetings: return "Совещания"
        case .people: return "Участники"
        case .glossary: return "Справочник"
        default: return project?.title ?? "Задачи и решения"
        }
    }

    private var projects: [Project] {
        model.workspace?.projects.filter { $0.archived != true } ?? []
    }

    private var project: Project? {
        guard case let .project(id) = selection else { return nil }
        return model.workspace?.projects.first { $0.id == id }
    }

    private var visibleTasks: [TaskItem] {
        model.workspace?.visibleTasks ?? []
    }

    private var tasks: [TaskItem] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let savedView, let workspace = model.workspace {
            return savedView.apply(to: visibleTasks, in: workspace, project: project?.id)
        }
        return visibleTasks.filter { task in
            if let projectID = project?.id ?? projectFilter, task.projectId != projectID { return false }
            if unassignedOnly && task.assigneeId != nil { return false }
            if let assigneeFilter, task.assigneeId != assigneeFilter { return false }
            if !taskStatus.matches(task, today: model.workspace?.today ?? "") { return false }
            return text.isEmpty || task.title.localizedCaseInsensitiveContains(text)
                || task.description?.localizedCaseInsensitiveContains(text) == true
        }
    }

    private func navigate(_ destination: Selection, itemID: Int? = nil) {
        guard selection != destination || selectedItemID != itemID else {
            inspectedApproval = nil
            return
        }
        history.append(NavigationEntry(section: selection, itemID: selectedItemID,
                                       approval: inspectedApproval, meetingTab: meetingTab,
                                       projectSections: projectSections,
                                       taskFilters: TaskFilterSnapshot(savedView: savedView, tab: taskTab, kind: taskKind,
                                                                      approvals: taskApprovalStatus, query: query,
                                                                      status: taskStatus, project: projectFilter,
                                                                      assignee: assigneeFilter, unassigned: unassignedOnly)))
        if case .project = destination, selection != destination {
            projectSections = ProjectSections()
        }
        inspectedApproval = nil
        show(destination, itemID: itemID)
    }

    private func show(_ destination: Selection, itemID: Int?, tab: MeetingTab = .protocolText) {
        selectedItemID = itemID
        selection = destination
        meetingTab = tab
    }

    private func goBack() {
        if inspectedApproval != nil {
            inspectedApproval = nil
            return
        }
        guard let previous = history.popLast() else { return }
        let filters = previous.taskFilters
        savedView = filters.savedView
        taskTab = filters.tab
        taskKind = filters.kind
        taskApprovalStatus = filters.approvals
        query = filters.query
        taskStatus = filters.status
        projectFilter = filters.project
        assigneeFilter = filters.assignee
        unassignedOnly = filters.unassigned
        projectSections = previous.projectSections
        show(previous.section, itemID: previous.itemID, tab: previous.meetingTab)
        inspectedApproval = previous.approval
    }

    private var inspectedItemSelection: Binding<Int?> {
        Binding(get: { selectedItemID }, set: { id in
            if let id {
                navigate(selection, itemID: id)
            } else {
                closeInspector()
            }
        })
    }

    private func closeInspector() {
        guard selectedItemID != nil else { return }
        if let list = history.lastIndex(where: { $0.section == selection && $0.itemID == nil }),
           history[list...].allSatisfy({ $0.section == selection }) {
            history.removeSubrange(list...)
        }
        selectedItemID = nil
    }

    private var approvalSelection: Binding<ApprovalsView.InspectedItem?> {
        Binding(get: { inspectedApproval }, set: { item in
            if let item {
                if taskDraftID != nil && taskDraftID == selectedItemID {
                    approvalAfterDiscard = item
                    return
                }
                closeInspector()
            }
            inspectedApproval = item
        })
    }

    private func openApprovals() {
        navigate(.tasks)
        taskTab = .items
        taskKind = .all
        taskApprovalStatus = .pending
        approvalFilters = ApprovalsView.Filters()
    }

    private func openMeeting(_ id: Int) {
        navigate(.meetings, itemID: id)
    }

    private func openTask(_ id: Int) {
        if let project, visibleTasks.contains(where: { $0.id == id && $0.projectId == project.id }) {
            navigate(.project(project.id), itemID: id)
            projectSections.tab = .items
            return
        }
        navigate(.tasks, itemID: id)
        savedView = nil
        query = ""
        projectFilter = nil
        assigneeFilter = nil
        unassignedOnly = false
        taskStatus = visibleTasks.first { $0.id == id }?.stageKind == "cancelled" ? .cancelled : .all
    }

    private func showProjectCard(_ project: Project) {
        if self.project?.id != project.id { navigate(.project(project.id)) }
        editingProject = project
    }

    private func taskFilters(includesSearch: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let savedView {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { savedTaskFilter(savedView); Spacer(minLength: 8); taskViewMenu }
                    VStack(alignment: .leading, spacing: 8) { savedTaskFilter(savedView); taskViewMenu }
                }
            } else {
                if includesSearch {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { taskSearch; taskFilterMenus }
                        VStack(alignment: .leading, spacing: 8) { taskSearch; taskFilterMenus }
                    }
                } else {
                    taskFilterMenus
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { taskShortcuts }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) { taskShortcut(.all, icon: "tray"); myTaskShortcut }
                        HStack(spacing: 6) { taskShortcut(.today, icon: "calendar"); taskShortcut(.overdue, icon: "exclamationmark.clock") }
                    }
                }
                if let name = taskFilterSummary {
                    HStack(spacing: 8) {
                        Label(name, systemImage: "line.3.horizontal.decrease")
                            .foregroundStyle(palette.muted)
                        Button("Сбросить") { resetTaskFilters() }.buttonStyle(.link)
                    }
                    .font(.caption)
                }
            }
        }
        .panelCard()
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var taskSearch: some View {
        PanelSearchField(placeholder: "Поиск задач", query: $query)
    }

    private var taskFilterMenus: some View {
        HStack(spacing: 8) {
            Menu {
                Menu("Статус и срок") {
                    Picker("Статус и срок", selection: $taskStatus) {
                        ForEach(TaskFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
                    }
                    .pickerStyle(.inline)
                }
                if project == nil {
                    Menu("Проект") {
                        Picker("Проект", selection: $projectFilter) {
                            Text("Все проекты").tag(nil as Int?)
                            ForEach(projects) { project in Text(project.title).tag(Optional(project.id)) }
                        }
                        .pickerStyle(.inline)
                    }
                }
                Menu("Исполнитель") {
                    Picker("Исполнитель", selection: Binding(
                        get: { unassignedOnly ? -1 : assigneeFilter },
                        set: {
                            unassignedOnly = $0 == -1
                            assigneeFilter = unassignedOnly ? nil : $0
                        }
                    )) {
                        Text("Все исполнители").tag(nil as Int?)
                        Text("Без исполнителя").tag(Optional(-1))
                        ForEach(model.workspace?.people ?? []) { person in Text(person.name).tag(Optional(person.id)) }
                    }
                    .pickerStyle(.inline)
                }
            } label: {
                Label("Фильтры", systemImage: taskFilterSummary == nil
                      ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            taskViewMenu
        }
    }

    private var taskViewMenu: some View {
        Menu {
            let views = model.workspace?.settings.savedViews ?? []
            ForEach(views) { view in
                Button {
                    closeInspector()
                    savedView = view
                    taskTab = view.view == "board" ? .board : .items
                    taskKind = .tasks
                    taskApprovalStatus = .approved
                    approvalFilters.query = ""
                } label: {
                    Label(view.name, systemImage: savedView?.id == view.id ? "checkmark" : "bookmark")
                }
            }
            if !views.isEmpty { Divider() }
            if let savedView {
                Button("Удалить выборку", role: .destructive) { deletingView = savedView }
            } else {
                Button("Сохранить выборку") {
                    viewName = ""
                    savingView = true
                }
            }
        } label: {
            Label("Выборки", systemImage: "bookmark")
        }
        .accessibilityLabel("Сохранённые выборки")
        .disabled(model.workspace == nil || model.loading || model.saving)
    }

    private func savedTaskFilter(_ view: SavedTaskView) -> some View {
        HStack(spacing: 8) {
            Label(view.name, systemImage: "bookmark.fill")
                .font(.callout.weight(.medium))
            Button("Сбросить") { savedView = nil }.buttonStyle(.link)
        }
    }

    @ViewBuilder
    private var taskShortcuts: some View {
        taskShortcut(.all, icon: "tray")
        myTaskShortcut
        taskShortcut(.today, icon: "calendar")
        taskShortcut(.overdue, icon: "exclamationmark.clock")
    }

    private var myTaskShortcut: some View {
        let me = model.workspace?.settings.meId
        return taskShortcutButton("Мои", icon: "person.crop.circle", selected: me != nil && assigneeFilter == me && taskStatus == .active) {
            assigneeFilter = me
            unassignedOnly = false
            taskStatus = .active
        }
        .disabled(me == nil)
    }

    private func taskShortcut(_ filter: TaskFilter, icon: String) -> some View {
        taskShortcutButton(filter.rawValue, icon: icon,
                           selected: taskStatus == filter && (filter != .all || taskFilterSummary == nil)) {
            if filter == .all { resetTaskFilters() }
            else { taskStatus = filter }
        }
    }

    private func taskShortcutButton(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.medium))
                .foregroundStyle(selected ? palette.selectedInk : palette.muted)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(selected ? palette.selected : palette.sidebar, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var taskFilterSummary: String? {
        let person = model.workspace?.people.first { $0.id == assigneeFilter }
        let filteredProject = project == nil ? projects.first { $0.id == projectFilter } : nil
        let parts = [taskStatus == .all ? nil : taskStatus.rawValue,
                     unassignedOnly ? "Без исполнителя" : person?.speakerPickerName, filteredProject?.title]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func resetTaskFilters() {
        taskStatus = .all
        assigneeFilter = nil
        unassignedOnly = false
        projectFilter = nil
    }

    private var sidebar: some View {
        return VStack(alignment: .leading, spacing: 0) {
            Button { navigate(.dashboard) } label: {
                let logoName = palette.dark ? "vtask-dark" : "vtask-light"
                if let url = Bundle.main.url(forResource: logoName, withExtension: "svg"),
                   let logo = NSImage(contentsOf: url) {
                    Image(nsImage: logo)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 156)
                } else {
                    Text("VTASK").font(.system(size: 28, weight: .bold))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("VTASK — обзор")
            .padding(.horizontal, 18)
            .padding(.vertical, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    nav("Сегодня", icon: "calendar", destination: .dashboard)
                    nav("Проекты", icon: "square.3.layers.3d", destination: .projectList)
                    nav("Совещания", icon: "video", destination: .meetings)
                    nav("Задачи и решения", icon: "checkmark.square", destination: .tasks, count: visibleTasks.filter { $0.stageKind == "active" }.count)
                    nav("Участники", icon: "person.2", destination: .people)
                    nav("Справочник", icon: "book", destination: .glossary)
                    nav("Обработка", icon: "waveform", destination: .processing)
                }
                .padding(.horizontal, 10)
            }
            Divider()
            nav("Настройки", icon: "gearshape", destination: .settings)
                .padding(10)
            Text("Данные на этом компьютере")
                .font(.caption).foregroundStyle(palette.muted)
                .padding(.horizontal, 20).padding(.bottom, 16)
        }
        .frame(width: 224)
        .background(palette.sidebar)
    }

    private func nav(_ title: String, icon: String, destination: Selection, count: Int = 0) -> some View {
        let active = selection == destination || (destination == .projectList && project != nil)
        return Button { navigate(destination) } label: {
            HStack {
                Image(systemName: icon).font(.system(size: 19)).frame(width: 24)
                Text(title).font(.system(size: 15, weight: active ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
                if count > 0 { Text(count, format: .number).font(.caption.monospacedDigit()) }
            }
            .padding(.horizontal, 13)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .foregroundStyle(active ? palette.selectedInk : palette.text)
            .background(active ? palette.selected : Color.clear, in: RoundedRectangle(cornerRadius: 11))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    @ViewBuilder
    private var workspaceLayout: some View {
        if selection == .dashboard {
                if let workspace = model.workspace {
                    Dashboard(
                        tasks: visibleTasks, projects: projects, people: workspace.people,
                        today: workspace.today, openTask: openTask,
                        showTasks: { filter in
                            navigate(.tasks)
                            taskTab = .items
                            taskKind = .tasks
                            taskApprovalStatus = .approved
                            approvalFilters.query = ""
                            savedView = nil
                            query = ""
                            projectFilter = nil
                            assigneeFilter = nil
                            unassignedOnly = false
                            taskStatus = filter
                        },
                        showAssignee: { assignee in
                            navigate(.tasks)
                            taskTab = .items
                            taskKind = .tasks
                            taskApprovalStatus = .approved
                            approvalFilters.query = ""
                            savedView = nil
                            query = ""
                            projectFilter = nil
                            assigneeFilter = assignee
                            unassignedOnly = assignee == nil
                            taskStatus = .active
                        },
                        myID: workspace.settings.meId,
                        openProjects: { navigate(.projectList) },
                        openMeetings: { navigate(.meetings) },
                        meetings: workspace.meetings,
                        pending: workspace.proposals.filter { $0.status == "pending" },
                        notifications: (workspace.notifications ?? []).filter { item in
                            workspace.visibleTasks.contains { $0.id == item.taskId }
                        },
                        openNotification: { item in
                            Task {
                                if item.readAt == nil {
                                    guard await model.command(["op":"read_task_notification","id":item.id]) else { return }
                                }
                                openTask(item.taskId)
                            }
                        },
                        openProject: { navigate(.project($0)) },
                        openMeeting: openMeeting,
                        openApprovals: openApprovals
                    )

                } else if let error = model.error {
                    VStack {
                        Text(error)
                        Button("Повторить") { Task { await model.reload() } }
                    }
                } else {
                    ProgressView()
                }
        } else {
            detailLayout
        }
    }

    private var detailLayout: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if let error = model.error {
                    Text(error).foregroundStyle(.secondary).padding()
                }
                if selection == .tasks {
                    Picker("Раздел задач", selection: $taskTab) {
                        ForEach(TaskTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 470)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    if taskTab == .items {
                        itemFilters(kind: $taskKind, status: $taskApprovalStatus)
                        if taskApprovalStatus != .pending && taskKind != .decisions {
                            taskFilters(includesSearch: false)
                        }
                    } else { taskFilters() }
                }
                if let project {
                    HStack {
                        Button { navigate(.projectList) } label: { Label("Все проекты", systemImage: "arrow.left") }
                            .buttonStyle(.link)
                        Spacer()
                        Menu {
                            Button("Новое совещание") { beginCreation(.meeting) }
                            Button("Новая задача") { beginCreation(.task) }
                            Button("Новое решение") { beginCreation(.decision) }
                        } label: {
                            Image(systemName: "plus").accessibilityLabel("Добавить в проект")
                        }
                        .menuIndicator(.hidden)
                        .help("Добавить в проект")
                        .disabled(project.archived == true || model.saving)
                    }
                    .padding(.horizontal, 24).padding(.top, 12)
                    Picker("Раздел проекта", selection: $projectSections.tab) {
                        ForEach(ProjectTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 470)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                }
                if model.loading && model.workspace == nil {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if selection == .processing {
                    List(model.workspace?.meetings.filter { $0.processing != nil || !$0.recordings.isEmpty } ?? []) { meeting in
                        Section(meeting.visibleTitle) { ProcessingControls(model: model, meeting: meeting) }
                    }
                } else if selection == .projectList, let workspace = model.workspace {
                    ProjectDirectory(workspace: workspace, archived: $archivedProjects, filters: $projectDirectoryFilters,
                                     openProject: { navigate(.project($0)) }, openTask: openTask,
                                     editProject: showProjectCard, changeArchive: { projectArchiveRequest = $0 },
                                     actionsDisabled: model.saving || model.loading)
                } else if selection == .settings, let workspace = model.workspace {
                    ScrollView {
                        EngineSettingsForm(model: model)
                        SettingsForm(model: model, settings: workspace.settings, people: workspace.people)
                        AssistantVoiceSettingsForm(canPreview: model.capture?.active == nil)
                        VoiceMatchingSettingsForm(model: model)
                    }
                } else if selection == .meetings {
                    if let meeting = selectedMeeting {
                        meetingPage(meeting)
                    } else {
                        meetingDirectory
                    }
                } else if selection == .people {
                    PersonDirectory(model: model, selection: inspectedItemSelection, filters: $personDirectoryFilters)
                } else if selection == .glossary, let workspace = model.workspace {
                    CompanyGlossaryView(model: model, entries: workspace.companyTerms ?? [],
                                        industry: workspace.settings.industryTemplate ?? .decor,
                                        starterTerms: workspace.industryTerms ?? [],
                                        meetings: workspace.meetings, openMeeting: openMeeting)
                } else if let project, let workspace = model.workspace {
                    projectContent(project, workspace: workspace)
                        .id(project.id)
                } else if selection == .tasks && taskTab == .items, let workspace = model.workspace {
                    ApprovalsView(model: model, workspace: workspace, inspectedItem: approvalSelection,
                                  filters: $approvalFilters, itemList: .init(
                                    project: nil, kind: taskKind, status: taskApprovalStatus,
                                    openTask: { navigate(.tasks, itemID: $0) }, openMeeting: openMeeting,
                                    acceptedTasks: tasks, taskGrouping: savedView?.group
                                  ), groupByTopic: groupByTopic)
                } else {
                    taskWorkspace
                        .id(selection)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if selectedItemID != nil && (selection == .people ||
                                        selection == .tasks ||
                                        (project != nil && (projectSections.tab == .items || taskDraftID == selectedItemID))) {
                Divider()
                VStack(spacing: 0) {
                    HStack {
                        WindowCloseButton(label: "Закрыть карточку", action: closeInspector)
                        Text(selection == .people ? "Участник" : "Карточка задачи").font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        if let task = inspectedTask {
                            Text("#\(task.id)").font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .accessibilityLabel("Номер задачи \(task.id)")
                        }
                    }
                    .padding(10)
                    Divider()
                    inspector
                }
                .frame(minWidth: 290, idealWidth: 350, maxWidth: 410)
                .background(palette.surface)
            }
        }
        .alert(item: $approvalAfterDiscard) { item in
            Alert(title: Text("В задаче есть несохранённые изменения"),
                  primaryButton: .destructive(Text("Не сохранять")) {
                      closeInspector()
                      inspectedApproval = item
                  },
                  secondaryButton: .cancel(Text("Остаться в задаче")))
        }
        .onChange(of: taskTab) { tab in
            if tab != .items { inspectedApproval = nil }
        }
        .onChange(of: projectSections.tab) { tab in
            if tab != .items && project != nil { inspectedApproval = nil }
        }
    }

    private var taskWorkspace: some View {
        TaskWorkspace(model: model, tasks: tasks, projects: projects,
                      people: model.workspace?.people ?? [], selection: inspectedItemSelection)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
    }

    @ViewBuilder
    private func projectContent(_ project: Project, workspace: Workspace) -> some View {
        switch projectSections.tab {
        case .overview:
            ProjectOverview(project: project, workspace: workspace, openTask: openTask, openTasks: {
                projectSections.tab = .items
                projectSections.kind = .tasks
                projectSections.status = .approved
                projectSections.filters.query = ""
            }, openBoard: {
                navigate(.tasks)
                resetTaskFilters()
                projectFilter = project.id
                taskTab = .board
            }, editProject: {
                showProjectCard(project)
            }, editingDisabled: model.saving || model.loading)
        case .items:
            itemFilters(kind: $projectSections.kind, status: $projectSections.status)
            ApprovalsView(model: model, workspace: workspace, inspectedItem: approvalSelection,
                          filters: $projectSections.filters, itemList: .init(
                            project: project, kind: projectSections.kind, status: projectSections.status,
                            openTask: { navigate(.project(project.id), itemID: $0) }, openMeeting: openMeeting
                          ), groupByTopic: groupByTopic)
        case .meetings:
            projectMeetings(project, workspace: workspace)
        }
    }

    private func projectMeetings(_ project: Project, workspace: Workspace) -> some View {
        let meetings = workspace.meetings.filter { $0.projectId == project.id }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if project.archived != true {
                    HStack {
                        Spacer()
                        Button { beginCreation(.meeting) } label: {
                            Label("Новое совещание", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.saving)
                    }
                    .padding(.bottom, 12)
                }
                if meetings.isEmpty {
                    Text("В этом проекте пока нет совещаний.")
                        .foregroundStyle(palette.muted)
                } else {
                    ForEach(meetings) { meeting in
                        Divider()
                        meetingRow(meeting, showsProject: false)
                    }
                    Divider()
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func itemFilters(kind: Binding<ApprovalsView.ItemList.Kind>,
                             status: Binding<ApprovalsView.ItemList.Status>) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                itemKindPicker(kind)
                itemStatusPicker(status)
                groupingButton
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    itemKindPicker(kind)
                    groupingButton
                }
                itemStatusPicker(status)
            }
        }
        .padding(.horizontal, 24)
    }

    private var groupingButton: some View {
        Button {
            groupByTopic.toggle()
        } label: {
            Label("По разделам", systemImage: groupByTopic ? "folder.fill" : "folder")
                .foregroundStyle(groupByTopic ? palette.accent : palette.text)
                .fixedSize()
        }
        .buttonStyle(.bordered)
        .help("Группировка по разделам")
        .accessibilityLabel("Группировка по разделам")
        .accessibilityValue(groupByTopic ? "Включена" : "Выключена")
        .accessibilityAddTraits(groupByTopic ? .isSelected : [])
    }

    private func itemKindPicker(_ kind: Binding<ApprovalsView.ItemList.Kind>) -> some View {
        Picker("Тип записи", selection: kind) {
            ForEach(ApprovalsView.ItemList.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
    }

    private func itemStatusPicker(_ status: Binding<ApprovalsView.ItemList.Status>) -> some View {
        Picker("Статус согласования", selection: status) {
            ForEach(ApprovalsView.ItemList.Status.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
    }

    private func reviewMeetingProposal(_ proposal: Proposal) {
        meetingFollowUp = .proposal(proposal)
    }

    private func meetingTasks(_ meeting: Meeting) -> some View {
        let glossary = companyGlossary
        let tasks = visibleTasks.filter {
            $0.stageKind != "cancelled" && $0.sources?.contains { $0.meetingId == meeting.id } == true
        }
        let proposals = model.workspace?.proposals.filter {
            $0.kind != "decision" && $0.status == "pending" && $0.source?.meetingId == meeting.id
        } ?? []

        return MeetingDisclosure(title: "Задачи", icon: "checklist", count: tasks.count + proposals.count) {
            if tasks.isEmpty && proposals.isEmpty {
                Text("Задач пока нет.").foregroundStyle(.secondary)
            }
            MeetingTopicList(rows: MeetingTopicEntry.rows(tasks, proposals: proposals), topic: { row in
                switch row {
                case .confirmed(let task):
                    let sources = task.sources?.filter { $0.meetingId == meeting.id } ?? []
                    return meetingTopics.taskTitle(task, sources: sources, glossary: glossary)
                case .proposed(let proposal):
                    return MeetingTopicEntry<TaskItem>.proposalTopic(proposal, topics: meetingTopics, glossary: glossary)
                }
            }) { row in
                switch row {
                case .confirmed(let task):
                    Button { meetingFollowUp = .task(task.id) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: task.stageKind == "done" ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(task.title).font(.callout.weight(.medium))
                                let person = model.workspace?.people.first { $0.id == task.assigneeId }
                                Text([task.stageTitle, person?.name, task.dueDate].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                case .proposed(let proposal):
                    MeetingProposalRow(proposal: proposal, icon: "checkmark.circle", review: reviewMeetingProposal)
                }
            }
        }
    }

    private var meetingDirectory: some View {
        let query = meetingQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let meetings = (model.workspace?.meetings ?? []).filter { meeting in
            (query.isEmpty || meeting.visibleTitle.localizedCaseInsensitiveContains(query)
                || meeting.protocolTitle?.localizedCaseInsensitiveContains(query) == true)
            && (meetingProjectFilter == nil || meeting.projectId == meetingProjectFilter)
            && (meetingPersonFilter.map(meeting.participants.contains) ?? true)
        }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Найти встречу", text: $meetingQuery).textFieldStyle(.roundedBorder)
                    HStack {
                        Picker("Проект", selection: $meetingProjectFilter) {
                            Text("Все проекты").tag(nil as Int?)
                            ForEach(projects) { Text($0.title).tag(Optional($0.id)) }
                        }
                        Picker("Участник", selection: $meetingPersonFilter) {
                            Text("Все участники").tag(nil as Int?)
                            ForEach(model.workspace?.people ?? []) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                }
                .padding(.bottom, 16)
                if meetings.isEmpty { Text("Встречи не найдены").foregroundStyle(palette.muted) }
                ForEach(meetings) { meeting in
                    Divider()
                    meetingRow(meeting, showsProject: true)
                }
                Divider()
            }
            .padding(24)
        }
    }

    private func meetingRow(_ meeting: Meeting, showsProject: Bool) -> some View {
        Button { openMeeting(meeting.id) } label: {
            HStack(spacing: 14) {
                Image(systemName: "video").foregroundStyle(palette.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text(meeting.visibleTitle).font(.headline)
                    if showsProject {
                        Text(meeting.projectName ?? "Без проекта")
                            .foregroundStyle(palette.muted)
                    }
                    if let schedule = meeting.meetingDateLabel(in: meetingTimeZone) {
                        Label(schedule, systemImage: "calendar").font(.caption).foregroundStyle(palette.muted)
                    }
                }
                Spacer()
                if let job = meeting.processing {
                    Text(job.label).font(.caption).foregroundStyle(palette.muted)
                } else if !meeting.recordings.isEmpty {
                    Text("Аудио сохранено").font(.caption).foregroundStyle(palette.muted)
                }
                Image(systemName: "chevron.right").foregroundStyle(palette.muted)
            }
            .padding(.vertical, 14).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func meetingPage(_ meeting: Meeting) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button { navigate(.meetings) } label: { Label("История встреч", systemImage: "list.bullet") }
                    .buttonStyle(.bordered)
                meetingMain(meeting)
            }
            .frame(maxWidth: 1120)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $meetingFollowUp) { item in
            switch item {
            case .task(let id):
                if let task = model.workspace?.tasks.first(where: { $0.id == id }) {
                    TaskEditor(model: model, task: task, openMeeting: { source in
                        meetingFollowUp = nil
                        openMeeting(source)
                    }, openRelatedTask: { related in
                        meetingFollowUp = .task(related)
                    }, draftChanged: { dirty in
                        taskDraftID = dirty ? id : nil
                    }, returnToMeeting: {
                        meetingFollowUp = nil
                    })
                    .id([task.id, task.revision])
                    .frame(minWidth: 530, idealWidth: 580, minHeight: 540, idealHeight: 640)
                } else {
                    Text("Задача недоступна.")
                        .padding()
                        .sheetCloseButton()
                }
            case .proposal(let proposal):
                Group {
                    if let workspace = model.workspace {
                        ProposalEditor(model: model, workspace: workspace, proposal: proposal, fromMeeting: true)
                    }
                }
                .sheetCloseButton(disabled: model.saving)
            }
        }
    }

    private func meetingMain(_ meeting: Meeting) -> some View {
        let participants = model.workspace?.people.filter { meeting.participants.contains($0.id) } ?? []
        let active = model.capture?.active
        let session = active?.meetingId == meeting.id ? active : nil
        return VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 14) {
                MeetingOrbit(title: meeting.visibleTitle,
                             projectName: meeting.projectName ?? "Без проекта",
                             participants: participants, photoURL: model.personPhotoURL,
                             session: session, hint: model.capture?.liveDisplay == true ? model.capture?.hint : nil) {
                    orbitControls(meeting, session: session)
                }
                if let level = session?.level {
                    ProgressView("Микрофон", value: min(1, max(0, level * 2.5))).frame(maxWidth: 240)
                }
                if session == nil && (active != nil || ["recording", "failed"].contains(meeting.status)) {
                    recoveryControls(for: meeting)
                }
            }
            .disabled(model.saving)
            .panelCard()
            VStack(alignment: .leading, spacing: 10) {
                if let job = meeting.processing {
                    ProcessingStatusView(job: job)
                }
                ProcessingControls(model: model, meeting: meeting, showsStatus: false, showsCancel: true)
            }
            .panelCard()
            Picker("Раздел встречи", selection: $meetingTab) {
                ForEach(MeetingTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            switch meetingTab {
            case .protocolText:
                VStack(alignment: .leading, spacing: 12) {
                    Text(meeting.protocolTitle ?? meeting.visibleTitle)
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    LabeledContent("Проект", value: meeting.projectName ?? "Без проекта")
                    LabeledContent("Дата совещания", value: meeting.meetingDateLabel(in: meetingTimeZone) ?? "Не указана")
                }
                .panelCard()
                MeetingAnalysisView(model: model, meeting: meeting, openMeeting: openMeeting, openTask: openTask).id(meeting.id)
                MeetingOpenQuestions(meeting: meeting).id(meeting.id)
                meetingTasks(meeting).id(meeting.id)
                MeetingDecisions(
                    decisions: model.workspace?.decisions.filter { $0.meetingId == meeting.id } ?? [],
                    proposals: model.workspace?.proposals.filter {
                        $0.kind == "decision" && $0.status == "pending" && $0.source?.meetingId == meeting.id
                    } ?? [],
                    review: reviewMeetingProposal
                ).id(meeting.id)
                if model.capture?.liveDisplay == true && liveMeetingID != meeting.id {
                    LiveTranscriptView(model: model, meetingID: meeting.id).id(meeting.id)
                }
                MeetingTranscript(model: model, meeting: meeting).id(meeting.id)
            case .audio:
                Form {
                    Section("Аудио") {
                        Button {
                            importMeetingID = meeting.id
                            importingAudio = true
                        } label: {
                            Label("Импортировать аудио", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.saving || model.loading || active != nil)
                        ForEach(meeting.recordings, id: \.id) { RecordingPlayer(url: model.recordingURL($0)) }
                    }
                }
                .formStyle(.columns)
                .panelCard()
            }
        }
    }

    @ViewBuilder
    private func orbitControls(_ meeting: Meeting, session: CaptureStatus.Session?) -> some View {
        if session.map({ ["recording", "paused"].contains($0.state) }) == true
            || (model.capture != nil && model.capture?.active == nil && !["recording", "failed"].contains(meeting.status)) {
            HStack(spacing: 10) {
                if let session, ["recording", "paused"].contains(session.state) {
                    if session.canPause {
                        let paused = session.state == "paused"
                        orbitButton(paused ? "Продолжить" : "Пауза", icon: paused ? "play.fill" : "pause.fill", primary: paused) {
                            await model.record(paused ? "resume" : "pause", meeting: meeting)
                        }
                    }
                    orbitButton("Завершить запись", icon: "stop.fill", stop: true) {
                        await model.record("stop", meeting: meeting)
                    }
                } else if model.capture != nil && model.capture?.active == nil && !["recording", "failed"].contains(meeting.status) {
                    let fresh = meeting.recordings.isEmpty
                    orbitButton(fresh ? "Начать запись" : "Продолжить запись",
                                icon: fresh ? "record.circle" : "play.fill", primary: true) {
                        await model.record(fresh ? "start" : "continue", meeting: meeting)
                    }
                }
            }
            .padding(6)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(.purple.opacity(0.22)) }
            .shadow(color: .purple.opacity(0.16), radius: 10, y: 4)
        }
    }

    private func orbitButton(_ title: String, icon: String, stop: Bool = false, primary: Bool = false,
                             action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Image(systemName: icon)
        }
        .buttonStyle(RecordingControlStyle(stop: stop, primary: primary))
        .help(title)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var inspector: some View {
            if selection == .dashboard || selection == .settings || selection == .processing {
                Color.clear
            } else if selection == .people {
                if let person = model.workspace?.people.first(where: { $0.id == selectedItemID }) {
                    Form {
                        PersonDetailsEditor(model: model, person: person)
                        VoiceProfileView(model: model, person: person)
                        Section("Совещания") {
                            ForEach(model.workspace?.meetings.filter { $0.participants.contains(person.id) } ?? []) { meeting in
                                Button(meeting.visibleTitle) { openMeeting(meeting.id) }
                                    .buttonStyle(.link)
                            }
                        }
                    }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                    .background(palette.background)
                    .id(person.id)
                    .navigationTitle(person.name)
                } else {
                    Text("Выберите участника").foregroundStyle(.secondary)
                }
            } else if let task = inspectedTask {
                TaskEditor(model: model, task: task, openMeeting: openMeeting, openRelatedTask: openTask, draftChanged: { dirty in
                    if dirty { taskDraftID = task.id }
                    else if taskDraftID == task.id { taskDraftID = nil }
                }).id([task.id, task.revision])
                .navigationTitle(task.title)
            } else {
                Text("Выберите задачу").foregroundStyle(.secondary)
            }
    }

    private var inspectedTask: TaskItem? {
        if let project, project.archived != true {
            return visibleTasks.first { $0.id == selectedItemID && $0.projectId == project.id }
        }
        guard selection == .tasks else { return nil }
        return (taskTab == .items ? visibleTasks : tasks).first { $0.id == selectedItemID }
    }

    private var selectedMeeting: Meeting? {
        guard selection == .meetings else { return nil }
        return model.workspace?.meetings.first { $0.id == selectedItemID }
    }

    private func beginCreation(_ kind: Creation) {
        newTitle = ""
        newMeetingDate = Date()
        usesCustomMeetingDate = false
        newParticipants = []
        newParticipantName = ""
        creationProjectID = project.flatMap { $0.archived == true ? nil : $0.id }
        creationNewProjectName = nil
        creationNeedsProject = kind == .decision
        newProjectOwnerID = nil
        unresolvedProjectOwner = nil
        newProjectDescription = ""
        newProjectStart = ""
        newProjectEnd = ""
        newTaskAssigneeID = nil
        unresolvedTaskAssignee = nil
        newTaskDescription = ""
        newTaskDueDate = ""
        newTaskDueTime = ""
        newTaskPriority = "normal"
        creation = kind
    }

    private var topbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { pageHeading; Spacer(minLength: 8); headerActions }
            VStack(alignment: .leading, spacing: 12) { pageHeading; headerActions }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(palette.background)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.border).frame(height: 1) }
    }

    private var pageHeading: some View {
        HStack(spacing: 12) {
            Button { navigationVisible.toggle() } label: {
                Image(systemName: "line.3.horizontal").font(.system(size: 20)).frame(width: 38, height: 38)
            }
            .accessibilityLabel(navigationVisible ? "Скрыть навигацию" : "Показать навигацию")
            NavigationBackButton(action: goBack)
                .disabled((history.isEmpty && inspectedApproval == nil) || model.saving)
            if let meeting = selectedMeeting {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Совещания").font(.headline).foregroundStyle(palette.text)
                    if let schedule = meeting.scheduleLabel(in: meetingTimeZone) {
                        Label(schedule, systemImage: "calendar").font(.caption).foregroundStyle(palette.muted)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("VTASK · мой компьютер").font(.caption).foregroundStyle(palette.muted)
                    Text(sectionTitle)
                        .font(.system(size: 32, weight: .bold)).tracking(-0.8)
                        .foregroundStyle(palette.text).lineLimit(1).accessibilityAddTraits(.isHeader)
                }
            }
        }
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            if let meeting = selectedMeeting {
                Button { editingMeeting = meeting } label: { Label("Участники", systemImage: "person.2") }
                    .buttonStyle(.bordered)
                    .disabled(model.saving || model.capture?.active?.meetingId == meeting.id)
            } else if let project {
                Button("Карточка проекта") { showProjectCard(project) }.disabled(model.saving)
                Button {
                    projectArchiveRequest = project
                } label: {
                    let archived = project.archived == true
                    Image(systemName: archived ? "arrow.uturn.backward" : "archivebox")
                        .accessibilityLabel(archived ? "Восстановить проект" : "Перенести проект в архив")
                        .help(archived ? "Восстановить проект" : "Перенести проект в архив")
                }
                .disabled(model.saving || model.loading)
            }
            Menu {
                ForEach(Creation.allCases.filter { $0 != .decision }) { kind in
                    Button(kind.rawValue) { beginCreation(kind) }
                        .disabled(model.workspace == nil || (project?.archived == true && (kind == .task || kind == .meeting)))
                }
                Divider()
                Button("Обновить") { Task { await model.reload() } }
                    .keyboardShortcut("r", modifiers: .command)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .accessibilityLabel("Добавить")
            }
            .menuIndicator(.hidden)
            .help("Добавить")
            Menu {
                ForEach([("system", "Как в системе"), ("light", "Светлая"), ("dark", "Тёмная")], id: \.0) { theme in
                    Button {
                        Task { await model.command(["op": "settings", "data": ["theme": theme.0]]) }
                    } label: {
                        if model.workspace?.settings.theme == theme.0 { Label(theme.1, systemImage: "checkmark") }
                        else { Text(theme.1) }
                    }
                }
            } label: {
                Label(["light": "Светлая", "dark": "Тёмная"][model.workspace?.settings.theme ?? ""] ?? "Как в системе",
                      systemImage: "circle.lefthalf.filled").accessibilityLabel("Тема интерфейса")
            }
            .disabled(model.workspace == nil || model.saving)
            Button { assistantVisible.toggle() } label: {
                HStack(spacing: 7) {
                    ValliAvatar(state: valliTakingNotes ? .takingNotes : .idle, size: 32,
                                highlighted: valliButtonHovered && !assistantVisible)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Валли")
                        if valliTakingNotes && !assistantVisible {
                            Text(ValliState.takingNotes.title).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .buttonStyle(.bordered)
            .onHover { valliButtonHovered = $0 }
            .accessibilityLabel("Валли")
            .accessibilityValue(valliTakingNotes ? ValliState.takingNotes.title : "")
        }
        .controlSize(.large)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var recordingBanner: some View {
        if let capture = model.capture?.active,
           let meeting = model.workspace?.meetings.first(where: { $0.id == capture.meetingId }) {
            HStack(spacing: 12) {
                Circle().fill(capture.state == "paused" ? Color.orange : Color.red).frame(width: 8, height: 8)
                Text(capture.state == "paused" ? "Пауза" : "Запись").fontWeight(.semibold)
                    .foregroundStyle(palette.recordingInk)
                Button(meeting.visibleTitle) { openMeeting(meeting.id) }.buttonStyle(.link)
                Text(meetingTime(capture.elapsedMs ?? 0)).monospacedDigit()
                if let level = capture.level {
                    ProgressView(value: min(1, max(0, level * 2.5))).frame(maxWidth: 75)
                        .accessibilityLabel("Уровень микрофона")
                }
                if let saved = capture.savedMs {
                    Text("Сохранено до " + meetingTime(saved)).font(.caption).foregroundStyle(palette.muted)
                        .lineLimit(1)
                }
                Spacer()
                if capture.canPause && ["recording", "paused"].contains(capture.state) {
                    Button(capture.state == "paused" ? "Продолжить" : "Пауза") {
                        Task { await model.record(capture.state == "paused" ? "resume" : "pause", meeting: meeting) }
                    }
                }
                if ["recording", "paused"].contains(capture.state) {
                    Button("Завершить запись") { Task { await model.record("stop", meeting: meeting) } }
                }
            }
            .disabled(model.saving)
            .padding(.horizontal, 24).padding(.vertical, 8)
            .background(palette.recordingSurface)
            .overlay(alignment: .bottom) { Rectangle().fill(palette.border).frame(height: 1) }
        }
    }

    private var valliTakingNotes: Bool {
        if model.capture?.liveDisplay == true && model.capture?.active?.state == "recording" { return true }
        guard let meeting = selectedMeeting else { return false }
        return meeting.analysis?.running == true ||
            meeting.processing?.status == "pending" || meeting.processing?.running == true
    }

    private var liveMeetingID: Int? {
        guard model.capture?.liveDisplay == true,
              let session = model.capture?.active, let sessionID = session.sessionId,
              assistantLive?.sessionId == sessionID else { return nil }
        return session.meetingId
    }

    private var livePreviewContext: String? {
        guard model.capture?.liveDisplay == true else { return nil }
        return model.capture?.active?.sessionId ?? selectedMeeting.map { "meeting-\($0.id)" }
    }

    private let assistantWidth: CGFloat = 355

    private func pollAssistantLive(_ session: CaptureStatus.Session) async {
        var commands = LiveAssistantCommands()
        guard let sessionID = session.sessionId else { return }
        while !Task.isCancelled {
            if let snapshot = try? await model.liveTranscript(for: session.meetingId),
               !Task.isCancelled, snapshot.sessionId == sessionID {
                let startedLive = assistantLive?.sessionId != sessionID
                assistantLive = snapshot
                if startedLive { assistantVisible = true }
                let requests = commands.read(snapshot.chunks)
                if !requests.isEmpty {
                    liveAssistantRequests.append(contentsOf: requests)
                    assistantVisible = true
                }
            }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
        }
    }

    @ViewBuilder
    private var assistantDrawer: some View {
        if let workspace = model.workspace {
            ZStack(alignment: .trailing) {
                if liveMeetingID == nil {
                    Color.black.opacity(0.16).contentShape(Rectangle()).onTapGesture { assistantVisible = false }
                }
                VStack(alignment: .leading, spacing: 0) {
                    AssistantSearch(tasks: visibleTasks, today: workspace.today, projects: projects, glossaryModel: model,
                                    currentProject: project ?? workspace.projects.first { $0.id == selectedMeeting?.projectId },
                                    currentTask: project != nil && projectSections.tab != .items && taskDraftID != selectedItemID
                                        ? nil : inspectedTask,
                                    taskStages: { task in
                                        workspace.projects.first { $0.id == task.projectId }?.stages
                                            ?? workspace.defaultStages
                                    },
                                    changeTaskStatus: { task, stage in
                                        if taskDraftID == task.id {
                                            return ("Сначала сохраните или отмените изменения в карточке задачи.", false)
                                        }
                                        guard await model.updateTask(task, changes: ["stage_id": stage.id]) else {
                                            return ("Не удалось изменить статус. Обновите карточку и повторите запрос.", false)
                                        }
                                        return ("«\(task.title)» теперь в статусе «\(stage.title)».", true)
                                    }, people: workspace.people,
                                    proposals: workspace.proposals, meetings: workspace.meetings,
                                    openTask: { assistantVisible = false; openTask($0) },
                                    openProject: { navigate(.project($0)) },
                                    openProposal: { proposal in
                                        assistantVisible = false
                                        if project == nil {
                                            openApprovals()
                                        } else {
                                            projectSections.tab = .items
                                            projectSections.status = .pending
                                            projectSections.kind = .all
                                            projectSections.filters.query = ""
                                        }
                                        approvalSelection.wrappedValue = .proposal(proposal.id)
                                    },
                                    canUseMicrophone: model.capture?.active == nil && creation == nil,
                                    meetingRecording: model.capture?.active != nil,
                                    takingNotes: valliTakingNotes,
                                    liveTranscript: selection == .meetings && model.capture?.liveDisplay == true &&
                                        (liveMeetingID == nil || liveMeetingID == selectedMeeting?.id) ? assistantLive : nil,
                                    liveRequests: $liveAssistantRequests,
                                    transcribe: model.transcribeAssistant,
                                    interpret: model.interpretAssistant,
                                    submitLocalCommand: { text, taskID, proposalID, update in
                                        var payload: [String: Any] = ["op":"assistant_command","text":text]
                                        if let taskID { payload["task_id"] = taskID }
                                        if let proposalID { payload["proposal_id"] = proposalID }
                                        if let update { payload["changes"] = update.fields }
                                        let id = await model.createEntity(payload)
                                        return (id, model.error)
                                    },
                                    close: { assistantVisible = false })
                }
                .frame(width: assistantWidth)
                .frame(maxHeight: .infinity)
                .background(palette.surface)
                .overlay(alignment: .leading) { Rectangle().fill(palette.border).frame(width: 1) }
            }
        }
    }

    private var needsIndustrySetup: Bool {
        guard let workspace = model.workspace else { return false }
        return workspace.settings.industryTemplate == nil && workspace.projects.isEmpty &&
            workspace.tasks.isEmpty && workspace.meetings.isEmpty
    }

    var body: some View {
        HStack(spacing: 0) {
            if navigationVisible {
                sidebar
                Rectangle().fill(palette.border).frame(width: 1)
            }
            VStack(spacing: 0) {
                topbar
                recordingBanner
                workspaceLayout.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(palette.background)
            .padding(.trailing, assistantVisible && liveMeetingID != nil ? assistantWidth : 0)
            .overlay(alignment: .trailing) {
                if assistantVisible { assistantDrawer }
            }
        }
        .environment(\.companyGlossary, companyGlossary)
        .environment(\.meetingTopics, meetingTopics)
        .preferredColorScheme(model.workspace?.settings.colorScheme)
        .tint(palette.accent)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            if !model.saving { Task { await model.reload() } }
        }
        .task { await model.reload() }
        .onChange(of: needsIndustrySetup) { needed in
            if needed && !offeredIndustrySetup {
                offeredIndustrySetup = true
                showingIndustrySetup = true
            }
        }
        .sheet(isPresented: $showingIndustrySetup) {
            IndustrySetupView(model: model)
        }
        .task { await model.pollCapture() }
        .task(id: livePreviewContext) {
            assistantLive = nil
            liveAssistantRequests.removeAll()
            guard livePreviewContext != nil else { return }
            if let session = model.capture?.active {
                await pollAssistantLive(session)
            } else if let meeting = selectedMeeting,
                      let snapshot = try? await model.liveTranscript(for: meeting.id), !Task.isCancelled {
                assistantLive = snapshot
            }
        }
        .fileImporter(isPresented: $importingAudio, allowedContentTypes: [.audio]) { result in
            if let id = importMeetingID, case let .success(url) = result {
                Task { await model.importAudio(from: url, meetingID: id) }
            }
            importMeetingID = nil
        }
        .alert("Сохранить выборку", isPresented: $savingView) {
            TextField("Название", text: $viewName)
            Button("Отмена", role: .cancel) {}
            Button("Сохранить") {
                let name = viewName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task {
                    var filters = taskStatus.savedFilters
                    filters["q"] = taskTab == .items ? approvalFilters.query.trimmingCharacters(in: .whitespacesAndNewlines) : query
                    if let id = project?.id ?? projectFilter { filters["projects"] = [String(id)] }
                    if unassignedOnly { filters["assignees"] = ["none"] }
                    else if let id = assigneeFilter { filters["assignees"] = [String(id)] }
                    if await model.saveView(name: name, filters: filters, board: taskTab == .board) {
                        savedView = model.workspace?.settings.savedViews?.first { $0.name == name }
                    }
                }
            }
        }
        .alert("Удалить сохранённую выборку?", isPresented: Binding(
            get: { deletingView != nil }, set: { if !$0 { deletingView = nil } }
        ), presenting: deletingView) { view in
            Button("Отмена", role: .cancel) {}
            Button("Удалить", role: .destructive) {
                Task {
                    if await model.deleteView(named: view.name) { savedView = nil }
                }
            }
        } message: { view in Text(view.name) }
        .sheet(item: $editingMeeting) { meeting in
            MeetingEditor(model: model, meeting: meeting)
                .sheetCloseButton(disabled: model.saving)
        }
        .sheet(item: $editingProject) { project in
            ProjectEditor(model: model, project: project)
                .sheetCloseButton(disabled: model.saving)
        }
        .alert(projectArchiveRequest?.archived == true ? "Восстановить проект?" : "Перенести проект в архив?",
               isPresented: Binding(get: { projectArchiveRequest != nil }, set: { if !$0 { projectArchiveRequest = nil } }),
               presenting: projectArchiveRequest) { project in
            Button("Отмена", role: .cancel) {}
            Button(project.archived == true ? "Восстановить" : "В архив") {
                Task {
                    if await model.setProjectArchived(project.archived != true, project: project) {
                        if self.project?.id == project.id { closeInspector() }
                    }
                }
            }
        } message: { project in
            Text(project.title)
        }
        .sheet(item: $creation) { kind in
            VStack(alignment: .leading, spacing: 16) {
                Text(kind.rawValue).font(.headline)
                TextField(kind == .meeting ? "Название (по умолчанию «Совещание»)" :
                          kind == .person ? "Имя" : kind == .decision ? "Текст решения" : "Название", text: $newTitle)
                if kind == .project {
                    TextField("Краткое описание", text: $newProjectDescription, axis: .vertical)
                        .lineLimit(2...4)
                    if let unresolvedProjectOwner, newProjectOwnerID == nil {
                        Text("Уточните владельца «" + unresolvedProjectOwner + "».").foregroundStyle(.secondary)
                    }
                    Picker("Владелец", selection: $newProjectOwnerID) {
                        Text(unresolvedProjectOwner == nil ? "Не назначен" : "Выберите владельца").tag(nil as Int?)
                        ForEach(model.workspace?.people ?? []) { Text($0.name).tag(Optional($0.id)) }
                    }
                    ProjectDateField(title: "Начало", value: $newProjectStart)
                    ProjectDateField(title: "Срок завершения", value: $newProjectEnd)
                }
                if [.task, .meeting, .decision].contains(kind) {
                    if let creationNewProjectName {
                        LabeledContent("Новый проект", value: creationNewProjectName)
                    } else {
                        Picker("Проект", selection: $creationProjectID) {
                            Text(creationNeedsProject ? "Выберите проект" : "Без проекта").tag(nil as Int?)
                            ForEach(projects) { Text($0.title).tag(Optional($0.id)) }
                        }
                    }
                }
                if kind == .task {
                    if let unresolvedTaskAssignee, newTaskAssigneeID == nil {
                        Text("Уточните исполнителя «" + unresolvedTaskAssignee + "».").foregroundStyle(.secondary)
                    }
                    Picker("Исполнитель", selection: $newTaskAssigneeID) {
                        Text(unresolvedTaskAssignee == nil ? "Не назначен" : "Выберите исполнителя").tag(nil as Int?)
                        ForEach(model.workspace?.people ?? []) { Text($0.name).tag(Optional($0.id)) }
                    }
                    TextField("Подробности", text: $newTaskDescription, axis: .vertical)
                    HStack {
                        TextField("Срок (ГГГГ-ММ-ДД)", text: $newTaskDueDate)
                        TextField("Время (ЧЧ:ММ)", text: $newTaskDueTime)
                            .disabled(newTaskDueDate.isEmpty)
                    }
                    Picker("Приоритет", selection: $newTaskPriority) {
                        Text("Низкий").tag("low")
                        Text("Обычный").tag("normal")
                        Text("Высокий").tag("high")
                        Text("Критический").tag("critical")
                    }
                }
                if kind == .meeting {
                    Toggle("Назначить другую дату и время", isOn: $usesCustomMeetingDate)
                    if usesCustomMeetingDate {
                        DatePicker("Дата и время", selection: $newMeetingDate, displayedComponents: [.date, .hourAndMinute])
                            .environment(\.timeZone, meetingTimeZone)
                    } else {
                        Text("Дата и время заполнятся при сохранении.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Участники").font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.workspace?.people ?? []) { person in
                                Toggle(person.name, isOn: Binding(
                                    get: { newParticipants.contains(person.id) },
                                    set: { selected in
                                        if selected { newParticipants.insert(person.id) }
                                        else { newParticipants.remove(person.id) }
                                    }
                                ))
                                .toggleStyle(.checkbox)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 120)
                    HStack {
                        TextField("Имя нового участника", text: $newParticipantName)
                            .onSubmit { Task { await addMeetingParticipant() } }
                        Button("Добавить участника") { Task { await addMeetingParticipant() } }
                            .disabled(newParticipantName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if let error = model.error { Text(error).foregroundStyle(.red) }
                let canSave = (kind == .meeting || !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) &&
                    (!creationNeedsProject || creationProjectID != nil || creationNewProjectName != nil) &&
                    (kind != .project || unresolvedProjectOwner == nil || newProjectOwnerID != nil) &&
                    (kind != .task || unresolvedTaskAssignee == nil || newTaskAssigneeID != nil)
                HStack {
                    Spacer()
                    Button("Отмена") { creation = nil }
                    Button("Сохранить") { Task { await create(kind) } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                }
            }
            .padding()
            .frame(width: 420)
            .disabled(model.saving || model.loading)
            .sheetCloseButton(disabled: model.saving)
            .interactiveDismissDisabled(model.saving)
            .sheet(item: $newMeetingPerson) { person in
                VStack(alignment: .leading, spacing: 12) {
                    Text("Карточка участника").font(.title3.bold())
                    Form {
                        PersonDetailsEditor(model: model, person: person)
                        VoiceProfileView(model: model, person: person)
                    }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                    .background(palette.background)
                    Button("Вернуться к совещанию") { newMeetingPerson = nil }
                        .disabled(model.saving)
                }
                .padding()
                .frame(width: 460, height: 520)
                .sheetCloseButton(disabled: model.saving)
                .interactiveDismissDisabled(model.saving)
            }
        }
    }
}
