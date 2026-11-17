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
        let summary: String?
        let openQuestions: [String]?
        let decisions: [Item]?
        let tasks: [Item]?
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
    @State private var editingNotes = false

    var body: some View {
        let analysis = meeting.analysis
        let summary = analysis?.saved?.result?.summary ?? ""
        let manualSummary = meeting.manualNotes?.summary ?? ""
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Итоги совещания", systemImage: "doc.text")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
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

        }
        .panelCard()
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
}

struct MeetingDecisions: View {
    let decisions: [Decision]
    let proposals: [Proposal]
    let review: (Proposal) -> Void

    var body: some View {
        if !decisions.isEmpty || !proposals.isEmpty {
            MeetingDisclosure(title: "Решения", icon: "checkmark.seal", count: decisions.count + proposals.count) {
                MeetingTopicList(rows: MeetingTopicEntry.rows(decisions, proposals: proposals), topic: { row in
                    switch row {
                    case .confirmed(let decision):
                        return MeetingTopics.title(topic: decision.source?.topic, text: decision.text, context: decision.source?.quote)
                    case .proposed(let proposal):
                        return MeetingTopicEntry<Decision>.proposalTopic(proposal)
                    }
                }) { row in
                    switch row {
                    case .confirmed(let decision):
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                .accessibilityLabel("Подтверждено")
                            ProtocolProse(text: decision.text)
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
    @State private var expanded = false
    @State private var hovering = false

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
                    Text("На подтверждении").font(.caption).foregroundStyle(.secondary)
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
