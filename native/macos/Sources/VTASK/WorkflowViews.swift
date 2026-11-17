import AVKit
import SwiftUI

struct ProcessingJob: Decodable {
    let id: Int
    let meetingId: Int
    let status: String
    let error: String?
    let stage: String?
    let startedAt: Int?
    let finishedAt: Int?

    var running: Bool { status == "running" }

    var label: String {
        switch status {
        case "pending": return "В очереди"
        case "running":
            switch stage {
            case "preparing": return "Подготовка аудио"
            case "transcribing": return "Распознавание речи"
            case "transcribing_and_separating": return "Распознавание речи и разделение голосов"
            case "separating": return "Разделение голосов"
            case "saving": return "Сохранение протокола"
            default: return "Обработка аудио"
            }
        case "completed": return "Готово"
        case "failed": return cancelled ? "Прервано" : "Ошибка"
        default: return status
        }
    }

    var cancelled: Bool { error == "Распознавание прервано пользователем" }

    var icon: String {
        switch status {
        case "pending": return "clock"
        case "completed": return "checkmark.circle"
        case "failed": return cancelled ? "stop.circle" : "exclamationmark.circle"
        default:
            switch stage {
            case "preparing": return "waveform"
            case "separating": return "person.2.wave.2"
            case "saving": return "doc.text"
            default: return "waveform"
            }
        }
    }
}

struct ProcessingStatusView: View {
    let job: ProcessingJob

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label(job.label, systemImage: job.icon)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 8)
                if let start = job.startedAt {
                    if job.running {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            timer(from: start, to: Int(context.date.timeIntervalSince1970))
                        }
                    } else if let end = job.finishedAt {
                        timer(from: start, to: end)
                    }
                }
            }
            if job.running || job.status == "pending" {
                ProgressView().progressViewStyle(.linear)
                    .accessibilityLabel(job.label)
            }
            if let error = job.error, !job.cancelled {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    private func timer(from start: Int, to end: Int) -> some View {
        let elapsed = max(0, end - start)
        return Label(meetingTime(elapsed * 1000), systemImage: "timer")
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
            .accessibilityLabel("Прошло времени: \(elapsed) секунд")
    }
}

struct ProcessingControls: View {
    @ObservedObject var model: WorkspaceModel
    let meeting: Meeting
    var showsStatus = true
    var showsCancel = false
    @State private var confirmGroq = false

