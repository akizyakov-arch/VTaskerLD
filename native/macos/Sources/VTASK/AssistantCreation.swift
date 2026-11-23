import Foundation

enum Creation: String, CaseIterable, Identifiable {
    case project = "Новый проект"
    case task = "Новая задача"
    case meeting = "Новое совещание"
    case decision = "Новое решение"
    case person = "Новый участник"

    var id: Self { self }
}

struct AssistantCreation {
    let kind: Creation
    var title: String
    var projectName: String? = nil
    var assignee: String? = nil
    var description: String? = nil
    var dueDate: String? = nil
    var dueTime: String? = nil
    var useCurrentMeetingTime = false
    var priority: String? = nil
    var projectFields: AssistantProjectFields? = nil

    private static let prefix = #"^(?:(?:валли|пожалуйста|давай|давайте|можно|можешь|можете|мне|хочу|нужно|надо|а)[\s,:]+)*(?:(?:создай(?:те)?|создать|добавь(?:те)?|добавить|организуй(?:те)?|запланируй(?:те)?|запланировать|зафиксируй(?:те)?|запиши(?:те)?|начни(?:те)?|начать|запусти(?:те)?|проведи(?:те)?)\s+(?:нов(?:ый|ую|ое)\s+)?|нов(?:ый|ую|ое)\s+)(проект|задач[ау]|поручение|решение|совещание|встреч[ау]|план[её]рк[ау])\b[\s,:]*"#

    static func parse(_ text: String, today: String) -> Self? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let regex = try! NSRegularExpression(pattern: prefix, options: .caseInsensitive)
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let entity = Range(match.range(at: 1), in: text), let command = Range(match.range, in: text) else {
            return nil
        }
        let kind: Creation
        switch AssistantRequest.normalize(String(text[entity])) {
        case "проект": kind = .project
        case "задачу", "задача", "поручение": kind = .task
        case "решение": kind = .decision
        default: kind = .meeting
        }
        let body = clean(String(text[command.upperBound...]))
        if kind == .project {
            let project = AssistantProjectFields.parse(body, today: today)
            return Self(kind: kind, title: project.fields.name ?? project.title,
                        description: project.fields.description, projectFields: project.fields)
        }
        var draft = Self(kind: kind, title: body)
        if kind == .meeting,
           let now = draft.title.range(of: #"(?:^|\s+)(?:на\s+)?(?:прямо\s+)?сейчас$"#,
                                       options: [.regularExpression, .caseInsensitive]) {
            draft.title = clean(String(draft.title[..<now.lowerBound]))
            draft.useCurrentMeetingTime = true
        }
        if kind == .task {
            if let value = tail(in: draft.title, pattern: #"\s+(?:исполнитель|ответственн[а-яё]+)\s*:?\s+"#) {
                draft.assignee = value.after
                draft.title = value.before
            }
        }
        if kind == .task || kind == .meeting,
           let value = tail(in: draft.title, pattern: #"(?:^|\s+)(?:на|срок(?:\s+до)?|дата)\s+"#),
           let schedule = deadline(value.after, today: today) {
            draft.title = value.before
            draft.dueDate = schedule.date
            draft.dueTime = schedule.time
        }
        let context = #"(?:^|\s+)(?:в\s+этом|по\s+этому|для\s+этого|в\s+текущем|по\s+текущему)\s+проект(?:е|у|а)\s*$"#
        if let range = draft.title.range(of: context, options: [.regularExpression, .caseInsensitive]) {
            draft.title = clean(String(draft.title[..<range.lowerBound]))
        } else if let value = tail(in: draft.title, pattern: #"(?:^|\s+)(?:(?:в|по|для|к)\s+проект(?:е|у|а)?|проект)\s*[«"]?\s*[: ]\s*"#) {
            draft.title = value.before
            draft.projectName = value.after
        }
        return draft
    }

