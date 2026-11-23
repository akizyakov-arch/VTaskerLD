import SwiftUI

struct ScheduleView: View {
    @Environment(\.colorScheme) private var scheme
    let tasks: [TaskItem]
    let projects: [Project]
    let people: [Person]
    let today: String
    let openTask: (Int) -> Void
    var showsGanttPicker = true
    @State private var gantt = false
    @State private var period: Period = .month
    @State private var selectedDate: Date?
    @State private var ganttPage = 0
    @State private var expandedGanttProjects: Set<Int?> = []
    private var palette: PanelPalette { PanelPalette(dark: scheme == .dark) }
    private let ganttDays = 28

    private enum Period: String, CaseIterable {
        case day = "День", week = "Неделя", month = "Месяц", year = "Год"
        var component: Calendar.Component {
            switch self {
            case .day: return .day
            case .week: return .weekOfYear
            case .month: return .month
            case .year: return .year
            }
        }
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var dateFormat: Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle().year().month().day().dateSeparator(.dash)
    }

    private var anchor: Date { selectedDate ?? (try? dateFormat.parse(today)) ?? .now }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsGanttPicker {
                Picker("Планирование", selection: $gantt) {
                    Label("Календарь задач", systemImage: "calendar").tag(false)
                    Label("Диаграмма Ганта", systemImage: "chart.bar.xaxis").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                Divider()
            }
            if gantt { ganttView } else { agenda }
        }
    }

    private func periodTitle(_ interval: DateInterval?) -> String {
        guard let interval else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = calendar.timeZone
        switch period {
        case .day: formatter.setLocalizedDateFormatFromTemplate("d MMMM yyyy")
        case .week: formatter.setLocalizedDateFormatFromTemplate("d MMM")
        case .month: formatter.setLocalizedDateFormatFromTemplate("LLLL yyyy")
        case .year: formatter.dateFormat = "yyyy"
        }
        let first = formatter.string(from: interval.start)
        if period == .week, let last = calendar.date(byAdding: .day, value: -1, to: interval.end) {
            return first + " — " + formatter.string(from: last)
        }
        return first
    }

    private var agenda: some View {
        let interval = calendar.dateInterval(of: period.component, for: anchor)
        let dates = Dictionary(grouping: tasks.filter { task in
            guard task.stageKind != "cancelled", let due = task.dueDate,
                  let day = try? dateFormat.parse(due), let interval else { return false }
            return day >= interval.start && day < interval.end
        }, by: { $0.dueDate ?? "" })
        return VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    calendarHeading(interval)
                    Spacer(minLength: 8)
                    calendarControls
                }
                VStack(alignment: .leading, spacing: 8) {
                    calendarHeading(interval)
                    calendarControls
                }
            }
            if let interval, period == .week || period == .month {
                calendarGrid(interval: interval, tasksByDay: dates)
            } else if let interval, period == .year {
                yearGrid(interval: interval, tasksByDay: dates)
            } else {
                let scheduled = dates.values.flatMap { $0 }
                if scheduled.isEmpty {
                    Text("На этот день задач со сроком нет.").foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(scheduled.prefix(4)) { task in taskRow(task, compact: true) }
                        if scheduled.count > 4 { moreTasks(Array(scheduled.dropFirst(4))) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func calendarHeading(_ interval: DateInterval?) -> some View {
        Text(periodTitle(interval)).font(.title3.bold()).accessibilityAddTraits(.isHeader)
    }

    private var calendarControls: some View {
        HStack(spacing: 6) {
            Picker("Период", selection: $period) {
                ForEach(Period.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Предыдущий период")
            Button("Сегодня") { selectedDate = nil }
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("Следующий период")
        }
        .buttonStyle(.bordered)
    }

    private func calendarGrid(interval: DateInterval, tasksByDay: [String: [TaskItem]]) -> some View {
        let start = calendar.dateInterval(of: .weekOfYear, for: interval.start)?.start ?? interval.start
        let count = calendar.dateComponents([.day], from: start, to: interval.end).day ?? 7
        let days = ((count + 6) / 7) * 7
        let columns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 3), count: 7)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 3) {
            ForEach(["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"], id: \.self) { day in
                Text(day).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            ForEach(0..<days, id: \.self) { offset in
                if let day = calendar.date(byAdding: .day, value: offset, to: start) {
                    let key = dateFormat.format(day)
                    let inPeriod = day >= interval.start && day < interval.end
                    let scheduled = tasksByDay[key] ?? []
                    let previewCount = period == .week ? 3 : 1
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 2) {
                            Text(calendar.component(.day, from: day), format: .number)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(key == today ? palette.selectedInk : inPeriod ? palette.text : palette.muted)
                                .accessibilityLabel(key)
                            Spacer(minLength: 0)
                            if scheduled.count > previewCount {
                                moreTasks(Array(scheduled.dropFirst(previewCount)))
                            }
                        }
                        ForEach(scheduled.prefix(previewCount)) { task in
                            taskRow(task, compact: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 3)
                                .background(
                                    task.overdue ? palette.recordingSurface
                                        : task.stageKind == "done" ? Color.green.opacity(0.16) : palette.selected,
                                    in: RoundedRectangle(cornerRadius: 4)
                                )
                        }
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, minHeight: period == .week ? 88 : 46, alignment: .topLeading)
                    .background(key == today ? palette.accent.opacity(0.10) : palette.background,
                                in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(key == today ? palette.accent : palette.border)
                        .allowsHitTesting(false))
                }
            }
        }
    }

    private func yearGrid(interval: DateInterval, tasksByDay: [String: [TaskItem]]) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 4)
        let monthly = Dictionary(grouping: tasksByDay.keys, by: { String($0.prefix(7)) })
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "LLLL"
        return LazyVGrid(columns: columns, spacing: 5) {
            ForEach(0..<12) { index in
                if let month = calendar.date(byAdding: .month, value: index, to: interval.start) {
                    let key = String(dateFormat.format(month).prefix(7))
                    let count = (monthly[key] ?? []).reduce(0) { $0 + (tasksByDay[$1]?.count ?? 0) }
                    Button {
                        selectedDate = month
                        period = .month
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(formatter.string(from: month)).lineLimit(1)
                            Text("Задач: \(count)").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(palette.background, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func moreTasks(_ tasks: [TaskItem]) -> some View {
        Menu {
            ForEach(tasks) { task in
                Button(task.title) { openTask(task.id) }
            }
        } label: {
            Text("+\(tasks.count)").font(.caption2.monospacedDigit()).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Ещё задач: \(tasks.count)")
    }

    private func shift(_ step: Int) {
        selectedDate = calendar.date(byAdding: period.component, value: step, to: anchor)
    }

    private var ganttView: some View {
        let currentDay = (try? dateFormat.parse(today)) ?? .now
        let monday = calendar.dateInterval(of: .weekOfYear, for: currentDay)?.start ?? currentDay
        let start = ganttDate(ganttPage * ganttDays - 7, from: monday)
        let todayOffset = offset(today, from: start)
        let scheduled = tasks.filter {
            $0.stageKind == "active" && offset($0.dueDate, from: start).map { (0..<ganttDays).contains($0) } == true
        }
        let byProject = Dictionary(grouping: scheduled, by: \.projectId)
        return VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    ganttHeading(start)
                    Spacer(minLength: 8)
                    ganttControls
                }
                VStack(alignment: .leading, spacing: 8) {
                    ganttHeading(start)
                    ganttControls
                }
            }
            HStack(spacing: 14) {
                Label("Срок проекта", systemImage: "rectangle.fill").foregroundStyle(palette.accent)
                Label("Дедлайн задачи", systemImage: "diamond.fill").foregroundStyle(palette.text)
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
            if projects.isEmpty && byProject[nil] == nil {
                Text("На этот период нет проектов и задач со сроком.").foregroundStyle(.secondary)
            } else {
                ganttScale(start: start, todayOffset: todayOffset)
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(projects) { project in
                            ganttGroup(project, tasks: byProject[project.id] ?? [], start: start, todayOffset: todayOffset)
                        }
                        if let unassigned = byProject[nil] {
                            ganttGroup(nil, tasks: unassigned, start: start, todayOffset: todayOffset)
                        }
                    }
                }
                .frame(height: 305)
            }
        }
    }

    private func ganttHeading(_ start: Date) -> some View {
        Text("\(ganttLabel(start)) – \(ganttLabel(ganttDate(ganttDays - 1, from: start), includesYear: true))")
            .font(.title3.bold())
            .accessibilityAddTraits(.isHeader)
    }

    private var ganttControls: some View {
        HStack(spacing: 6) {
            Button { ganttPage -= 1 } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Предыдущие четыре недели")
            Button("Сегодня") { ganttPage = 0 }
            Button { ganttPage += 1 } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("Следующие четыре недели")
        }
        .buttonStyle(.bordered)
    }

    private func ganttScale(start: Date, todayOffset: Int?) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<4) { week in
                let days = (week * 7)..<(week * 7 + 7)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ganttLabel(ganttDate(days.lowerBound, from: start)))
                        .lineLimit(1)
                    if let todayOffset, days.contains(todayOffset) {
                        Text("Сегодня").foregroundStyle(palette.accent)
                    } else {
                        Text(" ").accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 5)
                .overlay(alignment: .leading) { Rectangle().fill(palette.border).frame(width: 1) }
            }
        }
        .font(.caption)
        .foregroundStyle(palette.muted)
        .accessibilityElement(children: .combine)
    }

    private func ganttGroup(_ project: Project?, tasks: [TaskItem], start: Date, todayOffset: Int?) -> some View {
        let id = project?.id
        let expanded = expandedGanttProjects.contains(id)
        let first = project?.startDate
        let last = project?.endDate
        let dates = ganttProjectDates(first: first, last: last)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                if expanded { expandedGanttProjects.remove(id) }
                else { expandedGanttProjects.insert(id) }
            } label: {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .accessibilityHidden(true)
                        Label(project?.title ?? "Без проекта", systemImage: "folder")
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if project != nil {
                            Text(dates).font(.caption.monospacedDigit()).foregroundStyle(palette.muted)
                                .lineLimit(1)
                        }
                    }
                    ganttTrack(todayOffset: todayOffset, first: offset(first, from: start), last: offset(last, from: start))
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Развёрнуто" : "Свёрнуто")
            if expanded {
                if tasks.isEmpty {
                    Text("Нет активных задач со сроком в этом периоде.").font(.caption).foregroundStyle(palette.muted)
                }
                ForEach(tasks) { task in
                    Button { openTask(task.id) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(task.title).font(.callout.weight(.medium)).lineLimit(2)
                                Spacer(minLength: 8)
                                Text([task.dueDate, task.dueTime].compactMap { $0 }.joined(separator: " "))
                                    .font(.caption.monospacedDigit())
                            }
                            .foregroundStyle(task.overdue ? palette.recordingInk : palette.text)
                            Text(people.first { $0.id == task.assigneeId }?.name ?? "Без исполнителя")
                                .font(.caption).foregroundStyle(palette.muted)
                            ganttTrack(todayOffset: todayOffset, last: offset(task.dueDate, from: start),
                                       taskColor: task.overdue ? palette.recordingInk : palette.text)
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
        }
    }

    private func ganttDate(_ day: Int, from start: Date) -> Date {
        calendar.date(byAdding: .day, value: day, to: start) ?? start
    }

    private func ganttLabel(_ date: Date, includesYear: Bool = false) -> String {
        var format = Date.FormatStyle().day().month(.abbreviated)
        if includesYear { format = format.year() }
        format.locale = Locale(identifier: "ru_RU")
        format.timeZone = calendar.timeZone
        return format.format(date)
    }

    private func ganttProjectDates(first: String?, last: String?) -> String {
        switch (first, last) {
        case let (first?, last?): return first + " – " + last
        case let (first?, nil): return "Начало " + first
        case let (nil, last?): return "До " + last
        case (nil, nil): return "Сроки не заданы"
        }
    }

    private func offset(_ value: String?, from start: Date) -> Int? {
        guard let value, let day = try? dateFormat.parse(value) else { return nil }
        return calendar.dateComponents([.day], from: start, to: day).day
    }

    private func ganttTrack(todayOffset: Int?, first: Int? = nil, last: Int?, taskColor: Color? = nil) -> some View {
        GeometryReader { geometry in
            let dayWidth = geometry.size.width / CGFloat(ganttDays)
            let start = max(0, first ?? last ?? ganttDays)
            let end = min(ganttDays - 1, last ?? first ?? -1)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(palette.background)
                ForEach(0..<4) { week in
                    Rectangle().fill(palette.border).frame(width: 1)
                        .offset(x: CGFloat(week * 7) * dayWidth)
                }
                if start <= end {
                    if let taskColor {
                        Image(systemName: "diamond.fill").font(.system(size: 8))
                            .foregroundStyle(taskColor)
                            .position(x: (CGFloat(start) + 0.5) * dayWidth, y: geometry.size.height / 2)
                    } else {
                        Capsule().fill(palette.accent)
                            .frame(width: CGFloat(end - start + 1) * dayWidth, height: 6)
                            .offset(x: CGFloat(start) * dayWidth)
                    }
                }
                if let todayOffset, (0..<ganttDays).contains(todayOffset) {
                    Rectangle().fill(palette.accent).frame(width: 1)
                        .offset(x: (CGFloat(todayOffset) + 0.5) * dayWidth)
                }
            }
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }

    private func taskRow(_ task: TaskItem, compact: Bool = false) -> some View {
        Button { openTask(task.id) } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(task.stageKind == "done" ? "✅ " + task.title : task.title)
                    .font(compact ? .caption2 : .body)
                    .lineLimit(compact ? 1 : nil)
                    .foregroundStyle(task.overdue ? palette.recordingInk : palette.text)
                Text(people.first { $0.id == task.assigneeId }?.name ?? "Без исполнителя")
                    .font(compact ? .caption2 : .caption).lineLimit(compact ? 1 : nil)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
