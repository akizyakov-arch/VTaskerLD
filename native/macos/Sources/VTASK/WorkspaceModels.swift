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
    let industryTerms: [CompanyTerm]?
    let glossaryTerms: [CompanyTerm]?

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
    let revision: Int
    let goal: String?
    let materials: String?
    let ownerId: Int?
    let members: [Int]?
    let nextMilestone: String?
    let nextMilestoneDate: String?
    let blocker: String?
    let status: String
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
    let recordings: [Recording]
    let processing: ProcessingJob?
    let manualNotes: MeetingNotes?
    let analysis: MeetingAnalysis?

    var visibleTitle: String { displayTitle ?? title }

    func meetingDateLabel(in zone: TimeZone) -> String? {
        if let meetingAt {
            let parser = ISO8601DateFormatter()
            parser.formatOptions.insert(.withFractionalSeconds)
            if let date = parser.date(from: meetingAt) ?? ISO8601DateFormatter().date(from: meetingAt) {
                return formatMeetingDate(date, in: zone)
            }
        }
        return scheduleLabel(in: zone)
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
        let savedMs: Int?
        let level: Double?
    }
}
