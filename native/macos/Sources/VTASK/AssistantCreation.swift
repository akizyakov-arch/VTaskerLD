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
    let projectName: String?
    let startsRecording: Bool
    var projectFields: AssistantProjectFields? = nil
    var taskFields: AssistantTaskFields? = nil

    private static let startActions: Set<String> = [
        "запусти", "запустите", "начни", "начните", "запустить", "начать", "начнем", "проведи", "провести"
    ]
    private static let createActions: Set<String> = [
        "создай", "создайте", "добавь", "добавьте", "создать", "создадим", "добавить",
        "организуй", "организовать", "запланируй", "запланировать", "запиши", "зафиксируй", "зафиксировать"
    ]

    private static func commandWords(_ query: String) -> ArraySlice<Substring> {
        let fillers: Set<String> = ["пожалуйста", "давай", "давайте", "можно", "можешь", "можете", "хочу", "нужно", "надо", "а", "теперь", "мне"]
        return query.split(whereSeparator: \.isWhitespace).drop(while: { fillers.contains(normalize(String($0))) })
    }

    static func isCreationRequest(_ query: String) -> Bool {
        guard let first = commandWords(query).first else { return false }
        let action = normalize(String(first))
        return startActions.contains(action) || createActions.contains(action)
    }

    static func parse(_ query: String, today: String) -> Self? {
        let parts = commandWords(query)
        guard let verb = parts.first else { return nil }
        let modifiers: Set<String> = ["новый", "новую", "новое", "пожалуйста", "мне"]
        let arguments = parts.dropFirst().drop(while: { modifiers.contains(normalize(String($0))) })
        guard let entity = arguments.first else { return nil }
        let action = normalize(String(verb))
        let starts = startActions.contains(action)
        guard starts || createActions.contains(action) else { return nil }
        let kind: Creation
        switch normalize(String(entity)) {
        case "задачу", "задача", "поручение": kind = .task
        case "проект": kind = .project
        case "решение": kind = .decision
        case "совещание", "встречу", "встреча", "планерку", "планерка": kind = .meeting
        case "запись" where starts: kind = .meeting
        default: return nil
        }
        guard !starts || kind == .meeting else { return nil }
        var details = arguments.dropFirst()
        if starts, normalize(String(entity)) == "запись",
           let first = details.first, ["совещания", "встречи", "планерки"].contains(normalize(String(first))) {
            details = details.dropFirst()
        }
        let body = details.joined(separator: " ")
        if kind == .project {
            let parsed = AssistantProjectFields.parse(clean(body), today: today)
            return Self(kind: kind, title: parsed.title, projectName: nil, startsRecording: false,
                        projectFields: parsed.fields)
        }
        let currentContext = #"(?i)\s*(?:в\s+этом|по\s+этому|для\s+этого|в\s+текущем|по\s+текущему)\s+проект(?:е|у|а)\s*$"#
        let contextualBody = body.replacingOccurrences(of: currentContext, with: "", options: .regularExpression)
        if kind != .project && contextualBody != body {
            return Self(kind: kind, title: clean(contextualBody), projectName: nil, startsRecording: starts)
        }
        let pattern = #"(?i)(?:^|\s)(?:(?:к|в|для|по)\s+)?проект(?:у|е|а)?(?:\s*[:«"]\s*|\s+|$)"#
        if kind != .project, let range = body.range(of: pattern, options: .regularExpression) {
            let name = clean(String(body[range.upperBound...]))
            return Self(kind: kind, title: clean(String(body[..<range.lowerBound])),
                        projectName: name, startsRecording: starts)
        }
        return Self(kind: kind, title: clean(body), projectName: nil, startsRecording: starts)
    }

    static func normalize(_ text: String) -> String {
        clean(text).lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "«»“”\":,.!?")))
    }
}

enum AssistantTaskStatus {
    static func target(in text: String) -> String? {
        let text = AssistantCreation.normalize(text)
        let pattern = #"^(?:валли[\s,:]+)?(?:поменяй(?:те)?|смени(?:те)?|измени(?:те)?|поставь(?:те)?|установи(?:те)?)\s+статус(?:\s+задачи)?\b[\s,:]*(?:на\b\s*)?"#
        guard let prefix = text.range(of: pattern, options: .regularExpression) else { return nil }
        return AssistantCreation.normalize(String(text[prefix.upperBound...]))
    }

    static func movePhrase(in text: String) -> String? {
        let text = AssistantCreation.normalize(text)
        let pattern = #"^(?:валли[\s,:]+)?(?:перенеси(?:те)?|переведи(?:те)?|перемести(?:те)?)\s+задачу\b[\s,:]*"#
        guard let prefix = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[prefix.upperBound...])
    }

    static func destinations(in phrase: String) -> [(name: String, target: String)] {
        let expression = try! NSRegularExpression(pattern: #"(?<!\S)(?:в\s+статус|(?:на\s+)+(?=\S)|в(?=\s))"#)
        return expression.matches(in: phrase, range: NSRange(phrase.startIndex..., in: phrase)).reversed()
            .compactMap { match in
                guard let range = Range(match.range, in: phrase) else { return nil }
                let name = AssistantCreation.normalize(String(phrase[..<range.lowerBound]))
                let suffix = AssistantCreation.normalize(String(phrase[range.lowerBound...]))
                let target = suffix.hasPrefix("в статус")
                    ? AssistantCreation.normalize(String(phrase[range.upperBound...])) : suffix
                return (name, target)
            }
    }

    static func matches(_ target: String, stages: [Stage]) -> [Stage] {
        let normalized = AssistantCreation.normalize(target)
        let cleaned = normalized.replacingOccurrences(of: #"^(?:на\s+)+"#, with: "", options: .regularExpression)
        let exact = stages.filter {
            let title = AssistantCreation.normalize($0.title)
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
        case createProject = "create_project"
        case createTask = "create_task"
        case createMeeting = "create_meeting"
        case startMeeting = "start_meeting"
        case createDecision = "create_decision"
        case clarify
    }

    let action: Action
    let title: String?
    let project: String?
    let assignee: String?
    let filters: String?
    let description: String?
    let dueDate: String?
    let dueTime: String?
    let priority: String?
}

struct AssistantTaskFields {
    let assignee: String?
    let description: String?
    let dueDate: String?
    let dueTime: String?
    let priority: String?
}