    private static func tail(in text: String, pattern: String) -> (before: String, after: String)? {
        let regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        guard let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let range = Range(match.range, in: text) else { return nil }
        let value = clean(String(text[range.upperBound...]))
        guard !value.isEmpty else { return nil }
        return (clean(String(text[..<range.lowerBound])), value)
    }

    static func isImmediateMeeting(_ text: String) -> Bool {
        ["сейчас", "прямо сейчас", "на сейчас", "сейчас же", "текущее время"]
            .contains(AssistantRequest.normalize(text))
    }

    static func deadline(_ text: String, today: String) -> (date: String, time: String?)? {
        let text = AssistantRequest.normalize(text)
        let pattern = #"\s+(?:в\s+)?([0-9]{1,2}):([0-9]{2})$"#
        if let value = text.range(of: pattern, options: .regularExpression) {
            let parts = text[value].split { !$0.isNumber }.compactMap { Int($0) }
            let dateText = String(text[..<value.lowerBound])
            guard parts.count == 2, parts[0] < 24, parts[1] < 60,
                  let date = AssistantProjectFields.parseDate(dateText, today: today) ??
                    AssistantRequest.assignmentDeadline(dateText, today: today) else { return nil }
            return (date, String(format: "%02d:%02d", parts[0], parts[1]))
        }
        return (AssistantProjectFields.parseDate(text, today: today) ??
                AssistantRequest.assignmentDeadline(text, today: today)).map { ($0, nil) }
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "«»“”\".,:!?")))
    }
}

enum AssistantRequest {
    private static let searchPrefix = #"^(?:(?:валли|а|пожалуйста|можешь|можете|мне)[\s,:]+)*(?:покажи(?:те)?|найди(?:те)?|выведи(?:те)?)\b"#

    private static let navigationPrefix = #"^(?:(?:валли|а|пожалуйста|можно|можешь|можете|мне|давай|давайте|хочу|нужно)[\s,:]+)*(?:открой(?:те)?|открыть|покажи(?:те)?|показать|найди(?:те)?|найти|выведи(?:те)?)\b"#

    enum MeetingNavigation: Equatable {
        case choose, latest, named(String)
    }

    static func isNavigationRequest(_ text: String) -> Bool {
        normalize(text).range(of: navigationPrefix, options: .regularExpression) != nil
    }

    static func navigationTarget(_ text: String) -> String {
        let text = normalize(text)
        guard let prefix = text.range(of: navigationPrefix, options: .regularExpression) else { return text }
        return normalize(String(text[prefix.upperBound...]))
    }

    static func meetingToOpen(_ text: String) -> MeetingNavigation? {
        let text = normalize(text)
        let pattern = navigationPrefix + #"[\s,]+(?:(?:мне|пожалуйста|все|список)[\s,]+)*(?:(?:самое|самую)\s+)?(?:(последнее|последнюю|крайнее|крайнюю|прошлое|прошлую)\s+)?(?:совещание|совещания|совещаний|встреча|встречу|встречи|встреч)\b"#
        let regex = try! NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let command = Range(match.range, in: text) else { return nil }
        let projectContext = #"(?:^|\s+)(?:(?:в|по|для)\s+)?(?:(?:этом|этому|этого|текущем|текущему|текущего)\s+)?проект(?:а|е|у)?$"#
        let tail = normalize(String(text[command.upperBound...]))
        let title = normalize(tail.replacingOccurrences(of: projectContext, with: "", options: .regularExpression))
        if match.range(at: 1).location != NSNotFound ||
            ["последнее", "последнюю", "крайнее", "крайнюю", "прошлое", "прошлую"].contains(title) {
            return .latest
        }
        return title.isEmpty ? .choose : .named(title)
    }

    static func taskToOpen(_ text: String) -> String? {
        let text = normalize(text)
        let pattern = #"^(?:(?:валли|а|пожалуйста|можешь|можете)[\s,:]+)*(?:открой(?:те)?|открыть)[\s,]+(?:(?:мне|пожалуйста)[\s,]+)*(?:задачу|поручение)\b\s*(?:(?:по(?:\s+теме)?|про|о|об)\s+)?"#
        guard let prefix = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[prefix.upperBound...])
    }

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
        case createProject = "create_project"
        case createTask = "create_task"
        case createMeeting = "create_meeting"
        case createDecision = "create_decision"
        case clarify
    }

    let action: Action
    let title: String?
    let project: String?
    let assignee: String?
    let filters: String?
    let description: String?
    let priority: String?
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

