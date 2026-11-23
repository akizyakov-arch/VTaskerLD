import SwiftUI

struct MeetingDirectoryFilters {
    enum Period: String, CaseIterable {
        case all = "Все даты"
        case week = "Эта неделя"
        case month = "Этот месяц"
        case previousMonth = "Прошлый месяц"

        func interval(in calendar: Calendar, today: Date) -> DateInterval? {
            switch self {
            case .all: return nil
            case .week: return calendar.dateInterval(of: .weekOfYear, for: today)
            case .month: return calendar.dateInterval(of: .month, for: today)
            case .previousMonth:
                return calendar.date(byAdding: .month, value: -1, to: today)
                    .flatMap { calendar.dateInterval(of: .month, for: $0) }
            }
        }
    }

    var query = ""
    var projectID: Int?
    var personID: Int?
    var period: Period = .all
    var showsCalendar = false
    var calendarDay: Date?

    var activeCount: Int {
        [projectID != nil, personID != nil, period != .all].filter { $0 }.count
    }

    mutating func reset() {
        projectID = nil
        personID = nil
        period = .all
    }
}

struct MeetingDirectory: View {
    let meetings: [Meeting]
    let projects: [Project]
    let people: [Person]
    let timeZone: TimeZone
    let capture: CaptureStatus.Session?
    @Binding var filters: MeetingDirectoryFilters
    let open: (Int) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var showingFilters = true

