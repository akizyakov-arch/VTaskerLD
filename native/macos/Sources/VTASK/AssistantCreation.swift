import Foundation

enum Creation: String, CaseIterable, Identifiable {
    case project = "Новый проект"
    case task = "Новая задача"
    case meeting = "Новое совещание"
    case decision = "Новое решение"
    case person = "Новый участник"

    var id: Self { self }
}

enum AssistantRequest {
    private static let searchPrefix = #"^(?:(?:валли|а|пожалуйста|можешь|можете|мне)[\s,:]+)*(?:покажи(?:те)?|найди(?:те)?|выведи(?:те)?)\b"#

    static func isSearchRequest(_ text: String) -> Bool {
        normalize(text).range(of: searchPrefix, options: .regularExpression) != nil
    }

    static func searchAndAssignment(_ text: String) -> (title: String, assignee: String, deadline: String?)? {
        let text = normalize(text)
        guard let prefix = text.range(of: searchPrefix, options: .regularExpression) else { return nil }
        let rest = String(text[prefix.upperBound...]).trimmingCharacters(in: .whitespaces)
        let verb = #"\s+(?:и\s+)?(?:назначь(?:те)?|назначить|поручи(?:те)?)\b"#
        guard let action = rest.range(of: verb, options: .regularExpression) else { return nil }
        let title = String(rest[..<action.lowerBound]).replacingOccurrences(
            of: #"^(?:задач[ауи]|поручение)\s+"#, with: "", options: .regularExpression)
        guard !title.isEmpty else { return nil }
        let changes = String(rest[action.upperBound...]).replacingOccurrences(
            of: #"^\s*(?:(?:ее|задачу|исполнителя)(?:\s+|$))*"#, with: "", options: .regularExpression)
        guard let date = changes.range(of: #"(?:^|\s+)(?:на|к|до)\s+(?=\S)"#,
                                       options: .regularExpression) else {
            return (title, clean(changes), nil)
        }
        return (title, clean(String(changes[..<date.lowerBound])), clean(String(changes[date.upperBound...])))
    }

    static func assignmentDeadline(_ text: String, today: String) -> String? {
        let parsed = AssistantTaskFilters.parse(text, today: today)
        if case .dates(let dates) = parsed.filters.deadline, dates.lowerBound == dates.upperBound,
           parsed.remaining.trimmingCharacters(in: .whitespaces).isEmpty {
            return dates.lowerBound
        }
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        guard let day = Int(digits), (1...31).contains(day),
              ["", "-е", "е", " число", "-е число", "е число"].contains(String(text.dropFirst(digits.count))) else {
            return nil
        }
        let iso = Date.ISO8601FormatStyle().year().month().day().dateSeparator(.dash)
        guard let reference = try? iso.parse(today) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        guard let month = calendar.dateInterval(of: .month, for: reference)?.start else { return nil }
        for offset in 0...2 {
            guard let start = calendar.date(byAdding: .month, value: offset, to: month) else { continue }
            var parts = calendar.dateComponents([.year, .month], from: start)
            parts.day = day
            if parts.isValidDate(in: calendar), let date = calendar.date(from: parts), date >= reference {
                return iso.format(date)
            }
        }
        return nil
    }

    static func isCreationRequest(_ text: String) -> Bool {
        var command = normalize(text)
        if command.hasPrefix("по задаче #") || command.hasPrefix("задача #"),
           let separator = command.firstIndex(of: ":") {
            command = normalize(String(command[command.index(after: separator)...]))
        }
        let pattern = #"^(?:(?:валли|пожалуйста|давай|давайте|можно|можешь|мне|хочу|нужно|надо)[\s,:]+)*(?:созда\w*|добав\w*|организу\w*|запланиру\w*|нов\w+\s+(?:проект|задач|решени|совещани)|(?:начни|запусти)\s+(?:нов\w+\s+)?(?:совещани|встреч|запис))"#
        return command.range(of: pattern, options: .regularExpression) != nil
    }

    static func normalize(_ text: String) -> String {
        clean(text).lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "«»“”\":,.!?")))
    }
}

enum TaskCommandScope: Equatable {
    case project(Int)
    case unassigned

    init?(projectID: Int?, task: TaskItem?) {
        if let task {
            self = task.projectId.map(Self.project) ?? .unassigned
        } else if let projectID {
            self = .project(projectID)
        } else {
            return nil
        }
    }

    var projectID: Int? {
        if case .project(let id) = self { return id }
        return nil
    }

    static func tasks(_ tasks: [TaskItem], in scope: Self?) -> [TaskItem] {
        guard let scope else { return tasks }
        return tasks.filter { $0.projectId == scope.projectID }
    }
}