enum CreationField: Hashable {
    case title, project, start, end, dateRole, owner, assignee, meetingDate, participants, description, priority

    var question: String {
        switch self {
        case .title: "Как назвать? Для решения продиктуйте его текст."
        case .project: "Для какого проекта?"
        case .start: "Когда начинаем проект?"
        case .end: "Какой срок завершения?"
        case .dateRole: "Эта дата означает начало проекта или срок завершения?"
        case .owner: "Кого назначить ответственным за проект?"
        case .assignee: "Кто исполнитель задачи?"
        case .meetingDate: "На какую дату и время назначить встречу?"
        case .participants: "Кого добавить в участники?"
        case .description: "Какие добавить подробности?"
        case .priority: "Какой приоритет у задачи?"
        }
    }

    static func labeledValue(in text: String, kind: Creation) -> (CreationField, String)? {
        let labels: [(CreationField, String)] = [
            (.title, #"название|назови|текст решения|решение"#),
            (.start, #"дата начала|начало|начинаем|начнем|старт"#),
            (.end, #"срок завершения|дата завершения|срок|дедлайн|закончим|завершим"#),
            (.meetingDate, #"дату и время|дата и время|дату|дата|назначь на|перенеси на"#),
            (.owner, #"владелец|ответственный|ответственная|ответственного|назначь"#),
            (.assignee, #"исполнитель|исполнителя"#),
            (.participants, #"добавь участников|добавь участника|участники|участник|пригласи"#),
            (.project, #"проект|в проекте|по проекту|для проекта"#),
            (.description, #"описание|подробности|добавь описание"#),
            (.priority, #"приоритет"#)
        ]
        for (field, pattern) in labels {
            guard let prefix = text.range(of: "^(?:" + pattern + ")[\\s,:]+",
                                          options: [.regularExpression, .caseInsensitive]) else { continue }
            var field = field
            if field == .owner && kind == .task { field = .assignee }
            if field == .meetingDate && kind == .task { field = .end }
            if field == .meetingDate && kind == .project { field = .dateRole }
            let value = String(text[prefix.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (field, value)
        }
        return nil
    }
}

struct CreationConversation {
    let kind: Creation
    let missing: [CreationField]
    let canSave: Bool
}


enum MeetingParticipantNames {
    static func resolve(_ text: String, matches: (String) -> [Int]) -> Set<Int>? {
        let separated = text.replacingOccurrences(of: #"\s+и\s+|;"#, with: ",",
                                                   options: [.regularExpression, .caseInsensitive])
        var result = Set<Int>()
        for part in separated.split(separator: ",") {
            let words = part.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !words.isEmpty else { continue }
            let whole = matches(words.joined(separator: " "))
            if whole.count == 1 {
                result.insert(whole[0])
                continue
            }
            guard whole.isEmpty, let split = splitNames(words, matches: matches) else { return nil }
            result.formUnion(split)
        }
        return result.isEmpty ? nil : result
    }

    private static func splitNames(_ words: [String], matches: (String) -> [Int]) -> Set<Int>? {
        var suffixes = Array(repeating: Set<Set<Int>>(), count: words.count + 1)
        suffixes[words.count] = [[]]
        for start in words.indices.reversed() {
            for end in (start + 1)...words.count where !suffixes[end].isEmpty {
                let phrase = words[start..<end].joined(separator: " ")
                for person in matches(phrase) {
                    for suffix in suffixes[end] {
                        suffixes[start].insert(suffix.union([person]))
                    }
                }
                if suffixes[start].count > 1 { break }
            }
        }
        guard suffixes[0].count == 1 else { return nil }
        return suffixes[0].first
    }
}
