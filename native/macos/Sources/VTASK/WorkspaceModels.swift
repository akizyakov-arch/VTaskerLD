import Foundation

struct Workspace: Decodable {
    let projects: [Project]
    let tasks: [TaskItem]
    let meetings: [Meeting]
    let people: [Person]
    let defaultStages: [Stage]
    let settings: WorkspaceSettings
    let today: String
    let proposals: [Proposal]
    let decisions: [Decision]
    let notifications: [TaskNotification]?
    let companyTerms: [CompanyTerm]?
    let termProposals: [TermProposal]?
    let industryCatalog: [IndustryOption]?
    let specializationCatalog: [SpecializationOption]?
    let industryTerms: [CompanyTerm]?
    let glossaryTerms: [CompanyTerm]?
    let workPeriodCatalog: [WorkPeriodTemplate]?
    let eventWorkPeriodLists: [String: [WorkPeriodTemplate]]?

    var industryOptions: [IndustryOption] { industryCatalog ?? IndustryOption.legacy }

    func workPeriodTitles(for terminology: [String]) -> [String]? {
        guard let workPeriodCatalog else { return nil }
        let scopes = terminology.isEmpty ? [settings.industryTemplate ?? .events]
            : terminology.map { IndustryTemplate(rawValue: $0) }
        let industries = Set(scopes.map { $0.parent.rawValue } + ["universal"])
        var titles = workPeriodCatalog.filter { entry in
            industries.contains(entry.industryId)
                && (entry.industryId != "events" || eventWorkPeriodLists == nil || !entry.builtIn)
        }.map(\.title)
        if industries.contains("events"), let lists = eventWorkPeriodLists {
            let eventScopes = scopes.filter { $0.parent == .events }
            let keys = eventScopes.contains(where: { $0.eventWorkPeriodListKey == nil })
                ? Set(lists.keys) : Set(eventScopes.compactMap(\.eventWorkPeriodListKey))
            titles.append(contentsOf: keys.flatMap { lists[$0]?.map(\.title) ?? [] })
        }
        return titles
    }

    func terminologySelection(projectID: Int?, meeting: Meeting? = nil) -> [String] {
        if let ids = meeting?.terminologyIndustries, !ids.isEmpty {
            return ids
        }
        return projects.first { $0.id == (meeting?.projectId ?? projectID) }?.terminologyIndustries ?? []
    }

    func terminologyTitles(_ ids: [String]) -> String {
        let selection = ids.isEmpty ? [(settings.industryTemplate ?? .events).rawValue] : ids
        return selection.compactMap { id in
            industryOptions.first { $0.id == id }?.title ?? specializationCatalog?.first { $0.id == id }?.title
        }.joined(separator: ", ")
    }

    var industryTitle: String {
        industryOptions.first { $0.template == (settings.industryTemplate ?? .events) }?.title ?? "Мероприятия и декор"
    }

    var visibleTasks: [TaskItem] {
        let archivedIDs = Set(projects.filter { $0.archived == true }.map(\.id))
        return tasks.filter { task in
            task.projectId.map { !archivedIDs.contains($0) } ?? true
        }
    }
}

struct Project: Decodable, Identifiable {
    let id: Int
    let title: String
    let description: String?
    let archived: Bool?
    let stages: [Stage]
    let startDate: String?
    let endDate: String?
    let updatedAt: String?
    let revision: Int
    let goal: String?
    let materials: String?
    let ownerId: Int?
    let members: [Int]?
    let nextMilestone: String?
    let nextMilestoneDate: String?
    let blocker: String?
    let status: String
    let terminologyIndustries: [String]?

    let workPeriods: [ProjectWorkPeriod]?

    var isCurrent: Bool { archived != true && (status == "planned" || status == "active") }
}

struct ProjectWorkPeriod: Decodable, Identifiable {
    let id: String
    var title: String
    var startDate: String?
    var endDate: String?

    var datesAreReversed: Bool {
        if let startDate, let endDate { return startDate > endDate }
        return false
    }
}

