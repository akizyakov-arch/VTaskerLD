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
    @State private var settingsArea: SettingsArea = .general
    @State private var glossaryTab: GlossaryTab = .terms
    @State private var history: [NavigationEntry] = []
    @Environment(\.colorScheme) private var colorScheme
    @State private var navigationVisible = true
    @State private var assistantVisible = false
    @State private var assistantVoiceEnabled = false
    @State private var showingIndustrySetup = false
    @State private var offeredIndustrySetup = false
    @State private var valliButtonHovered = false
    @State private var tourStep: ValliTourStep?
    @State private var showingHelpError = false
    @State private var taskDraftID: Int?
    @State private var assistantLive: LiveTranscript?
    @State private var projectDirectoryFilters = ProjectDirectoryFilters()
    @State private var personDirectoryFilters = PersonDirectory.Filters()
    @State private var meetingFilters = MeetingDirectoryFilters()
    @FocusState private var meetingSearchFocused: Bool
    @State private var dashboardQuery = ""
    @FocusState private var dashboardSearchFocused: Bool
    @State private var scopedGlossary: [CompanyTerm] = []
    @State private var loadedGlossaryKey: String?
    private var activeTerminology: [String] {
        model.workspace?.terminologySelection(projectID: project?.id ?? inspectedTask?.projectId,
                                             meeting: selectedMeeting) ?? []
    }

    private var scopedGlossaryKey: String {
        let revisions = model.workspace?.companyTerms?.map { "\($0.id):\($0.revision)" } ?? []
        return activeTerminology.joined(separator: ",") + "|" +
            revisions.joined(separator: ",") + "|\(model.dictionaryGeneration)"
    }

    private var companyGlossary: CompanyGlossary {
        guard let workspace = model.workspace else { return CompanyGlossary() }
        if !activeTerminology.isEmpty {
            return CompanyGlossary(loadedGlossaryKey == scopedGlossaryKey ? scopedGlossary : workspace.companyTerms ?? [])
        }
        return CompanyGlossary(workspace.glossaryTerms ?? workspace.companyTerms ?? [])
    }

    private var meetingTopics: MeetingTopics {
        let selected = activeTerminology
        if selected.isEmpty {
            return MeetingTopics(industry: model.workspace?.settings.industryTemplate ?? .events)
        }
        return MeetingTopics(industries: selected.map { IndustryTemplate(rawValue: $0) })
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

    private enum GlossaryTab: String, CaseIterable {
        case terms = "Термины"
        case periods = "Этапы работ"
    }

    private enum TaskTab: String, CaseIterable {
        case items = "Задачи и решения"
        case board = "Доска"
        case calendar = "Календарь"

        var icon: String {
            switch self {
            case .items: return "checklist"
            case .board: return "rectangle.split.3x1"
            case .calendar: return "calendar"
            }
        }
    }

    private enum ProjectTab: String, CaseIterable {
        case overview = "Обзор"
        case items = "Задачи и решения"
        case meetings = "Совещания"
        case materials = "Материалы"
    }

    private struct ProjectSections {
        var tab: ProjectTab = .overview
        var kind: ApprovalsView.ItemList.Kind = .all
        var status: ApprovalsView.ItemList.Status = .all
        var filters = ApprovalsView.Filters()
    }

    private struct ProjectEdit {
        let snapshot: Project
        let target: ProjectEditor.Target
    }

    private enum ProjectNavigation {
        case open(Selection, Int?)
        case edit(Project, ProjectEditor.Target)
        case back
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
        let priority: String?
        let period: TaskFilter
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
    @State private var projectEdit: ProjectEdit?
    @State private var pendingProjectNavigation: ProjectNavigation?
    @State private var projectArchiveRequest: Project?
    @State private var creation: Creation?
    @State private var assistantEditsCreation = false
    @State private var savedView: SavedTaskView?
    @AppStorage("workItems.groupByTopic") private var groupByTopic = true
    @FocusState private var taskSearchFocused: Bool
    @State private var taskTab: TaskTab = .items
    @State private var taskKind: ApprovalsView.ItemList.Kind = .all
    @State private var taskApprovalStatus: ApprovalsView.ItemList.Status = .all
    @State private var savingView = false
    @State private var viewName = ""
    @State private var deletingView: SavedTaskView?
    @State private var query = ""
    @State private var taskStatus: TaskFilter = .all
    @State private var taskPriority: String?
    @State private var taskPeriod: TaskFilter = .all
    @State private var projectFilter: Int?
    @State private var assigneeFilter: Int?
    @State private var unassignedOnly = false
    @State private var newTitle = ""
    @State private var newIndustries: [String] = []
    @State private var newMeetingDate = Date()
    @State private var usesCustomMeetingDate = false
    @State private var newParticipants: Set<Int> = []
    @State private var newParticipantName = ""
    @State private var newMeetingPerson: Person?

    @State private var creationProjectID: Int?
    @State private var creationNewProjectName: String?
    @State private var creationNeedsProject = false
    @State private var creationProjectHint: String?
    @State private var pendingProjectDate: String?
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
        guard !model.saving && !model.loading && canSaveCreation(kind) else { return }
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
                "title": title, "status": "planned", "terminology_industries": newIndustries,
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
                "terminology_industries": newIndustries,
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
        guard let id = await model.createEntity(payload) else { return }
        cancelCreation()
        switch kind {
        case .project:
            navigate(.project(id))
        case .task:
            openTask(id)
            if project != nil {
                projectSections.kind = .tasks
                projectSections.status = .approved
                projectSections.filters = ApprovalsView.Filters()
            } else {
                taskTab = .items
                taskKind = .tasks
                taskApprovalStatus = .approved
                approvalFilters = ApprovalsView.Filters()
            }
        case .meeting:
            openMeeting(id)
        case .decision:
            if let selectedProject {
                navigate(.project(selectedProject.id))
                projectSections.tab = .items
                projectSections.kind = .decisions
                projectSections.status = .approved
                projectSections.filters = ApprovalsView.Filters()
                inspectedApproval = .decision(id)
            }
        case .person:
            navigate(.people, itemID: id)
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
        case .glossary: return "Справочники"
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
        let text = selection == .tasks && taskTab == .items ? "" : query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let savedView, let workspace = model.workspace {
            return savedView.apply(to: visibleTasks, in: workspace, project: project?.id)
        }
        return visibleTasks.filter { task in
            if let projectID = project?.id ?? projectFilter, task.projectId != projectID { return false }
            if unassignedOnly && task.assigneeId != nil { return false }
            if let assigneeFilter, task.assigneeId != assigneeFilter { return false }
            let today = model.workspace?.today ?? ""
            if !taskStatus.matches(task, today: today) { return false }
            if taskPeriod != .all && !taskPeriod.matches(task, today: today) { return false }
            if let taskPriority, taskPriority != (task.priority ?? "normal") { return false }
            return text.isEmpty || task.title.localizedCaseInsensitiveContains(text)
                || task.description?.localizedCaseInsensitiveContains(text) == true
        }
    }

    private func navigate(_ destination: Selection, itemID: Int? = nil) {
        guard selection != destination || selectedItemID != itemID else {
            inspectedApproval = nil
            return
        }
        if projectEdit != nil {
            guard !model.saving else { return }
            pendingProjectNavigation = .open(destination, itemID)
            return
        }
        history.append(NavigationEntry(section: selection, itemID: selectedItemID,
                                       approval: inspectedApproval, meetingTab: meetingTab,
                                       projectSections: projectSections,
                                       taskFilters: TaskFilterSnapshot(savedView: savedView, tab: taskTab, kind: taskKind,
                                                                      approvals: taskApprovalStatus, query: query,
                                                                      status: taskStatus, priority: taskPriority, period: taskPeriod,
                                                                      project: projectFilter,
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
        if projectEdit != nil {
            guard !model.saving else { return }
            pendingProjectNavigation = .back
            return
        }
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
        taskPriority = filters.priority
        taskPeriod = filters.period
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
        if let task = visibleTasks.first(where: { $0.id == id }),
           let taskProjectID = task.projectId, project?.id == taskProjectID || selectedMeeting?.projectId == taskProjectID {
            navigate(.project(taskProjectID), itemID: id)
            projectSections.tab = .items
            projectSections.status = .approved
            projectSections.kind = .tasks
            projectSections.filters = ApprovalsView.Filters()
            return
        }
        navigate(.tasks, itemID: id)
        taskTab = .items
        taskKind = .tasks
        taskApprovalStatus = .approved
        approvalFilters = ApprovalsView.Filters()
        savedView = nil
        query = ""
        projectFilter = nil
        assigneeFilter = nil
        unassignedOnly = false
        taskStatus = visibleTasks.first { $0.id == id }?.stageKind == "cancelled" ? .cancelled : .all
    }

    private func showProjectCard(_ project: Project, target: ProjectEditor.Target = .details) {
        if let projectEdit {
            if projectEdit.snapshot.id != project.id {
                pendingProjectNavigation = .edit(project, target)
            }
            return
        }
        if self.project?.id != project.id { navigate(.project(project.id)) }
        if selectedItemID != nil && taskDraftID != selectedItemID { closeInspector() }
        inspectedApproval = nil
        projectSections.tab = .overview
        assistantVisible = false
        projectEdit = ProjectEdit(snapshot: project, target: target)
    }

    private func discardProjectEdit(and continueTo: ProjectNavigation) {
        projectEdit = nil
        switch continueTo {
        case .open(let destination, let itemID): navigate(destination, itemID: itemID)
        case .edit(let project, let target): showProjectCard(project, target: target)
        case .back: goBack()
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

    private func resetTaskFilters() {
        taskStatus = .all
        taskPriority = nil
        taskPeriod = .all
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
                    nav("Задачи и решения", icon: "checkmark.square", destination: .tasks, count: visibleTasks.filter { $0.stageKind == "active" }.count)
                    nav("Совещания", icon: "video", destination: .meetings)
                    nav("Участники", icon: "person.2", destination: .people)
                    nav("Справочники", icon: "book", destination: .glossary)
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
                        today: workspace.today, query: dashboardQuery, openTask: openTask,
                        showTasks: { filter in
                            navigate(.tasks)
                            taskTab = .items
                            taskKind = .tasks
                            taskApprovalStatus = .approved
                            approvalFilters.query = ""
                            savedView = nil
                            query = ""
                            resetTaskFilters()
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
                            resetTaskFilters()
                            assigneeFilter = assignee
                            unassignedOnly = assignee == nil
                            taskStatus = .active
                        },
                        myID: workspace.settings.meId,
                        openProjects: { openDashboardProjects(activeOnly: false) },
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
                        openApprovals: openApprovals,
                        openActiveProjects: { openDashboardProjects(activeOnly: true) },
                        createTask: { beginCreation(.task) },
                        createMeeting: { beginCreation(.meeting) },
                        createProject: { beginCreation(.project) },
                        openWorkPeriods: { openGlossary(.periods) },
                        photoURL: model.personPhotoURL
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

    private func openDashboardProjects(activeOnly: Bool) {
        projectDirectoryFilters.query = ""
        projectDirectoryFilters.owner = ""
        projectDirectoryFilters.section = activeOnly ? .current : .all
        projectDirectoryFilters.status = activeOnly ? "active" : ""
        navigate(.projectList)
    }

    private var detailLayout: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if let error = model.error {
                    Text(error).foregroundStyle(.secondary).padding()
                }
                if selection == .tasks { taskDirectoryControls }
                if model.loading && model.workspace == nil {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if selection == .processing {
                    List(model.workspace?.meetings.filter { $0.processing != nil || !$0.recordings.isEmpty } ?? []) { meeting in
                        Section(meeting.visibleTitle) { ProcessingControls(model: model, meeting: meeting) }
                    }
                } else if (selection == .projectList || project != nil), let workspace = model.workspace {
                    ProjectDirectory(workspace: workspace, filters: $projectDirectoryFilters, selected: project,
                                     allowsSplit: selectedItemID == nil && inspectedApproval == nil,
                                     openProject: { navigate(.project($0)) }, closeProject: { navigate(.projectList) },
                                     createProject: { beginCreation(.project) }, openTask: openTask,
                                     editProject: { showProjectCard($0) }, changeArchive: { projectArchiveRequest = $0 },
                                     actionsDisabled: model.saving || model.loading || projectEdit != nil) {
                        if let project { projectDetail(project, workspace: workspace) }
                    }
                } else if selection == .settings, let workspace = model.workspace {
                    SettingsPage(model: model, workspace: workspace, area: $settingsArea,
                                 openGlossary: { openGlossary(.terms) }, openWorkPeriodCatalog: { openGlossary(.periods) },
                                 openProcessing: { navigate(.processing) })
                } else if selection == .meetings {
                    if let meeting = selectedMeeting {
                        meetingPage(meeting)
                    } else if let workspace = model.workspace {
                        MeetingDirectory(meetings: workspace.meetings, projects: workspace.projects,
                                         people: workspace.people, timeZone: meetingTimeZone,
                                         capture: model.capture?.active, filters: $meetingFilters, open: openMeeting)
                    }
                } else if selection == .people {
                    PersonDirectory(model: model, selection: inspectedItemSelection, filters: $personDirectoryFilters)
                } else if selection == .glossary, let workspace = model.workspace {
                    glossaryPage(workspace)
                } else if selection == .tasks && taskTab == .items, let workspace = model.workspace {
                    ApprovalsView(model: model, workspace: workspace, inspectedItem: approvalSelection,
                                  filters: $approvalFilters, itemList: .init(
                                    project: nil, kind: taskKind, status: taskApprovalStatus,
                                    openTask: { navigate(.tasks, itemID: $0) }, openMeeting: openMeeting,
                                    acceptedTasks: tasks, taskGrouping: savedView?.group,
                                    directory: .init(projectID: projectFilter,
                                                     assigneeID: assigneeFilter, unassigned: unassignedOnly,
                                                     selectedTaskID: selectedItemID, changeView: changeTaskDirectoryView)
                                  ), groupByTopic: groupByTopic)
                } else if selection == .tasks && taskTab == .calendar, let workspace = model.workspace {
                    ScrollView {
                        ScheduleView(tasks: tasks, projects: projects, people: workspace.people,
                                     today: workspace.today, openTask: openCalendarTask, showsGanttPicker: false)
                            .panelCard()
                            .padding(15)
                    }
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

    private func openGlossary(_ tab: GlossaryTab) {
        glossaryTab = tab
        navigate(.glossary)
    }

    private func glossaryPage(_ workspace: Workspace) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                ForEach(GlossaryTab.allCases, id: \.self) { tab in
                    let active = glossaryTab == tab
                    Button { glossaryTab = tab } label: {
                        Label(tab.rawValue, systemImage: tab == .terms ? "text.book.closed" : "square.3.layers.3d")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(active ? Color.white : palette.text)
                            .padding(.horizontal, 17).padding(.vertical, 9)
                            .background(active ? Color(red: 0.40, green: 0.24, blue: 0.83)
                                        : palette.projectAccent.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)

            switch glossaryTab {
            case .terms:
                CompanyGlossaryView(model: model, entries: workspace.companyTerms ?? [],
                                    proposals: workspace.termProposals ?? [], meetings: workspace.meetings,
                                    openMeeting: openMeeting, openDictionarySettings: {
                                        settingsArea = .terminology
                                        navigate(.settings)
                                    })
            case .periods:
                WorkPeriodCatalogView(model: model, embedded: true)
            }
        }
    }

    private var showsPendingTasksOnly: Bool { taskTab == .items && taskApprovalStatus == .pending }

    private var taskDirectoryControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal) {
                HStack(spacing: 3) {
                    ForEach(TaskTab.allCases, id: \.self) { tab in
                        Button {
                            taskTab = tab
                        } label: {
                            Label(tab.rawValue, systemImage: tab.icon)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(tab == taskTab ? .white : palette.text)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(tab == taskTab ? Color(red: 0.41, green: 0.24, blue: 0.84) : .clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(tab == taskTab ? .isSelected : [])
                    }
                }
                .padding(3)
                .background(palette.projectAccent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            }
            .scrollIndicators(.hidden)
            if let savedView {
                HStack { savedTaskFilter(savedView); Spacer(); taskViewMenu }
                    .panelCard(inset: 8)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        taskScopeControls
                        taskTimeControls
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 7) {
                        ScrollView(.horizontal) { HStack(spacing: 7) { taskScopeControls } }
                        ScrollView(.horizontal) { HStack(spacing: 7) { taskTimeControls } }
                    }
                    .scrollIndicators(.hidden)
                }
                .panelCard(inset: 9)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var taskScopeControls: some View {
        Menu {
            Button("Мои задачи") {
                assigneeFilter = model.workspace?.settings.meId
                unassignedOnly = false
                if !showsPendingTasksOnly { taskStatus = .active }
            }
            .disabled(model.workspace?.settings.meId == nil)
            Button("Сбросить фильтры", action: resetDirectoryFilters)
        } label: {
            Label("Фильтры", systemImage: "line.3.horizontal.decrease.circle")
                .foregroundStyle(palette.projectAccent)
        }
        let projectTitle = projects.first { $0.id == projectFilter }?.title ?? "Проект"
        taskFilterMenu("Проект", value: projectTitle) {
            Picker("Проект", selection: $projectFilter) {
                Text("Все проекты").tag(nil as Int?)
                ForEach(projects) { Text($0.title).tag(Optional($0.id)) }
            }
        }
        taskFilterMenu("Статус задачи", value: taskStatus == .all ? "Статус" : taskStatus.rawValue) {
            Picker("Статус", selection: $taskStatus) {
                ForEach([TaskFilter.all, .active, .done, .cancelled, .overdue]) { status in
                    Text(status == .all ? "Все статусы" : status.rawValue).tag(status)
                }
                if ![TaskFilter.all, .active, .done, .cancelled, .overdue].contains(taskStatus) {
                    Text(taskStatus.rawValue).tag(taskStatus)
                }
            }
        }
        .disabled(showsPendingTasksOnly)
        let priorities = [("low", "Низкий"), ("normal", "Обычный"), ("high", "Высокий"), ("critical", "Критический")]
        taskFilterMenu("Приоритет", value: priorities.first { $0.0 == taskPriority }?.1 ?? "Приоритет") {
            Picker("Приоритет", selection: $taskPriority) {
                Text("Все приоритеты").tag(nil as String?)
                ForEach(priorities, id: \.0) { id, name in Text(name).tag(Optional(id)) }
            }
        }
        .disabled(showsPendingTasksOnly)
    }

    @ViewBuilder
    private var taskTimeControls: some View {
        let people = model.workspace?.people ?? []
        let assigneeTitle = people.first { $0.id == assigneeFilter }?.speakerPickerName
        taskFilterMenu("Ответственный", value: unassignedOnly ? "Без исполнителя" : assigneeTitle ?? "Ответственный") {
            Picker("Ответственный", selection: Binding(
                get: { unassignedOnly ? -1 : assigneeFilter },
                set: { unassignedOnly = $0 == -1; assigneeFilter = unassignedOnly ? nil : $0 }
            )) {
                Text("Все исполнители").tag(nil as Int?)
                Text("Без исполнителя").tag(Optional(-1))
                ForEach(people) { Text($0.speakerPickerName).tag(Optional($0.id)) }
            }
        }
        taskFilterMenu("Период задачи", value: taskPeriod == .all ? "Период" : taskPeriod.rawValue) {
            Picker("Период", selection: $taskPeriod) {
                Text("Все даты").tag(TaskFilter.all)
                ForEach([TaskFilter.today, .dueSoon, .later, .undated]) { Text($0.rawValue).tag($0) }
            }
        }
        .disabled(showsPendingTasksOnly)
        Button("Сбросить", action: resetDirectoryFilters).buttonStyle(.link)
        if taskTab == .items { groupingButton.labelStyle(.iconOnly) }
        taskViewMenu.labelStyle(.iconOnly)
    }

    private func taskFilterMenu<Items: View>(_ title: String, value: String,
                                               @ViewBuilder items: () -> Items) -> some View {
        Menu(content: items) {
            Text(String(value.prefix(22))).lineLimit(1)
        }
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .fixedSize()
    }

    private var taskDirectorySearch: some View {
        HStack(spacing: 6) {
            PanelSearchField(placeholder: "Поиск задач и решений…",
                             query: taskTab == .items ? $approvalFilters.query : $query,
                             focus: $taskSearchFocused)
            Button("⌘K") { taskSearchFocused = true }
                .font(.caption.monospaced())
                .buttonStyle(.bordered)
                .keyboardShortcut("k", modifiers: .command)
                .accessibilityLabel("Перейти к поиску задач и решений")
        }
        .frame(width: 218)
    }

    private func resetDirectoryFilters() {
        resetTaskFilters()
        approvalFilters.reset()
        query = ""
        approvalFilters.query = ""
    }

    private func changeTaskDirectoryView(_ kind: ApprovalsView.ItemList.Kind,
                                         _ status: ApprovalsView.ItemList.Status) {
        inspectedApproval = nil
        taskKind = kind
        taskApprovalStatus = status
    }

    private func openCalendarTask(_ id: Int) {
        navigate(.tasks, itemID: id)
    }

    private var taskWorkspace: some View {
        TaskWorkspace(model: model, tasks: tasks, projects: projects, projectID: savedView == nil ? projectFilter : nil,
                      people: model.workspace?.people ?? [], selection: inspectedItemSelection)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
    }

    private func projectDetail(_ project: Project, workspace: Workspace) -> some View {
        let edit = projectEdit.flatMap { $0.snapshot.id == project.id ? $0 : nil }
        return VStack(spacing: 0) {
            ProjectDetailHeader(project: project,
                                direction: workspace.terminologyTitles(project.terminologyIndustries ?? []),
                                actionsDisabled: model.saving || model.loading || edit != nil,
                                editing: edit != nil, edit: { showProjectCard(project) },
                                changeStatus: { status in
                                    guard status != project.status else { return }
                                    Task { await model.updateProject(project, changes: ["status": status]) }
                                },
                                archive: { projectArchiveRequest = project },
                                createMeeting: { beginCreation(.meeting) },
                                createTask: { beginCreation(.task) },
                                createDecision: { beginCreation(.decision) })
            ScrollView(.horizontal) {
                HStack(spacing: 13) {
                    projectDetailTab("Обзор", icon: "chart.bar", tab: .overview)
                    projectDetailTab("Совещания", icon: "calendar", tab: .meetings,
                                     count: workspace.meetings.filter { $0.projectId == project.id }.count)
                    projectDetailTab("Задачи", icon: "checkmark.square", tab: .items, kind: .tasks,
                                     count: workspace.tasks.filter { $0.projectId == project.id && $0.stageKind != "cancelled" }.count)
                    projectDetailTab("Решения", icon: "bolt", tab: .items, kind: .decisions,
                                     count: workspace.decisions.filter { $0.projectId == project.id && $0.active }.count)
                    projectDetailTab("Материалы", icon: "folder", tab: .materials)
                }
                .padding(.horizontal, 13)
            }
            .scrollIndicators(.hidden)
            .disabled(edit != nil)
            Divider()
            if let edit {
                ProjectEditor(model: model, project: edit.snapshot, target: edit.target, close: { projectEdit = nil })
                    .id(edit.snapshot.id)
            } else {
                projectContent(project, workspace: workspace).id(project.id)
            }
        }
    }

    private func projectDetailTab(_ title: String, icon: String, tab: ProjectTab,
                                  kind: ApprovalsView.ItemList.Kind? = nil, count: Int? = nil) -> some View {
        let active = projectSections.tab == tab && (kind == nil || projectSections.kind == kind ||
            (kind == .tasks && projectSections.kind == .all))
        return Button {
            if let kind, projectSections.kind != kind { inspectedApproval = nil }
            projectSections.tab = tab
            if let kind { projectSections.kind = kind }
        } label: {
            HStack(spacing: 5) {
                Label(title, systemImage: icon).font(.callout.weight(active ? .semibold : .regular))
                if let count {
                    Text(count.formatted()).font(.caption.monospacedDigit())
                        .padding(.horizontal, 5).background(palette.selected, in: Capsule())
                }
            }
            .fixedSize()
            .padding(.horizontal, 3)
            .padding(.vertical, 9)
            .frame(minHeight: 36)
            .foregroundStyle(active ? palette.projectAccent : palette.text)
            .overlay(alignment: .bottom) {
                if active { Capsule().fill(palette.projectAccent).frame(height: 2) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
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
            }, openDecisions: {
                projectSections.tab = .items
                projectSections.kind = .decisions
                projectSections.status = .approved
                projectSections.filters.query = ""
            }, photoURL: model.personPhotoURL, openBoard: {
                navigate(.tasks)
                resetTaskFilters()
                projectFilter = project.id
                taskTab = .board
            }, editProject: { target in
                showProjectCard(project, target: target)
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
        case .materials:
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Материалы проекта", systemImage: "folder").font(.headline)
                    if let materials = project.materials, !materials.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(materials).textSelection(.enabled)
                    } else {
                        Text("Материалы пока не добавлены.").foregroundStyle(.secondary)
                    }
                    Button("Редактировать материалы") { showProjectCard(project) }
                        .buttonStyle(.link).disabled(model.saving || model.loading)
                }
                .panelCard()
                .padding(14)
            }
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

    private func meetingTasks(_ meeting: Meeting, missingWorkPeriod: ((String) -> Bool)?) -> some View {
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
            }, missingWorkPeriod: missingWorkPeriod) { row in
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
                let missingWorkPeriod = model.workspace?.workPeriodTitles(for: activeTerminology)
                    .map { meetingTopics.missingWorkPeriod(in: $0) }
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
                meetingTasks(meeting, missingWorkPeriod: missingWorkPeriod).id(meeting.id)
                MeetingDecisions(
                    decisions: model.workspace?.decisions.filter { $0.meetingId == meeting.id } ?? [],
                    proposals: model.workspace?.proposals.filter {
                        $0.kind == "decision" && $0.status == "pending" && $0.source?.meetingId == meeting.id
                    } ?? [],
                    missingWorkPeriod: missingWorkPeriod,
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

    private func beginCreation(_ kind: Creation, fromAssistant: Bool = false) {
        assistantEditsCreation = fromAssistant
        newTitle = ""
        newIndustries = []
        newMeetingDate = Date()
        usesCustomMeetingDate = false
        newParticipants = []
        newParticipantName = ""
        creationProjectID = project.flatMap { $0.archived == true ? nil : $0.id }
        creationNewProjectName = nil
        creationNeedsProject = kind == .decision
        creationProjectHint = nil
        pendingProjectDate = nil
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

    private func prepareAssistantCreation(_ draft: AssistantCreation, projectID: Int?, personID: Int?) {
        beginCreation(draft.kind, fromAssistant: true)
        assistantVisible = true
        newTitle = draft.title
        creationProjectID = projectID.flatMap { id in projects.contains { $0.id == id } ? id : nil }
        if let name = draft.projectName, !name.isEmpty, creationProjectID == nil {
            creationNeedsProject = true
            creationProjectHint = name
        }
        switch draft.kind {
        case .project:
            newProjectDescription = draft.description ?? ""
            if let fields = draft.projectFields {
                newProjectStart = fields.start ?? ""
                newProjectEnd = fields.end ?? ""
                pendingProjectDate = fields.unspecifiedDate
                newProjectOwnerID = personID
                unresolvedProjectOwner = personID == nil ? fields.owner : nil
            }
        case .task:
            newTaskDescription = draft.description ?? ""
            newTaskAssigneeID = personID
            unresolvedTaskAssignee = personID == nil ? draft.assignee : nil
            newTaskDueDate = draft.dueDate ?? ""
            newTaskDueTime = draft.dueTime ?? ""
            if let priority = draft.priority, ["low", "normal", "high", "critical"].contains(priority) {
                newTaskPriority = priority
            }
        case .meeting:
            if draft.useCurrentMeetingTime {
                newMeetingDate = .now
                usesCustomMeetingDate = true
            } else if let due = draft.dueDate {
                applyMeetingSchedule(date: due, time: draft.dueTime)
            }
        case .decision, .person:
            break
        }
    }

    private func canSaveCreation(_ kind: Creation) -> Bool {
        (kind == .meeting || !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) &&
            (!creationNeedsProject || creationProjectID != nil || creationNewProjectName != nil) &&
            (kind != .project || (pendingProjectDate == nil && (unresolvedProjectOwner == nil || newProjectOwnerID != nil))) &&
            (kind != .task || unresolvedTaskAssignee == nil || newTaskAssigneeID != nil)
    }

    private func creationConversation() -> CreationConversation? {
        guard assistantEditsCreation, let kind = creation else { return nil }
        var missing: [CreationField] = []
        if kind != .meeting && newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append(.title) }
        if [.meeting, .task, .decision].contains(kind) && creationProjectID == nil { missing.append(.project) }
        if kind == .project {
            if pendingProjectDate != nil { missing.append(.dateRole) }
            if newProjectStart.isEmpty { missing.append(.start) }
            if newProjectEnd.isEmpty { missing.append(.end) }
            if newProjectOwnerID == nil { missing.append(.owner) }
            if newProjectDescription.isEmpty { missing.append(.description) }
        }
        if kind == .task {
            if newTaskAssigneeID == nil { missing.append(.assignee) }
            if newTaskDueDate.isEmpty { missing.append(.end) }
            if newTaskDescription.isEmpty { missing.append(.description) }
        }
        if kind == .meeting {
            if !usesCustomMeetingDate { missing.append(.meetingDate) }
            if newParticipants.isEmpty { missing.append(.participants) }
        }
        return CreationConversation(kind: kind, missing: missing, canSave: canSaveCreation(kind))
    }

    private func cancelCreation() {
        guard !model.saving else { return }
        creation = nil
        assistantEditsCreation = false
    }

    private func confirmAssistantCreation() async -> String? {
        guard let dialog = creationConversation(), dialog.canSave else { return "Заполните обязательные поля в карточке." }
        guard !model.saving && !model.loading else { return "Дождитесь сохранения текущих изменений." }
        await create(dialog.kind)
        return creation == nil ? nil : (model.error ?? "Не удалось сохранить. Проверьте данные в карточке.")
    }

    private func creationPeople(matching name: String) -> [Person] {
        let words = CompanyGlossary.words(name)
        guard !words.isEmpty else { return [] }
        let people = model.workspace?.people ?? []
        let exact = people.filter { person in
            var forms = [person.name, person.nickname, person.lastName, person.speakerPickerName].compactMap { $0 }
            if let lastName = person.lastName, !lastName.isEmpty {
                forms.append(person.name + " " + lastName)
                forms.append(lastName + " " + person.name)
            }
            return forms.contains { CompanyGlossary.words($0) == words }
        }
        if !exact.isEmpty { return exact }
        guard words.count == 1 else { return [] }
        let variants: [String: Set<String>] = [
            "леша": ["алексей"], "алеша": ["алексей"], "ира": ["ирина"],
            "саша": ["александр", "александра"], "маша": ["мария"], "даша": ["дарья"],
            "миша": ["михаил"], "дима": ["дмитрий"], "вова": ["владимир"],
        ]
        let shortName = words[0]
        return people.filter { person in
            guard let first = CompanyGlossary.words(person.name).first else { return false }
            let root = first.last.map { "ая".contains($0) } == true ? String(first.dropLast()) : first
            return first == shortName || variants[shortName]?.contains(first) == true
                || (root.count >= 3 && ["е", "у", "ю", "а", "я"].contains { shortName == root + $0 })
        }
    }

    private func updateAssistantCreation(_ field: CreationField, value: String?) -> String? {
        guard let kind = creationConversation()?.kind else { return "Откройте карточку создания." }
        let today = model.workspace?.today ?? ""
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch field {
        case .title:
            guard !text.isEmpty else { return field.question }
            newTitle = text
        case .project:
            guard kind != .project else { return "В карточке нового проекта можно изменить название." }
            if value == nil {
                guard kind != .decision else { return "Для решения нужно выбрать проект." }
                creationProjectID = nil
                creationNeedsProject = false
                creationProjectHint = nil
            } else {
                let matches = projects.filter { CompanyGlossary.words($0.title) == CompanyGlossary.words(text) }
                guard matches.count == 1, let project = matches.first else {
                    return "Уточните название проекта или выберите его в карточке."
                }
                creationProjectID = project.id
                creationProjectHint = nil
            }
        case .dateRole:
            guard kind == .project else { return "Уточните дату." }
            if value == nil {
                pendingProjectDate = nil
            } else if let date = pendingProjectDate {
                let role = AssistantRequest.normalize(text)
                if ["начало", "это начало", "дата начала"].contains(role) { newProjectStart = date }
                else if ["срок", "это срок", "завершение", "дата завершения"].contains(role) { newProjectEnd = date }
                else { return field.question }
                pendingProjectDate = nil
            } else if let date = AssistantProjectFields.parseDate(text, today: today) {
                pendingProjectDate = date
            } else {
                return "Не удалось определить дату. Скажите, например, «17 декабря»."
            }
        case .start, .end, .meetingDate:
            if kind == .meeting {
                if value == nil { usesCustomMeetingDate = false; return nil }
                if AssistantCreation.isImmediateMeeting(text) {
                    newMeetingDate = .now
                    usesCustomMeetingDate = true
                    return nil
                }
                if let schedule = AssistantCreation.deadline(text, today: today),
                   applyMeetingSchedule(date: schedule.date, time: schedule.time) { return nil }
                return "Уточните дату и время, например «завтра в 15:30»."
            }
            guard kind == .project || (kind == .task && field == .end) else { return "В этой карточке нет такого поля даты." }
            let schedule = AssistantCreation.deadline(text, today: today)
            guard value == nil || schedule != nil else { return "Не удалось определить дату. Назовите день и месяц." }
            let date = schedule?.date ?? ""
            if kind == .task {
                newTaskDueDate = date
                newTaskDueTime = schedule?.time ?? ""
            } else if field == .start {
                guard newProjectEnd.isEmpty || date.isEmpty || date <= newProjectEnd else { return "Начало позже срока завершения. Уточните дату." }
                newProjectStart = date
                pendingProjectDate = nil
            } else {
                guard newProjectStart.isEmpty || date.isEmpty || date >= newProjectStart else { return "Срок раньше начала проекта. Уточните дату." }
                newProjectEnd = date
                pendingProjectDate = nil
            }
        case .owner, .assignee:
            guard kind == .project || kind == .task else { return "Для встречи можно указать участников." }
            let matches = value == nil ? [] : creationPeople(matching: text)
            let person = matches.count == 1 ? matches.first : nil
            guard value == nil || person != nil else {
                return "Не удалось однозначно определить «" + text + "». Назовите имя и фамилию или выберите человека в карточке."
            }
            if kind == .project { newProjectOwnerID = person?.id; unresolvedProjectOwner = nil }
            else { newTaskAssigneeID = person?.id; unresolvedTaskAssignee = nil }
        case .participants:
            guard kind == .meeting else { return "Участников можно добавить в карточке совещания." }
            if value == nil { return nil }
            guard let ids = MeetingParticipantNames.resolve(text, matches: {
                creationPeople(matching: $0).map(\.id)
            }) else {
                return "Уточните имена участников или отметьте их в карточке."
            }
            newParticipants.formUnion(ids)
        case .description:
            if kind == .project { newProjectDescription = text }
            else if kind == .task { newTaskDescription = text }
            else { return "Здесь можно изменить название или текст решения." }
        case .priority:
            guard kind == .task else { return "Приоритет можно указать у задачи." }
            switch AssistantRequest.normalize(text) {
            case "низкий", "низкая": newTaskPriority = "low"
            case "обычный", "средний", "нормальный": newTaskPriority = "normal"
            case "высокий", "высокая", "важная": newTaskPriority = "high"
            case "критический", "критичная", "срочно": newTaskPriority = "critical"
            default: return "Укажите низкий, обычный, высокий или критический приоритет."
            }
        }
        return nil
    }

    @discardableResult
    private func applyMeetingSchedule(date: String, time: String?) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = meetingTimeZone
        formatter.dateFormat = "HH:mm"
        let time = time ?? formatter.string(from: .now)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        guard let scheduled = formatter.date(from: date + " " + time) else { return false }
        newMeetingDate = scheduled
        usesCustomMeetingDate = true
        return true
    }

    private var topbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                pageHeading
                Spacer(minLength: 8)
                if showsMeetingDirectory { meetingSearch }
                if selection == .dashboard { dashboardSearch }
                headerActions
            }
            VStack(alignment: .leading, spacing: 10) {
                if showsMeetingDirectory || selection == .dashboard {
                    ViewThatFits(in: .horizontal) {
                        HStack { pageHeading; Spacer(minLength: 8); headerActions }
                        VStack(alignment: .leading, spacing: 10) { pageHeading; headerActions }
                    }
                    if showsMeetingDirectory { meetingSearch }
                    else { dashboardSearch }
                } else {
                    pageHeading
                    headerActions
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, selection == .tasks ? 12 : 16)
        .background(palette.background)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.border).frame(height: 1) }
    }

    private var showsMeetingDirectory: Bool { selection == .meetings && selectedMeeting == nil }
    private var compactHeader: Bool { showsMeetingDirectory || selection == .dashboard }

    private var dashboardSearch: some View {
        HStack(spacing: 5) {
            PanelSearchField(placeholder: "Задачи, проекты, совещания…", query: $dashboardQuery,
                             focus: $dashboardSearchFocused)
            Button("⌘K") { dashboardSearchFocused = true }
                .font(.caption.monospaced())
                .buttonStyle(.plain)
                .keyboardShortcut("k", modifiers: .command)
                .accessibilityLabel("Перейти к поиску на главной")
                .padding(.trailing, 8)
        }
        .background(palette.surface, in: Capsule())
        .overlay { Capsule().strokeBorder(palette.border).allowsHitTesting(false) }
        .frame(width: 250)
    }

    private var meetingSearch: some View {
        HStack(spacing: 5) {
            PanelSearchField(placeholder: "Найти встречу…", query: $meetingFilters.query, focus: $meetingSearchFocused)
            Button("⌘K") { meetingSearchFocused = true }
                .font(.caption.monospaced())
                .buttonStyle(.plain)
                .keyboardShortcut("k", modifiers: .command)
                .accessibilityLabel("Перейти к поиску встреч")
                .padding(.trailing, 8)
        }
        .background(palette.surface, in: Capsule())
        .overlay { Capsule().strokeBorder(palette.border).allowsHitTesting(false) }
        .frame(width: 208)
    }

    private var pageHeading: some View {
        HStack(spacing: 12) {
            Button { navigationVisible.toggle() } label: {
                Image(systemName: "line.3.horizontal").font(.system(size: 20)).frame(width: 38, height: 38)
            }
            .accessibilityLabel(navigationVisible ? "Скрыть навигацию" : "Показать навигацию")
            if !compactHeader || !history.isEmpty {
                NavigationBackButton(action: goBack)
                    .disabled((history.isEmpty && inspectedApproval == nil) || model.saving)
            }
            if let meeting = selectedMeeting {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Совещания").font(.headline).foregroundStyle(palette.text)
                    if let schedule = meeting.scheduleLabel(in: meetingTimeZone) {
                        Label(schedule, systemImage: "calendar").font(.caption).foregroundStyle(palette.muted)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selection == .settings || selection == .glossary ? "VTASK  ›  \(sectionTitle)" :
                            showsMeetingDirectory ? "VTASK  ›  Совещания" : "VTASK · мой компьютер")
                        .font(.caption).foregroundStyle(palette.muted)
                    Text(project == nil ? sectionTitle : "Проекты")
                        .font(.system(size: selection == .tasks ? 28 : 32, weight: .bold)).tracking(-0.8)
                        .foregroundStyle(palette.text).lineLimit(1).accessibilityAddTraits(.isHeader)
                    if selection == .settings {
                        Text("Персонализируйте VTASK под свои задачи и рабочие процессы.")
                            .font(.callout).foregroundStyle(palette.muted)
                    } else if selection == .tasks {
                        Text("Задачи и договорённости по проектам и совещаниям.")
                            .font(.callout).foregroundStyle(palette.muted).lineLimit(1)
                            .frame(maxWidth: 340, alignment: .leading)
                    } else if showsMeetingDirectory {
                        Text("Все встречи, записи и результаты.")
                            .font(.callout).foregroundStyle(palette.muted)
                    } else if selection == .glossary {
                        Text("Термины и этапы работ для ваших проектов.")
                            .font(.callout).foregroundStyle(palette.muted)
                    } else if selection == .dashboard {
                        Text("Ключевые задачи, проекты и ближайшие события.")
                            .font(.callout).foregroundStyle(palette.muted)
                    } else if selection == .projectList || project != nil {
                        Text("Совещания, задачи и результаты по проектам.")
                            .font(.callout).foregroundStyle(palette.muted)
                    }
                }
            }
        }
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            if selection == .tasks { taskDirectorySearch }
            if showsMeetingDirectory {
                Button { beginCreation(.meeting) } label: {
                    Label("Создать встречу", systemImage: "plus")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 13).padding(.vertical, 7)
                        .background(Color(red: 0.40, green: 0.24, blue: 0.83), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .opacity(model.workspace == nil || model.saving ? 0.55 : 1)
                .disabled(model.workspace == nil || model.saving)
            }
            if let meeting = selectedMeeting {
                Button { editingMeeting = meeting } label: { Label("Участники", systemImage: "person.2") }
                    .buttonStyle(.bordered)
                    .disabled(model.saving || model.capture?.active?.meetingId == meeting.id)
            }
            Menu {
                ForEach(Creation.allCases.filter { $0 != .decision }) { kind in
                    Button(kind.rawValue) { beginCreation(kind) }
                        .disabled(model.workspace == nil || (project?.archived == true && (kind == .task || kind == .meeting)))
                }
                if compactHeader {
                    Menu("Тема интерфейса") { themeOptions }
                        .disabled(model.workspace == nil || model.saving)
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
            .disabled(projectEdit != nil)
            if !compactHeader {
                Menu {
                    themeOptions
                } label: {
                    Label(["light": "Светлая", "dark": "Тёмная"][model.workspace?.settings.theme ?? ""] ?? "Как в системе",
                          systemImage: "circle.lefthalf.filled").accessibilityLabel("Тема интерфейса")
                }
                .disabled(model.workspace == nil || model.saving)
            }
            Menu {
                Button("Открыть справку VTASK", action: openUserGuide)
                Button("Начать тур с Валли", action: startTour)
                    .disabled(!canStartTour)
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("Справка")
            .help("Справка и тур с Валли")
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
            .disabled(projectEdit != nil)
            .accessibilityLabel("Валли")
            .accessibilityValue(valliTakingNotes ? ValliState.takingNotes.title : "")
        }
        .controlSize(compactHeader ? .regular : .large)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var themeOptions: some View {
        ForEach([("system", "Как в системе"), ("light", "Светлая"), ("dark", "Тёмная")], id: \.0) { theme in
            Button {
                Task { await model.command(["op": "settings", "data": ["theme": theme.0]]) }
            } label: {
                if model.workspace?.settings.theme == theme.0 { Label(theme.1, systemImage: "checkmark") }
                else { Text(theme.1) }
            }
        }
    }

    private var canNavigateTour: Bool {
        model.workspace != nil && !model.saving && projectEdit == nil && taskDraftID == nil && creation == nil
    }

    private var canStartTour: Bool {
        canNavigateTour && model.capture?.active == nil && !assistantVoiceEnabled
    }

    private func startTour() {
        guard canStartTour else { return }
        assistantVisible = true
        showTourStep(.today)
    }

    private func openUserGuide() {
        let url = Bundle.main.url(forResource: "VTASK-user-guide", withExtension: "html")
            ?? Bundle.module.url(forResource: "VTASK-user-guide", withExtension: "html")
        showingHelpError = !(url.map { NSWorkspace.shared.open($0) } ?? false)
    }

    private func showTourStep(_ step: ValliTourStep) {
        guard canNavigateTour else { return }
        switch step {
        case .today: navigate(.dashboard)
        case .projects: navigate(.projectList)
        case .meetings: navigate(.meetings)
        case .approvals: openApprovals()
        case .glossary: openGlossary(.periods)
        case .settings:
            settingsArea = .general
            navigate(.settings)
        case .assistant: break
        }
        tourStep = step
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

    private var assistantDocked: Bool {
        tourStep != nil || liveMeetingID != nil || assistantEditsCreation || assistantVoiceEnabled
    }

    private let assistantWidth: CGFloat = 355

    private func pollAssistantLive(_ session: CaptureStatus.Session) async {
        guard let sessionID = session.sessionId else { return }
        while !Task.isCancelled {
            if let snapshot = try? await model.liveTranscript(for: session.meetingId),
               !Task.isCancelled, snapshot.sessionId == sessionID {
                let startedLive = assistantLive?.sessionId != sessionID
                assistantLive = snapshot
                if startedLive { assistantVisible = true }
            }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
        }
    }

    @ViewBuilder
    private var assistantDrawer: some View {
        if let workspace = model.workspace {
            ZStack(alignment: .trailing) {
                if !assistantDocked {
                    Color.black.opacity(0.16).contentShape(Rectangle()).onTapGesture { assistantVisible = false }
                }
                ZStack {
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
                                    openTask: { openTask($0) },
                                    openMeeting: openMeeting,
                                    openProject: { navigate(.project($0)) },
                                    openProposal: { proposal in
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
                                    prepareCreation: prepareAssistantCreation,
                                    creationConversation: creationConversation,
                                    updateCreation: updateAssistantCreation,
                                    finishCreation: confirmAssistantCreation,
                                    cancelCreation: cancelCreation,
                                    canUseMicrophone: model.capture?.active == nil && (creation == nil || assistantEditsCreation),
                                    meetingRecording: model.capture?.active != nil,
                                    liveSession: model.capture?.liveDisplay == true ? model.capture?.active : nil,
                                    captureActivity: model.captureActivity,
                                    voiceEnabled: $assistantVoiceEnabled,
                                    takingNotes: valliTakingNotes,
                                    liveTranscript: assistantLive,
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
                                    startTour: canStartTour ? startTour : nil,
                                    close: { assistantVisible = false })
                        .opacity(tourStep == nil ? 1 : 0)
                        .disabled(tourStep != nil)
                        .allowsHitTesting(tourStep == nil)
                        .accessibilityHidden(tourStep != nil)
                    if let tourStep {
                        ValliTourPanel(step: tourStep, canNavigate: canNavigateTour,
                                       canSpeak: model.capture?.active == nil && !assistantVoiceEnabled,
                                       showStep: showTourStep,
                                       close: { self.tourStep = nil })
                    }
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

    private var workspaceShell: some View {
        HStack(spacing: 0) {
            if navigationVisible && !assistantEditsCreation {
                sidebar
                Rectangle().fill(palette.border).frame(width: 1)
            }
            VStack(spacing: 0) {
                topbar
                recordingBanner
                if assistantEditsCreation, let kind = creation {
                    ScrollView {
                        creationForm(kind)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(12)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    workspaceLayout.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(palette.background)
            .padding(.trailing, assistantVisible && assistantDocked ? assistantWidth : 0)
            .overlay(alignment: .trailing) {
                if assistantVisible { assistantDrawer }
            }
        }
    }

    var body: some View {
        workspaceShell
        .onChange(of: assistantVisible) { visible in
            if !visible { tourStep = nil }
        }
        .onChange(of: model.capture?.active != nil) { recording in
            if recording { tourStep = nil }
        }
        .alert("Не удалось открыть справку", isPresented: $showingHelpError) {
            Button("OK", role: .cancel) {}
        }
        .task(id: scopedGlossaryKey) {
            let selection = activeTerminology
            let key = scopedGlossaryKey
            guard !selection.isEmpty else {
                scopedGlossary = []
                loadedGlossaryKey = nil
                return
            }
            do {
                let terms = try await model.scopedGlossary(for: selection)
                guard !Task.isCancelled, key == scopedGlossaryKey else { return }
                scopedGlossary = terms
                loadedGlossaryKey = key
            } catch {
                guard !Task.isCancelled, key == scopedGlossaryKey else { return }
                loadedGlossaryKey = nil
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
        .alert("В проекте есть несохранённые изменения", isPresented: Binding(
            get: { pendingProjectNavigation != nil },
            set: { if !$0 { pendingProjectNavigation = nil } }
        ), presenting: pendingProjectNavigation) { destination in
            Button("Продолжить редактирование", role: .cancel) {}
            Button("Выйти без сохранения", role: .destructive) { discardProjectEdit(and: destination) }
        } message: { _ in
            Text("Чтобы применить изменения, сохраните проект перед переходом.")
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
        .sheet(item: Binding(get: { assistantEditsCreation ? nil : creation },
                             set: { if !assistantEditsCreation { creation = $0 } })) { kind in
            creationForm(kind).frame(width: 420)
                .sheetCloseButton(disabled: model.saving)
        }
    }

    private func creationForm(_ kind: Creation) -> some View {
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
                if let date = pendingProjectDate {
                    Text("К какому полю относится дата " + ProjectDateField.display(date) + "?")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Начало") { newProjectStart = date; pendingProjectDate = nil }
                        Button("Завершение") { newProjectEnd = date; pendingProjectDate = nil }
                        Button("Пропустить") { pendingProjectDate = nil }
                    }
                }
                ProjectDateField(title: "Начало", value: $newProjectStart)
                ProjectDateField(title: "Срок завершения", value: $newProjectEnd)
            }
            if [.task, .meeting, .decision].contains(kind) {
                if let hint = creationProjectHint, creationProjectID == nil {
                    Text("Уточните проект «" + hint + "».").foregroundStyle(.secondary)
                }
                if let creationNewProjectName {
                    LabeledContent("Новый проект", value: creationNewProjectName)
                } else {
                    Picker("Проект", selection: $creationProjectID) {
                        Text(creationNeedsProject ? "Выберите проект" : "Без проекта").tag(nil as Int?)
                        ForEach(projects) { Text($0.title).tag(Optional($0.id)) }
                    }
                }
            }
            if [.project, .meeting].contains(kind), let workspace = model.workspace {
                let parent = kind == .meeting ? creationProjectID : nil
                IndustrySelectionField(options: workspace.industryOptions, specializations: workspace.specializationCatalog ?? [],
                    inheritedTitle: (parent == nil ? "Из настроек · " : "Из проекта · ")
                        + workspace.terminologyTitles(workspace.terminologySelection(projectID: parent)),
                    selection: $newIndustries)
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
                            Toggle(person.speakerPickerName, isOn: Binding(
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
            HStack {
                Spacer()
                Button("Отмена", action: cancelCreation)
                Button("Сохранить") { Task { await create(kind) } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(assistantEditsCreation ? nil : .defaultAction)
                    .disabled(!canSaveCreation(kind))
            }
        }
        .padding()
        .frame(maxWidth: 500)
        .disabled(model.saving || model.loading)
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
