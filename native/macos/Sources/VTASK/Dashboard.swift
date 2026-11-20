import SwiftUI

enum TaskFilter: String, CaseIterable, Identifiable {
    case all = "Все"
    case active = "В работе"
    case today = "На сегодня"
    case overdue = "Просрочены"
    case undated = "Без срока"
    case done = "Выполнены"
    case cancelled = "Отменённые"
    case dueSoon = "Ближайшие 7 дней"
    case later = "Позже"

    var id: Self { self }

    func matches(_ task: TaskItem, today: String) -> Bool {
        switch self {
        case .all: return task.stageKind != "cancelled"
        case .active: return task.stageKind == "active"
        case .today: return task.stageKind == "active" && task.dueDate == today
        case .overdue: return task.overdue
        case .undated: return task.stageKind == "active" && task.dueDate == nil
        case .done: return task.stageKind == "done"
        case .cancelled: return task.stageKind == "cancelled"
        case .dueSoon, .later:
            guard task.stageKind == "active", !task.overdue, let due = task.dueDate else { return false }
            let format = Date.ISO8601FormatStyle().year().month().day().dateSeparator(.dash)
            guard let start = try? format.parse(today),
                  let boundary = Calendar(identifier: .iso8601).date(byAdding: .day, value: 7, to: start) else { return false }
            return self == .dueSoon ? due <= format.format(boundary) : due > format.format(boundary)
        }
    }
}

struct Dashboard: View {
    @Environment(\.colorScheme) private var scheme
    let tasks: [TaskItem]
    let projects: [Project]
    let people: [Person]
    let today: String
    let openTask: (Int) -> Void
    let showTasks: (TaskFilter) -> Void
    let showAssignee: (Int?) -> Void
    let myID: Int?
    let openProjects: () -> Void
    let openMeetings: () -> Void
    let openAssistant: () -> Void
    let meetings: [Meeting]
    let pending: [Proposal]
    let notifications: [TaskNotification]
    let openNotification: (TaskNotification) -> Void
    let openProject: (Int) -> Void
    let openMeeting: (Int) -> Void
    let openApprovals: () -> Void

