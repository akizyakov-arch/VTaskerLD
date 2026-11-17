import Foundation

struct SavedTaskView: Decodable, Identifiable {
    let name: String
    let filters: Filters
    let sort: String?
    let group: String?
    let view: String?
    var id: String { name }

    struct Filters: Decodable {
        let q: String?
        let projects: [String]?
        let assignees: [String]?
        let statuses: [String]?
        let priorities: [String]?
        let dues: [String]?
        let windowFrom: String?
        let windowTo: String?
        let from: String?
        let to: String?
        let active: Bool?
        let blocked: Bool?
        let missing: Bool?
        let source: String?
    }

    func apply(to tasks: [TaskItem], in workspace: Workspace, project: Int?) -> [TaskItem] {
        let today = workspace.today
        let weekEnd = dayAfter(6, from: today)
        let query = filters.q?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let results = tasks.filter { task in
            let projectKey = task.projectId.map(String.init) ?? "none"
            let assigneeKey = task.assigneeId.map(String.init) ?? "none"
            if let project {
                guard task.projectId == project else { return false }
            } else if !matches(filters.projects, projectKey) {
                return false
            }
            if let keys = filters.assignees, !keys.isEmpty,
               !keys.contains(assigneeKey) && !(keys.contains("me") && task.assigneeId != nil && task.assigneeId == workspace.settings.meId) {
                return false
            }
            if let statuses = filters.statuses, !statuses.isEmpty,
               !statuses.contains(projectKey + ":" + task.stageId) && !statuses.contains("kind:" + task.stageKind) {
                return false
            }
            if !matches(filters.priorities, task.priority ?? "normal") { return false }
            if filters.active == true && task.stageKind != "active" { return false }
            if filters.blocked == true && task.blocked != true { return false }
            if filters.missing == true && task.assigneeId != nil && task.dueDate != nil { return false }
            if let source = filters.source, !source.isEmpty,
               (source == "meeting") == (task.sources?.isEmpty ?? true) { return false }
            if let from = filters.windowFrom, !from.isEmpty, (task.dueDate ?? "") < from { return false }
            if let to = filters.windowTo, !to.isEmpty, (task.dueDate ?? "~") > to { return false }
            if let dues = filters.dues, !dues.isEmpty,
               !dues.contains(where: { matchesDue($0, task: task, today: today, weekEnd: weekEnd) }) { return false }
            return query.isEmpty || (task.title + " " + (task.description ?? "")).localizedCaseInsensitiveContains(query)
        }
        let rank = ["critical": 0, "high": 1, "normal": 2, "low": 3]
        return results.sorted { left, right in
            switch sort {
            case "created": return (left.createdAt ?? "") > (right.createdAt ?? "")
            case "updated": return (left.updatedAt ?? "") > (right.updatedAt ?? "")
            case "priority":
                let a = rank[left.priority ?? "normal"] ?? 2
                let b = rank[right.priority ?? "normal"] ?? 2
                return a == b ? left.title.localizedCompare(right.title) == .orderedAscending : a < b
            default:
                return (left.dueDate ?? "9999", left.dueTime ?? "23:59", rank[left.priority ?? "normal"] ?? 2)
                    < (right.dueDate ?? "9999", right.dueTime ?? "23:59", rank[right.priority ?? "normal"] ?? 2)
            }
        }
    }

    private func matches(_ values: [String]?, _ value: String) -> Bool {
        guard let values, !values.isEmpty else { return true }
        return values.contains(value)
    }

    private func matchesDue(_ key: String, task: TaskItem, today: String, weekEnd: String) -> Bool {
        let due = task.dueDate
        switch key {
        case "overdue": return task.overdue
        case "none": return due == nil
        case "today": return due == today
        case "week", "due-soon":
            guard let due else { return false }
            return due >= today && due <= weekEnd && (key == "week" || !task.overdue)
        case "due-later": return !task.overdue && (due ?? "") > weekEnd
        case "range":
            guard let due else { return false }
            return due >= (filters.from ?? "") && due <= (filters.to.flatMap { $0.isEmpty ? nil : $0 } ?? "~")
        default: return false
        }
    }

    private func dayAfter(_ count: Int, from date: String) -> String {
        let format = Date.ISO8601FormatStyle().year().month().day().dateSeparator(.dash)
        guard let start = try? format.parse(date) else { return date }
        return format.format(start.addingTimeInterval(Double(count) * 86_400))
    }
}

extension TaskFilter {
    var savedFilters: [String: Any] {
        switch self {
        case .all: return [:]
        case .active: return ["active": true]
        case .today: return ["active": true, "dues": ["today"]]
        case .overdue: return ["dues": ["overdue"]]
        case .undated: return ["active": true, "dues": ["none"]]
        case .done: return ["statuses": ["kind:done"]]
        case .dueSoon: return ["active": true, "dues": ["due-soon"]]
        case .later: return ["active": true, "dues": ["due-later"]]
        }
    }
}