    private var palette: PanelPalette { PanelPalette(dark: scheme == .dark) }
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ru_RU")
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        return calendar
    }

    var body: some View {
        let calendar = calendar
        let query = filters.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let period = filters.period.interval(in: calendar, today: .now)
        let results = meetings.compactMap { meeting -> DatedMeeting? in
            guard filters.projectID == nil || meeting.projectId == filters.projectID,
                  filters.personID.map(meeting.participants.contains) ?? true,
                  query.isEmpty || [meeting.visibleTitle, meeting.title, meeting.protocolTitle, meeting.projectName]
                    .compactMap({ $0 }).contains(where: { $0.localizedStandardContains(query) }) else { return nil }
            let date = meeting.date
            if let period, !(date.map { $0 >= period.start && $0 < period.end } ?? false) { return nil }
            return DatedMeeting(meeting: meeting, date: date)
        }.sorted {
            let first = $0.date ?? .distantPast
            let second = $1.date ?? .distantPast
            return first == second ? $0.id > $1.id : first > second
        }
        VStack(spacing: 0) {
            toolbar
            ScrollView {
                LazyVStack(spacing: 8) {
                    if filters.showsCalendar {
                        let anchor = filters.calendarDay ?? results.first?.date ?? .now
                        let days = Dictionary(grouping: results.compactMap(\.date), by: calendar.startOfDay(for:))
                            .mapValues(\.count)
                        MeetingMonthPicker(calendar: calendar, anchor: anchor, counts: days) { filters.calendarDay = $0 }
                        let selected = results.filter { item in
                            item.date.map { calendar.isDate($0, inSameDayAs: anchor) } ?? false
                        }
                        if !results.isEmpty {
                            Text(anchor.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: timeZone)))
                                .font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        rows(selected, empty: results.isEmpty ? "Встречи не найдены" : "На этот день встреч нет")
                    } else {
                        rows(results, empty: "Встречи не найдены")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
            }
        }
    }

    private struct DatedMeeting: Identifiable {
        let meeting: Meeting
        let date: Date?
        var id: Int { meeting.id }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                showingFilters.toggle()
            } label: {
                Label(filters.activeCount == 0 ? "Фильтры" : "Фильтры · \(filters.activeCount)",
                      systemImage: "line.3.horizontal.decrease")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(palette.projectAccent)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(palette.projectAccent.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showingFilters ? "Развёрнуты" : "Свёрнуты")
            if showingFilters {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        filterMenu("Проект", projects.first { $0.id == filters.projectID }?.title ?? "Все проекты") {
                            Picker("Проект", selection: $filters.projectID) {
                                Text("Все проекты").tag(nil as Int?)
                                ForEach(projects) { Text($0.title).tag(Optional($0.id)) }
                            }
                            .pickerStyle(.inline)
                        }
                        filterMenu("Участник", people.first { $0.id == filters.personID }?.speakerPickerName ?? "Все участники") {
                            Picker("Участник", selection: $filters.personID) {
                                Text("Все участники").tag(nil as Int?)
                                ForEach(people) { Text($0.speakerPickerName).tag(Optional($0.id)) }
                            }
                            .pickerStyle(.inline)
                        }
                        filterMenu("Период", filters.period == .all ? nil : filters.period.rawValue) {
                            Picker("Период", selection: $filters.period) {
                                ForEach(MeetingDirectoryFilters.Period.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.inline)
                        }
                        if filters.activeCount > 0 {
                            Button("Сбросить") { filters.reset() }.buttonStyle(.link)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            } else {
                Spacer()
            }
            Picker("Вид совещаний", selection: $filters.showsCalendar) {
                Image(systemName: "list.bullet").accessibilityLabel("Список").tag(false)
                Image(systemName: "calendar").accessibilityLabel("Календарь").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 92)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private func filterMenu<Items: View>(_ title: String, _ value: String?,
                                         @ViewBuilder items: () -> Items) -> some View {
        Menu(content: items) {
            Text(value.map { title + ": " + $0 } ?? title).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 205)
        .fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(palette.surface, in: Capsule())
        .overlay { Capsule().strokeBorder(palette.border).allowsHitTesting(false) }
        .tint(palette.text)
        .accessibilityLabel(title)
        .accessibilityValue(value ?? "Все даты")
    }

    @ViewBuilder private func rows(_ results: [DatedMeeting], empty: String) -> some View {
        if results.isEmpty {
            Label(empty, systemImage: "video.slash").foregroundStyle(palette.muted).panelCard()
        }
        ForEach(results) { item in
            MeetingDirectoryRow(meeting: item.meeting, date: item.date, timeZone: timeZone,
                                capture: capture?.meetingId == item.id ? capture : nil,
                                palette: palette) { open(item.id) }
        }
    }
}

private struct MeetingDirectoryRow: View {
    let meeting: Meeting
    let date: Date?
    let timeZone: TimeZone
    let capture: CaptureStatus.Session?
    let palette: PanelPalette
    let open: () -> Void
    @State private var hovered = false

    private var status: (title: String, icon: String, color: Color) {
        if let capture {
            return capture.state == "paused"
                ? ("Пауза", "pause.circle", .orange)
                : ("Запись", "record.circle", palette.recordingInk)
        }
        if let job = meeting.processing {
            switch job.status {
            case "completed":
                return (job.label, job.icon, palette.dark ? Color.green : Color(red: 0.10, green: 0.43, blue: 0.21))
            case "failed":
                return (job.label, job.icon, job.cancelled ? palette.muted : palette.recordingInk)
            default: return (job.label, job.icon, palette.projectAccent)
            }
        }
        if !meeting.recordings.isEmpty { return ("Аудио сохранено", "waveform", palette.projectAccent) }
        if meeting.scheduledDate != nil { return ("Запланировано", "clock", palette.muted) }
        return ("Создано", "doc", palette.muted)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 13)
        let status = status
        let formatter = Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: timeZone)
        Button(action: open) {
            HStack(spacing: 14) {
                Image(systemName: "video")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(palette.projectAccent)
                    .frame(width: 46, height: 46)
                    .background(palette.projectAccent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.visibleTitle).font(.headline).foregroundStyle(palette.text).lineLimit(2)
                    Text(meeting.projectName ?? "Без проекта")
                        .font(.callout).foregroundStyle(palette.muted).lineLimit(1)
                    if let date {
                        Label(formatter.format(date), systemImage: "calendar")
                            .font(.caption).foregroundStyle(palette.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Label(status.title, systemImage: status.icon)
                    .lineLimit(2).font(.caption.weight(.medium))
                    .foregroundStyle(status.color)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(status.color.opacity(0.12), in: Capsule())
                    .frame(maxWidth: 136)
                Image(systemName: "chevron.right").font(.callout.weight(.medium))
                    .foregroundStyle(palette.muted).accessibilityHidden(true)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(hovered ? palette.selected : palette.surface, in: shape)
            .overlay { shape.strokeBorder(hovered ? palette.projectAccent : palette.border).allowsHitTesting(false) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct MeetingMonthPicker: View {
    let calendar: Calendar
    let anchor: Date
    let counts: [Date: Int]
    let select: (Date) -> Void

    var body: some View {
        if let month = calendar.dateInterval(of: .month, for: anchor),
           let first = calendar.dateInterval(of: .weekOfYear, for: month.start)?.start {
            let dayCount = calendar.dateComponents([.day], from: first, to: month.end).day ?? 0
            let columns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 4), count: 7)
            VStack(spacing: 8) {
                HStack {
                    Text(formatted(anchor, template: "LLLL yyyy"))
                        .font(.headline)
                    Spacer()
                    shiftButton(-1, icon: "chevron.left", label: "Предыдущий месяц")
                    Button("Сегодня") { select(.now) }
                    shiftButton(1, icon: "chevron.right", label: "Следующий месяц")
                }
                LazyVGrid(columns: columns, spacing: 4) {
                    let symbols = calendar.shortStandaloneWeekdaySymbols
                    ForEach(0..<7) { offset in
                        Text(symbols[(calendar.firstWeekday - 1 + offset) % 7])
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(0..<((dayCount + 6) / 7 * 7), id: \.self) { offset in
                        if let date = calendar.date(byAdding: .day, value: offset, to: first) {
                            dayButton(date, inMonth: date >= month.start && date < month.end)
                        }
                    }
                }
            }
            .panelCard()
        }
    }

    private func shiftButton(_ months: Int, icon: String, label: String) -> some View {
        Button {
            if let next = calendar.date(byAdding: .month, value: months, to: anchor) { select(next) }
        } label: {
            Image(systemName: icon)
        }
        .accessibilityLabel(label)
        .help(label)
    }

    private func dayButton(_ date: Date, inMonth: Bool) -> some View {
        let count = counts[calendar.startOfDay(for: date), default: 0]
        let selected = calendar.isDate(date, inSameDayAs: anchor)
        return Button { select(date) } label: {
            VStack(spacing: 2) {
                Text(calendar.component(.day, from: date), format: .number).font(.callout.monospacedDigit())
                if count > 0 {
                    Text(count, format: .number).font(.caption2).foregroundStyle(Color.accentColor)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 31)
            .foregroundStyle(inMonth || selected ? Color.primary : Color.secondary)
            .background(Color.accentColor.opacity(selected ? 0.19 : count > 0 ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(formatted(date, template: "d MMMM yyyy") + ", число встреч: \(count)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func formatted(_ date: Date, template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = calendar.locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.formattingContext = .beginningOfSentence
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}
