import SwiftUI

struct MeetingEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: WorkspaceModel
    let meeting: Meeting
    @State private var title: String
    @State private var schedule: Date
    @State private var hasSchedule: Bool
    @State private var projectID: Int?
    @State private var participants: Set<Int>

    init(model: WorkspaceModel, meeting: Meeting) {
        self.model = model
        self.meeting = meeting
        _title = State(initialValue: meeting.title)
        _schedule = State(initialValue: meeting.scheduledDate ?? .now)
        _hasSchedule = State(initialValue: meeting.scheduledDate != nil)
        _projectID = State(initialValue: meeting.projectId)
        _participants = State(initialValue: Set(meeting.participants))
    }

    var body: some View {
        Form {
            TextField("Название", text: $title)
            Toggle("Указать дату и время", isOn: $hasSchedule)
            if hasSchedule {
                let zone = model.workspace.flatMap { TimeZone(identifier: $0.settings.timezone) } ?? .current
                DatePicker("Дата и время", selection: $schedule, displayedComponents: [.date, .hourAndMinute])
                    .environment(\.timeZone, zone)
            }
            Picker("Проект", selection: $projectID) {
                Text("Без проекта").tag(nil as Int?)
                ForEach(model.workspace?.projects.filter { $0.archived != true || $0.id == meeting.projectId } ?? []) { project in
                    Text(project.title).tag(Optional(project.id))
                }
            }
            Section("Участники") {
                ForEach(model.workspace?.people ?? []) { person in
                    Toggle(person.name, isOn: Binding(
                        get: { participants.contains(person.id) },
                        set: { chosen in
                            if chosen { participants.insert(person.id) } else { participants.remove(person.id) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
            if let error = model.error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Отмена") { dismiss() }.buttonStyle(.bordered)
                Spacer()
                Button("Сохранить") {
                    Task {
                        let data: [String: Any] = [
                            "title": title,
                            "project_id": projectID.map { $0 as Any } ?? NSNull(),
                            "participants": participants.sorted(),
                            "scheduled_at": hasSchedule ? ISO8601DateFormatter().string(from: schedule) as Any : NSNull()
                        ]
                        if await model.command(["op": "save_meeting", "id": meeting.id, "data": data]) {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 420)
        .disabled(model.saving || model.loading || model.capture?.active?.meetingId == meeting.id)
        .interactiveDismissDisabled(model.saving)
    }
}

struct MeetingAnalysis: Decodable {
    struct Saved: Decodable {
        let result: Result?
    }
    struct Result: Decodable {
        struct Item: Decodable { let title: String? }
        struct Finding: Decodable, Identifiable {
            let id: String
            let kind: String
            let text: String
            let source: Proposal.Source?
            let taskId: Int?

            var label: String {
                ["status_update": "Ход работы", "question": "Вопрос", "information": "Наблюдение"][kind] ?? kind
            }
        }
        let summary: String?
        let openQuestions: [String]?
        let decisions: [Item]?
        let tasks: [Item]?
        let findings: [Finding]?
    }

    let state: String
    let error: String?
    let saved: Saved?
    let stale: Bool?

    var running: Bool { state == "pending" || state == "running" }
}

struct MeetingAnalysisView: View {
    @ObservedObject var model: WorkspaceModel
    let meeting: Meeting
    let openMeeting: (Int) -> Void
    let openTask: (Int) -> Void
    @State private var showingAgenda = false
    @State private var editingNotes = false

    var body: some View {
        let analysis = meeting.analysis
        let summary = analysis?.saved?.result?.summary ?? ""
        let observations = analysis?.saved?.result?.findings?.filter {
            ["status_update", "question", "information"].contains($0.kind)
        } ?? []
        let manualSummary = meeting.manualNotes?.summary ?? ""
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Итоги совещания", systemImage: "doc.text")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if meeting.projectId != nil {
                    Button("Черновик повестки") { showingAgenda = true }
                        .buttonStyle(.bordered)
                }
                if meeting.manualNotes != nil {
                    Button { editingNotes = true } label: {
                        Label("Заметки", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.bordered)
                }
            }
            if analysis?.running == true {
                ProgressView(analysis?.state == "pending" ? "Анализ в очереди…" : "Анализирую протокол…")
                    .progressViewStyle(.linear)
            }
            if let error = analysis?.error { Text(error).foregroundStyle(.red) }
            if analysis?.stale == true {
                Label("Протокол или участники изменились после анализа.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !summary.isEmpty {
                ProtocolProse(text: summary)
            }
            if !manualSummary.isEmpty {
                if !summary.isEmpty { Text("Ручное резюме").font(.headline) }
                ProtocolProse(text: manualSummary)
            }
            if summary.isEmpty && manualSummary.isEmpty && analysis?.running != true {
                Text("Резюме пока нет.").foregroundStyle(.secondary)
            }
            if !observations.isEmpty {
                MeetingDisclosure(title: "Наблюдения", icon: "list.bullet.rectangle", count: observations.count) {
                    ForEach(observations) { item in
                        DisclosureGroup {
                            if let quote = item.source?.quote { Text(quote).textSelection(.enabled) }
                            ForEach(item.source?.materialLinks ?? []) { link in
                                if let target = link.target { Link(link.label, destination: target) }
                            }
                            if let id = item.taskId, let task = model.workspace?.visibleTasks.first(where: { $0.id == id }) {
                                Button(task.title) { openTask(id) }.buttonStyle(.link)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.text)
                                Text([item.label, item.source?.startMs.map(meetingTime)].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .panelCard()
        .sheet(isPresented: $showingAgenda) {
            agenda.sheetCloseButton()
        }
        .sheet(isPresented: $editingNotes) {
            Group {
                if let notes = meeting.manualNotes {
                    MeetingNotesEditor(model: model, meetingID: meeting.id, notes: notes)
                        .id([meeting.id, notes.revision])
                }
            }
            .sheetCloseButton(disabled: model.saving)
        }
    }
    private var agenda: some View {
        let tasks = (model.workspace?.visibleTasks ?? []).filter {
            $0.projectId == meeting.projectId && $0.stageKind == "active"
        }
        let priorMeetings = (model.workspace?.meetings ?? []).filter {
            $0.projectId == meeting.projectId && $0.id < meeting.id
        }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Повестка").font(.title2.bold())
                MeetingDisclosure(title: "Открытые вопросы прошлых встреч", icon: "questionmark.bubble", count: nil) {
                    ForEach(priorMeetings) { prior in
                        let manual = prior.manualNotes?.openQuestions ?? ""
                        let questions = prior.analysis?.saved?.result?.openQuestions ?? []
                        if !manual.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !questions.isEmpty {
                            Button(prior.title) {
                                showingAgenda = false
                                openMeeting(prior.id)
                            }.buttonStyle(.link)
                            if !manual.isEmpty { Text(manual).textSelection(.enabled) }
                            ForEach(Array(questions.enumerated()), id: \.offset) { _, question in
                                Text(question).textSelection(.enabled)
                            }
                        }
                    }
                    if !priorMeetings.contains(where: {
                        !($0.manualNotes?.openQuestions.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
                            || $0.analysis?.saved?.result?.openQuestions?.isEmpty == false
                    }) {
                        Text("Открытых вопросов пока нет.").foregroundStyle(.secondary)
                    }
                }
                agendaTasks("Блокировки", icon: "exclamationmark.circle", tasks: tasks.filter { $0.blocked == true })
                agendaTasks("Открытые задачи", icon: "checklist", tasks: tasks.filter { $0.blocked != true })
            }
            .padding(20)
        }
        .frame(width: 560, height: 460)
    }

    private func agendaTasks(_ title: String, icon: String, tasks: [TaskItem]) -> some View {
        MeetingDisclosure(title: title, icon: icon, count: tasks.count) {
            if tasks.isEmpty { Text("Нет задач.").foregroundStyle(.secondary) }
            ForEach(tasks) { task in
                Button(task.title) {
                    showingAgenda = false
                    openTask(task.id)
                }.buttonStyle(.link)
                if let reason = task.blockedReason, !reason.isEmpty, task.blocked == true {
                    Text(reason).foregroundStyle(.secondary)
                }
            }
        }
    }

}

struct MeetingDecisions: View {
    @Environment(\.companyGlossary) private var glossary
    @Environment(\.meetingTopics) private var meetingTopics
    let decisions: [Decision]
    let proposals: [Proposal]
    let review: (Proposal) -> Void

    var body: some View {
        if !decisions.isEmpty || !proposals.isEmpty {
            MeetingDisclosure(title: "Решения", icon: "checkmark.seal", count: decisions.count + proposals.count) {
                MeetingTopicList(rows: MeetingTopicEntry.rows(decisions, proposals: proposals), topic: { row in
                    switch row {
                    case .confirmed(let decision):
                        return meetingTopics.title(topic: decision.source?.topic, text: decision.text, context: decision.source?.quote, glossary: glossary)
                    case .proposed(let proposal):
                        return MeetingTopicEntry<Decision>.proposalTopic(proposal, topics: meetingTopics, glossary: glossary)
                    }
                }) { row in
                    switch row {
                    case .confirmed(let decision):
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: decision.active ? "checkmark.circle.fill" : "minus.circle")
                                .foregroundStyle(decision.active ? Color.green : Color.secondary)
                                .accessibilityLabel(decision.statusLabel)
                            VStack(alignment: .leading, spacing: 4) {
                                ProtocolProse(text: decision.text)
                                ForEach(decision.source?.materialLinks ?? []) { link in
                                    if let target = link.target { Link(link.label, destination: target) }
                                }
                                if !decision.active {
                                    Text(decision.statusLabel).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    case .proposed(let proposal):
                        MeetingProposalRow(proposal: proposal, icon: "checkmark.seal", review: review)
                    }
                }
            }
        }
    }
}

struct MeetingOpenQuestions: View {
    let meeting: Meeting

    var body: some View {
        let questions = meeting.analysis?.saved?.result?.openQuestions?
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []
        let notes = meeting.manualNotes?.openQuestions.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        MeetingDisclosure(title: "Открытые вопросы", icon: "questionmark.bubble", count: questions.count + (notes.isEmpty ? 0 : 1)) {
            if questions.isEmpty && notes.isEmpty {
                Text("Открытых вопросов пока нет.").foregroundStyle(.secondary)
            }
            ForEach(questions.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1).")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    ProtocolProse(text: questions[index])
                }
            }
            if !notes.isEmpty {
                Text("Из заметок").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ProtocolProse(text: notes)
            }
        }
    }
}

struct MeetingDisclosure<Content: View>: View {
    let title: String
    let icon: String
    let count: Int?
    @ViewBuilder let content: () -> Content
    @State private var expanded: Bool
    @State private var hovering = false

    init(title: String, icon: String, count: Int?, initiallyExpanded: Bool = false,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.count = count
        self.content = content
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        let state = expanded ? "Развёрнуто" : "Свёрнуто"
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    Image(systemName: icon)
                        .foregroundStyle(.tint)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    Text(title).font(.headline)
                    Spacer(minLength: 8)
                    if let count {
                        Text(count, format: .number)
                            .font(.caption.weight(.medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .background(hovering ? Color.primary.opacity(0.04) : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel(title)
            .accessibilityValue(count.map { "\(state), \($0)" } ?? state)

            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                    content()
                }
                .padding([.horizontal, .bottom], 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .panelCard(inset: 0)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct MeetingProposalRow: View {
    let proposal: Proposal
    let icon: String
    let review: (Proposal) -> Void

    var body: some View {
        Button { review(proposal) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: icon).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(proposal.title ?? "Предложение").font(.callout.weight(.medium))
                    Text(proposal.suggestedExistingTaskId == nil ? "На подтверждении" : "Уточнение к задаче · На подтверждении")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ProtocolProse: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 15))
            .lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: 740, alignment: .leading)
    }
}