    private var palette: PanelPalette { PanelPalette(dark: scheme == .dark) }
    private let columns = [GridItem(.adaptive(minimum: 166), spacing: 12, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(formattedToday).font(.callout).foregroundStyle(palette.muted)
                    Spacer(minLength: 8)
                    Button(action: openAssistant) { Label("Открыть помощника", systemImage: "sparkles") }
                        .buttonStyle(.link)
                        .font(.callout)
                }
                metrics
                if !notifications.isEmpty {
                    MeetingDisclosure(title: "Уведомления", icon: "bell",
                                      count: notifications.filter { $0.readAt == nil }.count) {
                        ForEach(notifications) { item in
                            dashboardRow(item.payload.title, icon: item.readAt == nil ? "bell.badge" : "bell",
                                         subtitle: item.label) { openNotification(item) }
                        }
                    }
                    .panelCard()
                }
                ScheduleView(tasks: tasks, projects: projects, people: people, today: today, openTask: openTask)
                    .panelCard()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                    deadlineChart
                    assigneeChart
                    focus
                    card("На подтверждение", icon: "tray", action: ("Все предложения", openApprovals)) {
                        if pending.isEmpty {
                            Text("Новых предложений нет.").foregroundStyle(palette.muted)
                        }
                        ForEach(pending.prefix(3)) { proposal in
                            dashboardRow(proposal.displayTitle, icon: proposal.presentation.icon, action: openApprovals)
                        }
                    }
                    card("Проекты", icon: "folder", action: ("Все проекты", openProjects)) {
                        if projects.isEmpty { Text("Нет проектов").foregroundStyle(.secondary) }
                        ForEach(projects.prefix(3)) { project in
                            let owner = people.first { $0.id == project.ownerId }?.name
                            let subtitle = [project.goal, owner].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                            dashboardRow(project.title, icon: "folder", subtitle: subtitle) {
                                openProject(project.id)
                            }
                        }
                    }
                    card("Совещания", icon: "video", action: ("Все встречи", openMeetings)) {
                        if meetings.isEmpty { Text("Нет совещаний").foregroundStyle(.secondary) }
                        ForEach(meetings.prefix(4)) { meeting in
                            let status = meeting.processing?.label ?? (meeting.recordings.isEmpty ? "Новая" : "Сохранено")
                            dashboardRow(meeting.title, icon: "video", subtitle: status) {
                                openMeeting(meeting.id)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1360)
            .frame(maxWidth: .infinity)
        }
    }

    private var formattedToday: String {
        let format = Date.ISO8601FormatStyle().year().month().day().dateSeparator(.dash)
        guard let day = try? format.parse(today) else { return today }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .medium
        return formatter.string(from: day)
    }

    private var metrics: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            metric("Мои задачи", icon: "person.crop.circle", count: tasks.filter { myID != nil && $0.assigneeId == myID && $0.stageKind == "active" }.count) {
                if let myID { showAssignee(myID) } else { showTasks(.active) }
            }
            metric("На сегодня", icon: "calendar", count: tasks.filter { TaskFilter.today.matches($0, today: today) }.count) { showTasks(.today) }
            metric("Просрочены", icon: "exclamationmark.clock", count: tasks.filter(\.overdue).count, overdue: true) { showTasks(.overdue) }
            metric("На подтверждение", icon: "tray", count: pending.count, action: openApprovals)
        }
    }

    private func metric(_ title: String, icon: String, count: Int, overdue: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    dashboardIcon(icon, overdue: overdue && count > 0)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.muted)
                        .accessibilityHidden(true)
                }
                Text(count, format: .number)
                    .font(.system(size: 29, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(overdue && count > 0 ? palette.recordingInk : palette.text)
                Text(title).font(.callout.weight(.medium)).foregroundStyle(palette.muted)
            }
            .panelCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func dashboardIcon(_ icon: String, overdue: Bool = false) -> some View {
        Image(systemName: icon)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(overdue ? palette.recordingInk : palette.selectedInk)
            .frame(width: 29, height: 29)
            .background(overdue ? palette.recordingSurface : palette.selected, in: RoundedRectangle(cornerRadius: 7))
            .accessibilityHidden(true)
    }

    private func dashboardRow(_ title: String, icon: String, subtitle: String = "", overdue: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                dashboardIcon(icon, overdue: overdue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.callout.weight(.medium)).lineLimit(2)
                        .foregroundStyle(overdue ? palette.recordingInk : palette.text)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(palette.muted).lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.muted)
                    .accessibilityHidden(true)
            }
            .padding(8)
            .background(palette.background, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func card<Content: View>(_ title: String, icon: String, action: (String, () -> Void)? = nil,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    cardHeading(title, icon: icon)
                    if let action {
                        Spacer(minLength: 8)
                        Button(action.0, action: action.1).buttonStyle(.link).font(.caption)
                    }
                }
                if let action {
                    VStack(alignment: .leading, spacing: 5) {
                        cardHeading(title, icon: icon)
                        Button(action.0, action: action.1).buttonStyle(.link).font(.caption)
                    }
                }
            }
            content()
        }
        .panelCard()
    }

    private func cardHeading(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            dashboardIcon(icon)
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
        }
    }

    private var deadlineChart: some View {
        let filters: [TaskFilter] = [.overdue, .dueSoon, .later, .undated]
        let counts = filters.map { filter in tasks.filter { filter.matches($0, today: today) }.count }
        return card("Сроки активных задач", icon: "clock") {
            ForEach(Array(filters.enumerated()), id: \.element) { index, filter in
                chartRow(filter.rawValue, count: counts[index], maximum: counts.max() ?? 0,
                         color: filter == .overdue ? palette.recordingInk : palette.accent) { showTasks(filter) }
            }
        }
    }

    private var assigneeChart: some View {
        let groups = Dictionary(grouping: tasks.filter { $0.stageKind == "active" }, by: \.assigneeId)
        let rows = groups.map { key, values in
            (id: key, name: people.first { $0.id == key }?.name ?? "Без исполнителя", count: values.count)
        }.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return card("Активные задачи по исполнителям", icon: "person.2") {
            if rows.isEmpty { Text("Активных задач нет").foregroundStyle(.secondary) }
            ForEach(rows, id: \.id) { row in
                chartRow(row.name, count: row.count, maximum: rows.first?.count ?? 0, color: palette.accent) {
                    showAssignee(row.id)
                }
            }
        }
    }

    private func chartRow(_ title: String, count: Int, maximum: Int, color: Color,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.callout)
                    Spacer()
                    Text(count, format: .number).font(.callout.monospacedDigit()).foregroundStyle(palette.muted)
                }
                GeometryReader { geometry in
                    Capsule().fill(color.opacity(0.14))
                    Capsule().fill(color).frame(width: geometry.size.width * Double(count) / Double(max(1, maximum)))
                }
                .frame(height: 5)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var focus: some View {
        let upcoming = tasks.filter { $0.stageKind == "active" && $0.dueDate != nil }
            .sorted { ($0.dueDate ?? "") < ($1.dueDate ?? "") }
        return card("В фокусе", icon: "scope", action: ("Все задачи", { showTasks(.all) })) {
            if upcoming.isEmpty {
                Text("Нет задач со сроком").foregroundStyle(.secondary)
            }
            ForEach(upcoming.prefix(5)) { task in
                dashboardRow(task.title, icon: task.overdue ? "exclamationmark.clock" : "calendar",
                             subtitle: [task.dueDate, task.dueTime].compactMap { $0 }.joined(separator: " "),
                             overdue: task.overdue) {
                    openTask(task.id)
                }
            }
        }

    }
}