    var body: some View {
        if showsStatus, let job = meeting.processing {
            ProcessingStatusView(job: job)
        }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { actions }
            VStack(alignment: .leading, spacing: 8) { actions }
        }
        .controlSize(.large)
        .confirmationDialog("Отправить протокол выбранному провайдеру ИИ?", isPresented: $confirmGroq) {
            Button("Отправить и проанализировать") {
                Task {
                    await model.command(["meeting_id": meeting.id, "consent": true], path: "api/groq/analyze")
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if (showsStatus || showsCancel) && meeting.processing?.running == true {
            Button(role: .destructive) {
                Task { await model.command(["meeting_id": meeting.id], path: "api/jobs/cancel") }
            } label: {
                Label("Прервать распознавание", systemImage: "stop.circle")
            }
            .buttonStyle(.bordered)
            .disabled(model.saving)
        } else if meeting.processing?.running != true {
            Button {
                Task { await model.runSpeech(for: meeting) }
            } label: {
                Label(meeting.processing?.status == "failed" ? "Повторить распознавание" : "Распознать аудио",
                      systemImage: "waveform")
            }
            .buttonStyle(.borderedProminent)
            .disabled(meeting.recordings.isEmpty || model.saving || model.loading || model.capture?.active != nil)
        }
        Button {
            confirmGroq = true
        } label: {
            Label("Анализ ИИ", systemImage: "sparkles")
        }
        .buttonStyle(.bordered)
        .disabled(meeting.processing?.status != "completed" || meeting.analysis?.running == true
                  || model.saving || model.loading || model.capture?.active?.meetingId == meeting.id)
    }
}

struct RecordingPlayer: View {
    let url: URL
    var startMs = 0
    var endMs: Int? = nil
    @State private var player: AVPlayer?

    var body: some View {
        if let player {
            RecordingPlayerView(player: player)
                .frame(height: 58)
                .task {
                    if startMs > 0 {
                        let start = CMTime(value: Int64(startMs), timescale: 1000)
                        let positioned = await player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
                        guard positioned else { return }
                    }
                    guard !Task.isCancelled else { return }
                    player.play()
                }
                .onDisappear { player.pause() }
        } else {
            Button("Воспроизвести") {
                let item = AVPlayerItem(url: url)
                if let endMs {
                    item.forwardPlaybackEndTime = CMTime(value: Int64(endMs), timescale: 1000)
                }
                player = AVPlayer(playerItem: item)
            }
        }
    }
}

private struct RecordingPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

struct TaskHistoryEntry: Decodable, Identifiable {
    struct Snapshot: Decodable {
        let title: String
        let dueDate: String?
        let dueTime: String?
    }
    let id: Int
    let createdAt: String
    let before: Snapshot?
    let after: Snapshot
}

struct TaskEditor: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: WorkspaceModel
    let task: TaskItem
    let openMeeting: (Int) -> Void
    let draftChanged: (Bool) -> Void
    let returnToMeeting: (() -> Void)?
    @State private var confirmDiscard = false
    @State private var title: String
    @State private var description: String
    @State private var dueDate: String
    @State private var dueTime: String
    @State private var stage: String
    @State private var assignee: Int?
    @State private var projectID: Int?
    @State private var author: Int?
    @State private var priority: String
    @State private var blocked: Bool
    @State private var blockedReason: String
    @State private var dependencies: Set<Int>
    @State private var history: [TaskHistoryEntry] = []
    @State private var historyError: String?
    @State private var historyOpen = false

    init(model: WorkspaceModel, task: TaskItem, openMeeting: @escaping (Int) -> Void,
         draftChanged: @escaping (Bool) -> Void,
         returnToMeeting: (() -> Void)? = nil) {
        self.model = model
        self.task = task
        self.openMeeting = openMeeting
        self.draftChanged = draftChanged
        self.returnToMeeting = returnToMeeting
        _title = State(initialValue: task.title)
        _description = State(initialValue: task.description ?? "")
        _dueDate = State(initialValue: task.dueDate ?? "")
        _dueTime = State(initialValue: task.dueTime ?? "")
        _stage = State(initialValue: task.stageId)
        _assignee = State(initialValue: task.assigneeId)
        _projectID = State(initialValue: task.projectId)
        _author = State(initialValue: task.authorId)
        _priority = State(initialValue: task.priority ?? "normal")
        _blocked = State(initialValue: task.blocked == true)
        _blockedReason = State(initialValue: task.blockedReason ?? "")
        _dependencies = State(initialValue: Set(task.dependencies ?? []))
    }

    private var hasDraft: Bool {
        title != task.title || description != (task.description ?? "") ||
            dueDate != (task.dueDate ?? "") || dueTime != (task.dueTime ?? "") ||
            stage != task.stageId || assignee != task.assigneeId || projectID != task.projectId ||
            author != task.authorId || priority != (task.priority ?? "normal") ||
            blocked != (task.blocked == true) || blockedReason != (task.blockedReason ?? "") ||
            dependencies != Set(task.dependencies ?? [])
    }

    var body: some View {
        let availableStages = stages(for: projectID)
        let workspace = model.workspace
        let palette = PanelPalette(dark: scheme == .dark)
        VStack(spacing: 0) {
            if let returnToMeeting {
                let requestClose = {
                    if hasDraft { confirmDiscard = true }
                    else { returnToMeeting() }
                }
                HStack {
                    WindowCloseButton(action: requestClose)
                        .disabled(model.saving)
                    NavigationBackButton(action: requestClose)
                        .disabled(model.saving)
                    Spacer()
                    Text(task.title).font(.headline).lineLimit(1)
                }
                .padding(16)
                Divider()
            }
            editor(availableStages: availableStages, workspace: workspace)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(palette.recordingInk)
                }
                HStack {
                    Spacer()
                    Button(returnToMeeting == nil ? "Сохранить" : "Сохранить и вернуться") {
                        Task { await save(returnAfter: returnToMeeting != nil) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(palette.surface)
        }
        .background(palette.background)
        .interactiveDismissDisabled(returnToMeeting != nil && (hasDraft || model.saving))
        .confirmationDialog("Сохранить изменения задачи?", isPresented: $confirmDiscard) {
            Button("Сохранить и вернуться") {
                Task { await save(returnAfter: true) }
            }
            .disabled(!canSave)
            Button("Вернуться без сохранения", role: .destructive) { returnToMeeting?() }
            Button("Продолжить редактирование", role: .cancel) {}
        }
    }

    private func editor(availableStages: [Stage], workspace: Workspace?) -> some View {
        Form {
            Section("Описание задачи") {
                TextField("Название", text: $title)
                TextField("Описание", text: $description, axis: .vertical).lineLimit(3...8)
            }
            assignmentFields(availableStages: availableStages, workspace: workspace)
            Section("Срок") {
                TextField("Дата (ГГГГ-ММ-ДД)", text: $dueDate)
                TextField("Время (ЧЧ:ММ)", text: $dueTime)
            }
            Section("Связи") {
                Toggle("Заблокировано", isOn: $blocked)
                if blocked { TextField("Причина блокировки", text: $blockedReason) }
                dependenciesField(workspace: workspace)
            }
            if let sources = task.sources, !sources.isEmpty {
                Section("Источники") {
                    ForEach(sources.indices, id: \.self) { index in
                        let source = sources[index]
                        if let quote = source.quote, !quote.isEmpty { Text(quote).textSelection(.enabled) }
                        if let id = source.meetingId, returnToMeeting == nil {
                            Button(workspace?.meetings.first { $0.id == id }?.title ?? "Открыть встречу") {
                                openMeeting(id)
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
            }
            historyField
        }
        .onChange(of: hasDraft, perform: draftChanged)
        .onDisappear { draftChanged(false) }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(maxHeight: .infinity)
    }

    private func assignmentFields(availableStages: [Stage], workspace: Workspace?) -> some View {
        Section("Организация") {
            Picker("Проект", selection: $projectID) {
                Text("Без проекта").tag(nil as Int?)
                ForEach(workspace?.projects.filter { $0.archived != true || $0.id == task.projectId } ?? []) {
                    Text($0.title).tag(Optional($0.id))
                }
            }
            .onChange(of: projectID) { id in
                let candidates = stages(for: id)
                if !candidates.contains(where: { $0.id == stage }) {
                    stage = candidates.first(where: { $0.kind == "active" })?.id ?? ""
                }
                let eligible = Set((workspace?.tasks ?? []).filter { $0.projectId == id }.map(\.id))
                dependencies.formIntersection(eligible)
            }
            Picker("Статус", selection: $stage) {
                ForEach(availableStages) { Text($0.title).tag($0.id) }
            }
            Picker("Исполнитель", selection: $assignee) {
                Text("Без исполнителя").tag(nil as Int?)
                ForEach(model.workspace?.people ?? []) { Text($0.name).tag(Optional($0.id)) }
            }
            Picker("Приоритет", selection: $priority) {
                Text("Низкий").tag("low")
                Text("Обычный").tag("normal")
                Text("Высокий").tag("high")
                Text("Критический").tag("critical")
            }
            Picker("Автор", selection: $author) {
                Text("Не указан").tag(nil as Int?)
                ForEach(workspace?.people ?? []) { Text($0.name).tag(Optional($0.id)) }
            }
        }
    }

    private func dependenciesField(workspace: Workspace?) -> some View {
        DisclosureGroup("Зависимости") {
            let candidates = workspace?.tasks.filter {
                $0.id != task.id && ($0.projectId == projectID || dependencies.contains($0.id))
            } ?? []
            if candidates.isEmpty { Text("Нет доступных задач").foregroundStyle(.secondary) }
            ForEach(candidates) { candidate in
                Toggle(candidate.title, isOn: Binding(
                    get: { dependencies.contains(candidate.id) },
                    set: { selected in
                        if selected { dependencies.insert(candidate.id) } else { dependencies.remove(candidate.id) }
                    }
                )).toggleStyle(.checkbox)
            }
        }
    }

    private var historyField: some View {
        DisclosureGroup("История изменений", isExpanded: $historyOpen) {
            if let historyError { Text(historyError).foregroundStyle(.red) }
            ForEach(history) { item in
                VStack(alignment: .leading) {
                    Text(item.createdAt).font(.caption).foregroundStyle(.secondary)
                    Text((item.before == nil ? "Создана: " : "Изменена: ") + item.after.title)
                    if item.before?.dueDate != item.after.dueDate || item.before?.dueTime != item.after.dueTime {
                        Text("Срок: " + [item.after.dueDate, item.after.dueTime].compactMap { $0 }.joined(separator: " "))
                    }
                }
            }
        }
        .task(id: historyOpen) {
            guard historyOpen else { return }
            do {
                history = try await model.taskHistory(task.id)
                historyError = nil
            } catch {
                if !Task.isCancelled { historyError = error.localizedDescription }
            }
        }
    }

    private var canSave: Bool {
        !model.saving && !model.loading && !stage.isEmpty
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!blocked || !blockedReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func save(returnAfter: Bool) async {
        let saved = await model.updateTask(task, changes: [
            "title": title, "description": description, "stage_id": stage,
            "project_id": projectID.map { $0 as Any } ?? NSNull(),
            "author_id": author.map { $0 as Any } ?? NSNull(),
            "priority": priority, "blocked": blocked, "blocked_reason": blockedReason,
            "dependencies": dependencies.sorted(),
            "assignee_id": assignee.map { $0 as Any } ?? NSNull(),
            "due_date": dueDate.isEmpty ? NSNull() as Any : dueDate,
            "due_time": dueTime.isEmpty || dueDate.isEmpty ? NSNull() as Any : dueTime
        ])
        if saved && returnAfter { returnToMeeting?() }
    }

    private func stages(for project: Int?) -> [Stage] {
        model.workspace?.projects.first { $0.id == project }?.stages ?? model.workspace?.defaultStages ?? []
    }
}
