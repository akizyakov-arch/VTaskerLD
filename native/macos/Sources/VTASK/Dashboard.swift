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
    @AppStorage("favoriteProjectIDs") private var savedFavorites = ""
    @State private var focusMode: FocusMode?
    @State private var expandedFocus = false
    @State private var deadlineWindow = DeadlineWindow.week
    @State private var approvalsDismissed = false
    let tasks: [TaskItem]
    let projects: [Project]
    let people: [Person]
    let today: String
    let query: String
    let openTask: (Int) -> Void
    let showTasks: (TaskFilter) -> Void
    let showAssignee: (Int?) -> Void
    let myID: Int?
    let openProjects: () -> Void
    let openMeetings: () -> Void
    let meetings: [Meeting]
    let pending: [Proposal]
    let notifications: [TaskNotification]
    let openNotification: (TaskNotification) -> Void
    let openProject: (Int) -> Void
    let openMeeting: (Int) -> Void
    let openApprovals: () -> Void
    let openActiveProjects: () -> Void
    let createTask: () -> Void
    let createMeeting: () -> Void
    let createProject: () -> Void
    let openWorkPeriods: () -> Void
    let photoURL: (Person) -> URL?

    private var palette: PanelPalette { PanelPalette(dark: scheme == .dark) }
    private var activeTasks: [TaskItem] { tasks.filter { $0.stageKind == "active" } }
    private var problems: [TaskItem] { activeTasks.filter { $0.overdue || $0.blocked == true } }
    private var mine: [TaskItem] { activeTasks.filter { myID != nil && $0.assigneeId == myID } }
    private var favorites: Set<Int> { Set(savedFavorites.split(separator: ",").compactMap { Int($0) }) }
    private var currentProjects: [Project] {
        projects.filter(\.isCurrent).sorted {
            let first = favorites.contains($0.id), second = favorites.contains($1.id)
            if first != second { return first }
            if $0.status != $1.status { return $0.status == "active" }
            return ($0.updatedAt ?? "", $0.id) > ($1.updatedAt ?? "", $1.id)
        }
    }
    private var currentFocus: FocusMode { focusMode ?? (myID == nil ? .projects : .mine) }
    private let dateFormat = Date.ISO8601FormatStyle().year().month().day().dateSeparator(.dash)

    private enum FocusMode: String, CaseIterable {
        case mine = "Мои задачи", projects = "По проектам", problems = "Проблемные"
    }

    private enum DeadlineWindow: String, CaseIterable {
        case today = "Сегодня", week = "Неделя", month = "Месяц"
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        metrics(wide: geometry.size.width >= 760)
                        overview(width: geometry.size.width)
                        if !pending.isEmpty && !approvalsDismissed { approvalsBanner }
                        additionalSections
                    } else {
                        searchResults
                    }
                }
                .padding(20)
                .frame(maxWidth: 1360)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private func overview(width: CGFloat) -> some View {
        let wide = width >= 850
        let sideWidth = max(305, (min(1360, width) - 54) * 0.37)
        let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 14))
                          : AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
        return layout {
            VStack(spacing: 14) {
                focus
                projectCards(wide: wide)
            }
            .frame(maxWidth: .infinity)
            VStack(spacing: 14) {
                upcoming
                quickActions
            }
            .frame(width: wide ? sideWidth : nil)
            .frame(maxWidth: wide ? sideWidth : .infinity)
        }
    }

    private func metrics(wide: Bool) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: wide ? 4 : 2), spacing: 10) {
            metric("Просрочены", icon: "exclamationmark.triangle", count: tasks.filter(\.overdue).count, overdue: true) { showTasks(.overdue) }
            metric("Ближайшие сроки", icon: "calendar", count: tasks.filter { TaskFilter.dueSoon.matches($0, today: today) }.count) { showTasks(.dueSoon) }
            metric("Активные задачи", icon: "checkmark.circle", count: activeTasks.count) { showTasks(.active) }
            metric("Активные проекты", icon: "square.3.layers.3d", count: projects.filter { $0.status == "active" }.count,
                   action: openActiveProjects)
        }
    }

    private func metric(_ title: String, icon: String, count: Int, overdue: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                dashboardIcon(icon, overdue: overdue && count > 0)
                VStack(alignment: .leading, spacing: 3) {
                    Text(count, format: .number)
                        .font(.system(size: 26, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(palette.text)
                    Text(title).font(.caption.weight(.medium)).foregroundStyle(palette.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.muted).accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .panelCard(inset: 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func dashboardIcon(_ icon: String, overdue: Bool = false) -> some View {
        Image(systemName: icon)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(overdue ? palette.recordingInk : palette.projectAccent)
            .frame(width: 29, height: 29)
            .background(overdue ? palette.recordingSurface : palette.projectAccent.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 8))
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
        let candidates = switch currentFocus {
        case .mine: mine
        case .projects: activeTasks
        case .problems: problems
        }
        let ordered = candidates.sorted {
            if currentFocus == .projects && $0.projectId != $1.projectId {
                let left = projectTitle($0.projectId)
                let right = projectTitle($1.projectId)
                if left != right { return left.localizedStandardCompare(right) == .orderedAscending }
            }
            return byDueDate($0, $1)
        }
        return card("Фокус сегодня", icon: "scope") {
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    ForEach(FocusMode.allCases, id: \.self) { mode in
                        let selected = currentFocus == mode
                        Button { focusMode = mode; expandedFocus = false } label: {
                            HStack(spacing: 5) {
                                Text(mode.rawValue)
                                if mode != .projects {
                                    Text(mode == .mine ? mine.count : problems.count, format: .number)
                                        .font(.caption.monospacedDigit())
                                }
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(selected ? Color.white : palette.text)
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .background(selected ? Color(red: 0.40, green: 0.24, blue: 0.83)
                                        : palette.projectAccent.opacity(0.09), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.hidden)
            if currentFocus == .mine && myID == nil {
                Text("Выберите свой профиль в настройках.").font(.callout).foregroundStyle(palette.muted)
            } else if ordered.isEmpty {
                Text("В этой выборке нет задач.").font(.callout).foregroundStyle(palette.muted)
            }
            VStack(spacing: 5) {
                ForEach(ordered.prefix(expandedFocus ? ordered.count : 3)) { task in
                    focusRow(task)
                }
            }
            if ordered.count > 3 {
                Button {
                    expandedFocus.toggle()
                } label: {
                    Label(expandedFocus ? "Свернуть" : "Показать ещё \(ordered.count - 3)",
                          systemImage: expandedFocus ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    private func focusRow(_ task: TaskItem) -> some View {
        Button { openTask(task.id) } label: {
            HStack(spacing: 9) {
                Image(systemName: task.blocked == true ? "pause.circle" : "circle")
                    .foregroundStyle(task.overdue ? palette.recordingInk : palette.projectAccent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title).font(.callout.weight(.semibold)).foregroundStyle(palette.text).lineLimit(2)
                    Text(projectTitle(task.projectId) + " · " + task.stageTitle)
                        .font(.caption).foregroundStyle(palette.muted).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let label = dueLabel(task) {
                    Text(label)
                        .font(.caption.weight(.medium)).lineLimit(1)
                        .foregroundStyle(task.overdue ? palette.recordingInk : palette.projectAccent)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(task.overdue ? palette.recordingInk.opacity(0.10) : palette.projectAccent.opacity(0.09),
                                    in: Capsule())
                }
                if let person = people.first(where: { $0.id == task.assigneeId }) {
                    PersonAvatar(person: person, url: photoURL(person), size: 26)
                }
            }
            .padding(8)
            .background(task.overdue ? palette.recordingSurface : palette.background, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dueLabel(_ task: TaskItem) -> String? {
        if task.overdue { return "Просрочено" }
        if task.blocked == true { return "Блокировка" }
        guard let date = task.dueDate else { return nil }
        if date == today { return "Сегодня" }
        if let anchor = try? dateFormat.parse(today),
           let tomorrow = Calendar(identifier: .iso8601).date(byAdding: .day, value: 1, to: anchor),
           date == dateFormat.format(tomorrow) { return "Завтра" }
        return ProjectDateField.display(date)
    }

    private func projectTitle(_ id: Int?) -> String {
        projects.first { $0.id == id }?.title ?? "Без проекта"
    }

    private func byDueDate(_ first: TaskItem, _ second: TaskItem) -> Bool {
        (first.dueDate ?? "9999", first.dueTime ?? "", first.id) <
            (second.dueDate ?? "9999", second.dueTime ?? "", second.id)
    }

    private var upcoming: some View {
        let nearest = activeTasks.filter { task in
            guard let due = task.dueDate, !task.overdue else { return false }
            switch deadlineWindow {
            case .today: return due == today
            case .week: return TaskFilter.dueSoon.matches(task, today: today)
            case .month:
                guard let start = try? dateFormat.parse(today),
                      let limit = Calendar(identifier: .iso8601).date(byAdding: .month, value: 1, to: start) else { return false }
                return due >= today && due <= dateFormat.format(limit)
            }
        }.sorted(by: byDueDate)
        let overdue = activeTasks.filter(\.overdue).sorted(by: byDueDate).first
        let displayed = Array(([overdue].compactMap { $0 } + nearest).prefix(4))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                cardHeading("Ближайшие сроки", icon: "calendar")
                Spacer(minLength: 0)
                Picker("Период сроков", selection: $deadlineWindow) {
                    ForEach(DeadlineWindow.allCases, id: \.self) { item in Text(item.rawValue).tag(item) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if displayed.isEmpty {
                Text("На этот период нет сроков.").font(.callout).foregroundStyle(palette.muted)
            }
            ForEach(displayed) { task in
                Button { openTask(task.id) } label: {
                    HStack(spacing: 8) {
                        Text(shortDate(task.dueDate))
                            .font(.caption.weight(.medium)).foregroundStyle(palette.muted)
                            .frame(width: 49, alignment: .leading)
                        Rectangle().fill(palette.border).frame(width: 1, height: 26)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(task.title).font(.callout.weight(.semibold)).foregroundStyle(palette.text).lineLimit(2)
                            Text(projectTitle(task.projectId)).font(.caption).foregroundStyle(palette.muted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if task.overdue {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(palette.recordingInk)
                                .accessibilityLabel("Просрочено")
                        }
                    }
                    .padding(8)
                    .background(task.overdue ? palette.recordingSurface : palette.background, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .panelCard()
    }

    private func shortDate(_ value: String?) -> String {
        guard let value, let date = try? dateFormat.parse(value) else { return "" }
        let style = Date.FormatStyle().day().month(.abbreviated).locale(.current)
        var local = style
        local.timeZone = TimeZone(secondsFromGMT: 0)!
        return local.format(date)
    }

    private var quickActions: some View {
        card("Быстрые действия", icon: "bolt") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                quickAction("Создать задачу", icon: "plus", action: createTask)
                quickAction("Новая встреча", icon: "calendar.badge.plus", action: createMeeting)
                quickAction("Создать проект", icon: "folder", action: createProject)
                quickAction("Настроить этапы", icon: "square.3.layers.3d", action: openWorkPeriods)
            }
        }
    }

    private func quickAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                dashboardIcon(icon)
                Text(title).font(.callout.weight(.medium)).foregroundStyle(palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 47, alignment: .leading)
            .background(palette.projectAccent.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(palette.border).allowsHitTesting(false) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func projectCards(wide: Bool) -> some View {
        card("Проекты", icon: "square.3.layers.3d", action: ("Все проекты", openProjects)) {
            if currentProjects.isEmpty {
                Text("Нет актуальных проектов").font(.callout).foregroundStyle(palette.muted)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: wide ? 3 : 2),
                          alignment: .leading, spacing: 8) {
                    ForEach(currentProjects.prefix(3)) { project in
                        projectCard(project)
                    }
                }
            }
        }
    }

    private func projectCard(_ project: Project) -> some View {
        let work = tasks.filter { $0.projectId == project.id && $0.stageKind != "cancelled" }
        let trouble = problems.filter { $0.projectId == project.id }.count
        let progress = ProjectProgress.percent(work)
        let favorite = favorites.contains(project.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                dashboardIcon("folder")
                Spacer()
                Button {
                    var values = favorites
                    if favorite { values.remove(project.id) } else { values.insert(project.id) }
                    savedFavorites = values.sorted().map(String.init).joined(separator: ",")
                } label: {
                    Image(systemName: favorite ? "star.fill" : "star")
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.projectAccent)
                .accessibilityLabel((favorite ? "Убрать из избранного: " : "В избранное: ") + project.title)
            }
            Button { openProject(project.id) } label: {
                VStack(alignment: .leading, spacing: 7) {
                    Text(project.title).font(.callout.weight(.semibold)).foregroundStyle(palette.text).lineLimit(1)
                    ProjectStatusBadge(archived: false, status: project.status, palette: palette)
                    HStack(spacing: 6) {
                        ProjectProgress(value: progress)
                        Text("\(progress)%").font(.caption.monospacedDigit().weight(.semibold))
                    }
                    HStack(spacing: 6) {
                        Label(work.count.formatted(), systemImage: "checkmark.square")
                            .accessibilityLabel("Задач: \(work.count)")
                        if trouble > 0 {
                            Label(trouble.formatted(), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(palette.recordingInk)
                                .accessibilityLabel("Проблемных задач: \(trouble)")
                        }
                    }
                    .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(9)
        .background(palette.background, in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(favorite ? palette.projectAccent : palette.border).allowsHitTesting(false) }
    }

    private var approvalsBanner: some View {
        HStack(spacing: 10) {
            ValliAvatar(state: .needsReview, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text("Валли").font(.headline)
                let decisions = pending.filter { $0.kind == "decision" }.count
                Text("На согласовании · задачи: \(pending.count - decisions), решения: \(decisions)")
                    .font(.callout).foregroundStyle(palette.muted)
            }
            Spacer(minLength: 4)
            Button(action: openApprovals) {
                Text("Открыть согласование")
                    .font(.callout.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(Color(red: 0.40, green: 0.24, blue: 0.83), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                approvalsDismissed = true
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Скрыть подсказку Валли")
        }
        .panelCard(inset: 12)
    }

    private var additionalSections: some View {
        VStack(spacing: 10) {
            if !notifications.isEmpty {
                MeetingDisclosure(title: "Уведомления", icon: "bell", count: notifications.filter { $0.readAt == nil }.count) {
                    ForEach(notifications) { item in
                        dashboardRow(item.payload.title, icon: item.readAt == nil ? "bell.badge" : "bell",
                                     subtitle: item.label) { openNotification(item) }
                    }
                }
            }
            MeetingDisclosure(title: "Календарь и диаграмма Ганта", icon: "chart.bar.xaxis", count: nil) {
                ScheduleView(tasks: tasks, projects: projects, people: people, today: today, openTask: openTask)
            }
            MeetingDisclosure(title: "Аналитика задач", icon: "chart.bar", count: nil) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top) { deadlineChart; assigneeChart }
                    VStack { deadlineChart; assigneeChart }
                }
            }
            MeetingDisclosure(title: "Совещания", icon: "video", count: meetings.count) {
                Button("Все встречи", action: openMeetings).buttonStyle(.link)
                ForEach(meetings.prefix(4)) { meeting in
                    dashboardRow(meeting.visibleTitle, icon: "video", subtitle: meeting.projectName ?? "") {
                        openMeeting(meeting.id)
                    }
                }
            }
        }
    }

    private var searchResults: some View {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let foundTasks = tasks.filter {
            $0.stageKind != "cancelled" && ($0.title.localizedStandardContains(term)
                || $0.description?.localizedStandardContains(term) == true)
        }
        let foundProjects = projects.filter {
            $0.title.localizedStandardContains(term) || $0.description?.localizedStandardContains(term) == true
        }
        let foundMeetings = meetings.filter {
            $0.visibleTitle.localizedStandardContains(term) || $0.protocolTitle?.localizedStandardContains(term) == true
        }
        return VStack(spacing: 12) {
            if foundTasks.isEmpty && foundProjects.isEmpty && foundMeetings.isEmpty {
                Label("Ничего не найдено", systemImage: "magnifyingglass").foregroundStyle(palette.muted).panelCard()
            }
            if !foundTasks.isEmpty {
                card("Задачи", icon: "checklist") { ForEach(foundTasks, content: focusRow) }
            }
            if !foundProjects.isEmpty {
                card("Проекты", icon: "folder") {
                    ForEach(foundProjects) { item in dashboardRow(item.title, icon: "folder") { openProject(item.id) } }
                }
            }
            if !foundMeetings.isEmpty {
                card("Совещания", icon: "video") {
                    ForEach(foundMeetings) { item in dashboardRow(item.visibleTitle, icon: "video") { openMeeting(item.id) } }
                }
            }
        }

    }
}