enum AssistantTaskStatus {
    static func target(in text: String) -> String? {
        let text = AssistantRequest.normalize(text)
        let pattern = #"^(?:валли[\s,:]+)?(?:поменяй(?:те)?|смени(?:те)?|измени(?:те)?|поставь(?:те)?|установи(?:те)?)\s+статус(?:\s+задачи)?\b[\s,:]*(?:на\b\s*)?"#
        guard let prefix = text.range(of: pattern, options: .regularExpression) else { return nil }
        return AssistantRequest.normalize(String(text[prefix.upperBound...]))
    }

    static func movePhrase(in text: String) -> String? {
        let text = AssistantRequest.normalize(text)
        let pattern = #"^(?:валли[\s,:]+)?(?:перенеси(?:те)?|переведи(?:те)?|перемести(?:те)?)\s+задачу\b[\s,:]*"#
        guard let prefix = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[prefix.upperBound...])
    }

    static func destinations(in phrase: String) -> [(name: String, target: String)] {
        let expression = try! NSRegularExpression(pattern: #"(?<!\S)(?:в\s+статус|(?:на\s+)+(?=\S)|в(?=\s))"#)
        return expression.matches(in: phrase, range: NSRange(phrase.startIndex..., in: phrase)).reversed()
            .compactMap { match in
                guard let range = Range(match.range, in: phrase) else { return nil }
                let name = AssistantRequest.normalize(String(phrase[..<range.lowerBound]))
                let suffix = AssistantRequest.normalize(String(phrase[range.lowerBound...]))
                let target = suffix.hasPrefix("в статус")
                    ? AssistantRequest.normalize(String(phrase[range.upperBound...])) : suffix
                return (name, target)
            }
    }

    static func matches(_ target: String, stages: [Stage]) -> [Stage] {
        let normalized = AssistantRequest.normalize(target)
        let cleaned = normalized.replacingOccurrences(of: #"^(?:на\s+)+"#, with: "", options: .regularExpression)
        let exact = stages.filter {
            let title = AssistantRequest.normalize($0.title)
            return title == normalized || title == cleaned || title == "на " + cleaned
        }
        if !exact.isEmpty { return exact }
        switch cleaned {
        case "выполнено", "завершено", "выполнена", "завершена", "готово":
            return stages.filter { $0.kind == "done" }
        case "отменена", "отменено":
            return stages.filter { $0.kind == "cancelled" }
        case "в работу", "в работе":
            return stages.filter { $0.id == "doing" }
        case "на проверку", "на проверке", "проверку", "проверке":
            return stages.filter { $0.id == "review" }
        default:
            return []
        }
    }
}

struct AssistantIntent: Decodable {
    enum Action: String, Decodable {
        case searchTasks = "search_tasks"
        case refineTasks = "refine_tasks"
        case listProjects = "list_projects"
        case openProject = "open_project"
        case updateTask = "update_task"
        case clarify
    }

    let action: Action
    let title: String?
    let project: String?
    let assignee: String?
    let filters: String?
    let dueDate: String?
    let dueTime: String?
}

struct AssistantTaskUpdate {
    var dueDate: String?
    var dueTime: String?
    var assignee: String?

    init(dueDate: String?, assignee: String?) {
        self.dueDate = dueDate
        self.assignee = assignee
    }

    init(_ intent: AssistantIntent) {
        func cleaned(_ value: String?) -> String? {
            let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        }
        dueDate = cleaned(intent.dueDate)
        dueTime = cleaned(intent.dueTime)
        assignee = cleaned(intent.assignee)
    }

    var fields: [String: String] {
        ["due_date": dueDate, "due_time": dueDate == nil ? nil : dueTime, "assignee": assignee].compactMapValues { $0 }
    }

    func correctedDay(in text: String) -> String? {
        guard let dueDate,
              let match = text.range(of: #"^(?:да,?\s+)?(?:только\s+)?на\s+"#, options: .regularExpression) else {
            return nil
        }
        let dayText = String(text[match.upperBound...]).trimmingCharacters(in: .punctuationCharacters)
        let ordinal = ["первое", "второе", "третье", "четвертое", "пятое",
                       "шестое", "седьмое", "восьмое", "девятое", "десятое"]
        guard let day = Int(dayText) ?? ordinal.firstIndex(of: dayText).map({ $0 + 1 }) else { return nil }
        let parts = dueDate.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        let candidate = DateComponents(year: parts[0], month: parts[1], day: day)
        guard candidate.isValidDate(in: calendar) else { return nil }
        return String(format: "%04d-%02d-%02d", parts[0], parts[1], day)
    }

    var preview: String {
        var parts: [String] = []
        if let dueDate {
            let iso = Date.ISO8601FormatStyle().year().month().day().dateSeparator(.dash)
            let formatter = DateFormatter()
            formatter.timeZone = .gmt
            formatter.setLocalizedDateFormatFromTemplate("d MMMM yyyy")
            let label = (try? iso.parse(dueDate)).map(formatter.string(from:)) ?? dueDate
            parts.append([label, dueTime].compactMap { $0 }.joined(separator: " "))
        }
        if let assignee { parts.append(assignee) }
        return parts.joined(separator: " · ")
    }
}