struct TaskItem: Decodable, Identifiable {
    let id: Int
    let title: String
    let description: String?
    let projectId: Int?
    let stageTitle: String
    let stageId: String
    let stageKind: String
    let assigneeId: Int?
    let dueDate: String?
    let overdue: Bool
    let priority: String?
    let blocked: Bool?
    let blockedReason: String?
    let authorId: Int?
    let dependencies: [Int]?
    let relatedTaskIds: [Int]?
    let sources: [TaskSource]?
    let createdAt: String?
    let updatedAt: String?
    let revision: Int
    let dueTime: String?
}

struct TaskNotification: Decodable, Identifiable {
    struct Payload: Decodable {
        let title: String
        let kind: String
    }

    let id: Int
    let taskId: Int
    let payload: Payload
    let readAt: String?

    var label: String {
        switch payload.kind {
        case "create_task": return "Поручение утверждено"
        case "change_due": return "Срок изменён"
        case "change_assignee": return "Вам назначена задача"
        case "change_blocked": return "Блокировка изменена"
        case "change_status": return "Статус изменён"
        default: return "Изменения утверждены"
        }
    }
}

struct AnalysisMaterialLink: Decodable, Equatable, Identifiable {
    let id: Int
    let label: String
    let url: String

    var target: URL? {
        guard let target = URL(string: url), let scheme = target.scheme,
              ["https", "http"].contains(scheme), target.host != nil else { return nil }
        return target
    }
}

struct TaskSource: Decodable, Equatable {
    let meetingId: Int?
    let quote: String?
    let topic: String?
    let materialLinks: [AnalysisMaterialLink]?
}

struct Meeting: Decodable, Identifiable {
    let id: Int
    let scheduledAt: String?
    let title: String
    let displayTitle: String?
    let protocolTitle: String?
    let meetingAt: String?
    let projectName: String?
    let projectId: Int?
    let status: String
    let participants: [Int]
    let terminologyIndustries: [String]?
    let recordings: [Recording]
    let processing: ProcessingJob?
    let manualNotes: MeetingNotes?
    let analysis: MeetingAnalysis?

    var visibleTitle: String { displayTitle ?? title }

    var date: Date? {
        if let meetingAt {
            let parser = ISO8601DateFormatter()
            parser.formatOptions.insert(.withFractionalSeconds)
            if let date = parser.date(from: meetingAt) ?? ISO8601DateFormatter().date(from: meetingAt) {
                return date
            }
        }
        return scheduledDate
    }

    func meetingDateLabel(in zone: TimeZone) -> String? {
        date.map { formatMeetingDate($0, in: zone) }
    }

    var scheduledDate: Date? {
        scheduledAt.flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    func scheduleLabel(in zone: TimeZone) -> String? {
        guard let scheduledDate else { return nil }
        return formatMeetingDate(scheduledDate, in: zone)
    }

    private func formatMeetingDate(_ date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = zone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct Person: Decodable, Identifiable {
    let id: Int
    let name: String
    let lastName: String?
    let patronymic: String?
    let role: String?
    let organization: String?
    let department: String?
    let nickname: String?
    let photoRevision: Int?
    let email: String?
    let phone: String?
    let notes: String?
}

struct Stage: Decodable, Identifiable {
    let id: String
    let title: String
    let kind: String
}

struct Recording: Decodable {
    let id: Int
}

struct CaptureStatus: Decodable, Equatable {
    let active: Session?
    let hint: SpeakerHint?
    var liveDisplay: Bool?

    struct SpeakerHint: Decodable, Equatable {
        let sessionId: String?
        let personId: Int?
        let status: String
        let ageMs: Int?
        let endMs: Int?
    }

    struct Session: Decodable, Equatable {
        let meetingId: Int
        let state: String
        let canPause: Bool
        let sessionId: String?
        let elapsedMs: Int?
        let positionMs: Int?
        let savedMs: Int?
        let level: Double?
    }
}
