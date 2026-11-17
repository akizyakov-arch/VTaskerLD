import SwiftUI

struct AssistantSearch: View {
    let tasks: [TaskItem]
    let today: String
    let projects: [Project]
    let currentProject: Project?
    let currentTask: TaskItem?
    let taskStages: (TaskItem) -> [Stage]
    let changeTaskStatus: (TaskItem, Stage) async -> String
    let people: [Person]
    let proposals: [Proposal]
    let meetings: [Meeting]
    let openTask: (Int) -> Void
    let openProject: (Int) -> Void
    let openProposal: (Proposal) -> Void
    let openMeeting: (Int) -> Void
    let canUseMicrophone: Bool
    let meetingRecording: Bool
    let liveTranscript: LiveTranscript?
    @Binding var liveRequests: [String]
    let prepareCreation: (AssistantCreation, Int?) -> Void
    let interpret: (String, Bool, Bool) async throws -> AssistantIntent
    let close: () -> Void

    private struct Message: Identifiable {
        let id = UUID()
        let text: String
        let isUser: Bool
    }

    private enum Step {
        case action, projectKind, existingProject, newProject, title, projectDateRole, review
    }

    @State private var query = ""
    @State private var liveProtocolExpanded = true
    @State private var awaitingStatusForTask: Int?
    @State private var awaitingStatusTaskName = false
    @State private var pendingStatusTarget = ""
    @State private var statusTaskChoices: [TaskItem] = []
    @State private var statusChoices: [Stage] = []
    @State private var changingStatus = false
    private enum Refinement {
        case assignee, project, deadline
    }

    @State private var searchQuery = ""
    @State private var refinement: Refinement?
    @State private var refinedAssignee: Person?
    @State private var refinedProject: Project?
    @State private var refinedDeadline: AssistantTaskFilters.Deadline?
    @State private var refinedDeadlineLabel: String?
    @State private var semanticTaskFilters = AssistantTaskFilters()
    @State private var messages = [Message(text: "Слушаю. Что найти или создать?", isUser: false)]
    @State private var draft: AssistantCreation?
    @State private var step: Step = .action
    @State private var selectedProject: Project?
    @State private var newProjectName: String?
    @AppStorage(AssistantVoicePreferences.silenceKey)
    private var silenceMilliseconds = AssistantVoicePreferences.defaultSilence
    @AppStorage(AssistantVoicePreferences.speakRepliesKey)
    private var speakReplies = true
    @StateObject private var voice = VoiceSearch()
    @StateObject private var speech = AssistantSpeech()
    @State private var voiceEnabled = true
    @State private var listenTurn = 0
    @State private var interpretation: Task<Void, Never>?
    @AppStorage("assistantSemanticInterpretation") private var semanticInterpretation = true
    @State private var projectChoices: [Project] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var listeningRequest: Int? {
        voiceEnabled && canUseMicrophone && !speech.isSpeaking && interpretation == nil && !changingStatus ? listenTurn : nil
    }

    private struct SearchResults {
        let projectListOnly: Bool
        let recognized: Bool
        let ambiguousAssignees: [Person]
        let tasks: [TaskItem]
        let projects: [Project]
        let proposals: [Proposal]

        var isEmpty: Bool {
            tasks.isEmpty && projects.isEmpty && proposals.isEmpty && ambiguousAssignees.isEmpty
        }

        var reply: String {
            if !ambiguousAssignees.isEmpty { return "Уточните, кого из исполнителей вы имеете в виду." }
            let names = tasks.map(\.title) + projects.map(\.title) +
                proposals.map { $0.title ?? "Предложение на подтверждение" }
            guard !names.isEmpty else { return "По этому запросу ничего не найдено." }
            let intro = "Найдено результатов: \(names.count). "
            let preview = names.prefix(3).joined(separator: ". ")
            return intro + preview + (names.count > 3 ? ". Остальные результаты в чате." : ".")
        }
    }

    private var searchResults: SearchResults {
        resultsForQuery(searchQuery, includeRefinements: true)
    }

    private func resultsForQuery(_ searchQuery: String, includeRefinements: Bool = false) -> SearchResults {
        let refinedAssignee = includeRefinements ? self.refinedAssignee : nil
        let refinedProject = includeRefinements ? self.refinedProject : nil
        let refinedDeadline = includeRefinements ? self.refinedDeadline : nil
        let extra = includeRefinements ? semanticTaskFilters : AssistantTaskFilters()
        let ignored: Set<String> = [
            "найди", "найдите", "найти", "покажи", "покажите", "выведи", "задачу", "задачи", "задача",
            "поручение", "в", "по", "с", "к", "все", "только", "задач", "теме", "исполнитель", "исполнителю", "для", "ранее",
            "запущенную", "была", "ее", "у", "на", "про", "мне", "пожалуйста", "открой", "откройте"
        ]
        let requestWords = tokens(searchQuery)
        let projectListWords: Set<String> = ["проекты", "проектов", "проееты"]
        let projectListOnly = requestWords.contains(where: projectListWords.contains) &&
            !requestWords.contains { $0.hasPrefix("задач") || $0.hasPrefix("поручен") }
        let activeProjectsOnly = requestWords.contains { $0.hasPrefix("актуальн") || $0.hasPrefix("активн") }
        let listModifiers: Set<String> = ["список", "какие", "каких", "которые", "сейчас", "есть"]
        let projectListTopic = requestWords.filter {
            !ignored.contains($0) && !projectListWords.contains($0) && !listModifiers.contains($0) &&
                !$0.hasPrefix("актуальн") && !$0.hasPrefix("активн")
        }
        let parsed = AssistantTaskFilters.parse(searchQuery, today: today)
        let filters = parsed.filters
        let words = tokens(parsed.remaining).filter { !ignored.contains($0) }
        let projectWords: Set<String> = ["проект", "проекте", "проекту", "проекта"]
        let scopeIndex = words.firstIndex { projectWords.contains($0) }
        let scope = projectScope(words, at: scopeIndex)
        let terms = scopeIndex.flatMap { index in
            scope.first.map { Array(words.prefix(index)) + Array(words.dropFirst(index + 1 + tokens($0.title).count)) }
        } ?? words
        let assignees = assigneeMatch(in: terms)
        let topic = terms.filter { $0 != assignees?.word }
        let assigneeIDs = Set(refinedAssignee.map { [$0.id] } ?? assignees?.people.map(\.id) ?? [])
        let taskOnly = filters.isActive || assignees != nil || refinedAssignee != nil ||
            refinedProject != nil || refinedDeadline != nil || tokens(searchQuery).contains { $0.hasPrefix("задач") }
        let canMatch = (scopeIndex == nil || !scope.isEmpty || refinedProject != nil) && assigneeIDs.count <= 1
        let scopeIDs = Set(refinedProject.map { [$0.id] } ?? scope.map(\.id))
        let matchingProposals = proposals.filter { proposal in
            guard !projectListOnly, canMatch, !filters.isActive, !extra.isActive, refinedDeadline == nil, !words.isEmpty, proposal.status == "pending", proposal.kind != "decision" else { return false }
            let target = tasks.first { $0.id == proposal.taskId }
            let meeting = meetings.first { $0.id == proposal.source?.meetingId }
            let projectID = proposal.projectId ?? target?.projectId ?? meeting?.projectId
            guard projectID.map({ id in projects.contains { $0.id == id } }) ?? true,
                  scopeIDs.isEmpty || projectID.map(scopeIDs.contains) == true else { return false }
            let assignee = proposal.proposed?.assigneeId ?? proposal.assigneeId ?? target?.assigneeId
            guard assigneeIDs.isEmpty || assignee.map(assigneeIDs.contains) == true else { return false }
            let person = people.first { $0.id == assignee }?.name
            let project = projects.first { $0.id == projectID }?.title
            return matches(topic, in: [proposal.title, proposal.description, proposal.source?.quote, project, person,
                                       meeting?.title, target?.title, target?.description])
        }
        let matchingTasks = tasks.filter { task in
            guard !projectListOnly, canMatch,
                  scopeIDs.isEmpty || task.projectId.map(scopeIDs.contains) == true,
                  assigneeIDs.isEmpty || task.assigneeId.map(assigneeIDs.contains) == true,
                  !(filters.overdueOnly || extra.overdueOnly) || task.overdue,
                  !(filters.blockedOnly || extra.blockedOnly) || task.blocked == true,
                  !(filters.unassignedOnly || extra.unassignedOnly) || task.assigneeId == nil,
                  !(filters.noProjectOnly || extra.noProjectOnly) || task.projectId == nil,
                  filters.stage.map({ $0 == task.stageKind }) ?? true,
                  filters.priority.map({ $0 == (task.priority ?? "normal") }) ?? true,
                  filters.deadline?.matches(task.dueDate) ?? true,
                  refinedDeadline?.matches(task.dueDate) ?? true,
                  extra.deadline?.matches(task.dueDate) ?? true,
                  extra.stage.map({ $0 == task.stageKind }) ?? true,
                  extra.priority.map({ $0 == (task.priority ?? "normal") }) ?? true else { return false }
            let project = projects.first { $0.id == task.projectId }?.title
            let person = people.first { $0.id == task.assigneeId }?.name
            let context = (task.sources ?? []).flatMap { source in
                [source.quote, meetings.first { $0.id == source.meetingId }?.title]
            }
            return matches(topic, in: [task.title, task.description, project, person] + context)
        }
        let foundProjects = scopeIndex == nil
            ? projects.filter { !words.isEmpty && matches(words, in: [$0.title, $0.description]) }
            : scope
        let listedProjects = projects.filter { project in
            (!activeProjectsOnly || project.status == "active") &&
                matches(projectListTopic, in: [project.title, project.description])
        }
        let matchingProjects = projectListOnly ? listedProjects : (taskOnly ? [] : foundProjects)
        return SearchResults(projectListOnly: projectListOnly,
                             recognized: (projectListOnly && projectListTopic.isEmpty) || (taskOnly && topic.isEmpty),
                             ambiguousAssignees: !projectListOnly && assigneeIDs.count > 1 ? assignees?.people ?? [] : [],
                             tasks: matchingTasks, projects: matchingProjects, proposals: matchingProposals)
    }

    var body: some View {
        let results = searchResults
        VStack(spacing: 0) {
            HStack {
                WindowCloseButton(label: "Закрыть ассистента", action: close)
                    .keyboardShortcut(.cancelAction)
                NavigationBackButton(action: close)
                TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !voiceEnabled || !canUseMicrophone || reduceMotion)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate * .pi / 1.4
                    let pulse = voiceEnabled && canUseMicrophone && !reduceMotion ? 0.65 + 0.35 * cos(phase) : 1
                    Image(systemName: "sparkles")
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor.opacity(0.24 * pulse), in: Circle())
                        .foregroundStyle(Color.accentColor)
                        .opacity(voiceEnabled ? 1 : 0.55)
                }
                .accessibilityHidden(true)
                Text("Валли").font(.title2.bold())
                Spacer()
            }
            .padding(16)
            Divider()
            if let liveTranscript {
                liveProtocol(liveTranscript)
                Divider()
            }
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { message in
                            Text(message.text)
                                .textSelection(.enabled)
                                .padding(10)
                                .background(message.isUser ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10),
                                            in: RoundedRectangle(cornerRadius: 12))
                                .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
                                .accessibilityLabel((message.isUser ? "Вы. " : "Ассистент. ") + message.text)
                        }
                        if let task = statusTask(awaitingStatusForTask) {
                            ForEach(statusChoices) { stage in
                                Button(stage.title) { applyTaskStatus(stage, to: task) }
                            }
                        }
                        ForEach(statusTaskChoices) { task in
                            let project = projects.first { $0.id == task.projectId }?.title ?? "Без проекта"
                            Button(task.title + " · " + project) {
                                if let latest = statusTask(task.id) {
                                    requestTaskStatus(pendingStatusTarget, for: latest)
                                }
                            }
                        }
                        if projectChoices.isEmpty {
                            choices
                        } else {
                            ForEach(projectChoices) { project in
                                Button(project.title) { showProject(project) }
                            }
                        }
                        if !searchQuery.isEmpty {
                            if !results.projectListOnly { searchRefinementOptions }
                            if !results.ambiguousAssignees.isEmpty {
                                Text("Выберите исполнителя.").foregroundStyle(.secondary)
                                ForEach(results.ambiguousAssignees) { person in
                                    Button(person.name) { applyAssignee(person) }
                                }
                            } else if results.tasks.isEmpty && results.projects.isEmpty && results.proposals.isEmpty {
                                Text("Ничего не найдено. Попробуйте уточнить название.").foregroundStyle(.secondary)
                            }
                            ForEach(results.tasks) { task in
                                VStack(alignment: .leading, spacing: 3) {
                                    Button(task.title + " · " + (task.overdue ? "Просрочена" : task.stageTitle)) {
                                        openTask(task.id)
                                    }.buttonStyle(.link)
                                    if meetingRecording {
                                        let assignee = people.first { $0.id == task.assigneeId }?.name ?? "Без исполнителя"
                                        let due = task.dueDate.map { [$0, task.dueTime].compactMap { $0 }.joined(separator: " ") }
                                        Text(assignee + " · " + (due ?? "Без срока"))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            ForEach(results.proposals) { proposal in
                                HStack {
                                    Button((proposal.title ?? "Предложение") + " · На подтверждение") { openProposal(proposal) }
                                    if let id = proposal.source?.meetingId {
                                        Button("К встрече") { openMeeting(id) }
                                    }
                                }.buttonStyle(.link)
                            }
                            ForEach(results.projects) { project in
                                Button("Проект · " + project.title) { openProject(project.id) }.buttonStyle(.link)
                            }
                        }
                        Color.clear.frame(height: 1).id("chat-end")
                    }
                    .padding(14)
                }
                .onChange(of: messages.count) { _ in scroll.scrollTo("chat-end", anchor: .bottom) }
            }
            Divider()
            if changingStatus {
                Text("Сохраняю статус…").font(.caption).foregroundStyle(.secondary)
            } else if interpretation != nil {
                Text("Разбираю запрос…").font(.caption).foregroundStyle(.secondary)
            }
            if let error = voice.error {
                Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14)
            } else if !canUseMicrophone {
                Text(meetingRecording ? "Скажи «Валли, найди задачу…» или напиши запрос." : "Можно написать запрос.").font(.caption)
                    .foregroundStyle(.secondary).padding(.horizontal, 14)
            } else if speech.isSpeaking {
                Button("Остановить озвучивание") { speech.stop() }
                    .buttonStyle(.link).font(.caption)
            } else if voice.listening {
                Text("Слушаю…").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Напишите или скажите…", text: $query)
                    .onSubmit(submit)
                Button {
                    if voiceEnabled {
                        voiceEnabled = false
                        interpretation?.cancel()
                        interpretation = nil
                        voice.stop()
                        speech.stop()
                    } else {
                        voiceEnabled = true
                    }
                } label: {
                    Label(voiceEnabled ? "Стоп" : "Голос",
                          systemImage: voiceEnabled ? "stop.circle.fill" : "mic")
                }
                .disabled(!voiceEnabled && !canUseMicrophone)
                .accessibilityLabel(voiceEnabled ? "Остановить голосовой диалог" : "Включить голосовой диалог")
                Button(action: submit) { Image(systemName: "arrow.up.circle.fill") }
                    .accessibilityLabel("Отправить")
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(14)
        }
        .task(id: listeningRequest) {
            guard listeningRequest != nil else { return }
            // Give the output device time to finish playing the synthesized audio.
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard listeningRequest != nil, !Task.isCancelled else { return }
            await voice.start(silenceMilliseconds: silenceMilliseconds)
        }
        .onChange(of: voice.text) { value in
            if !value.isEmpty { query = value }
        }
        .onChange(of: voice.completedText) { message in
            if let message, voiceEnabled, canUseMicrophone {
                query = message
                submit()
            }
        }
        .onChange(of: voice.listening) { listening in
            if !listening && listeningRequest != nil && voice.completedText == nil && voice.error == nil {
                listenTurn += 1
            }
        }
        .onChange(of: voice.error) { error in
            if error != nil { voiceEnabled = false }
        }
        .onChange(of: canUseMicrophone) { available in
            if !available { voice.stop() }
        }
        .onAppear(perform: handleLiveRequests)
        .onChange(of: currentTask?.id) { _ in clearStatusRequest() }
        .onChange(of: liveRequests) { _ in handleLiveRequests() }
        .onChange(of: meetingRecording) { recording in
            if recording { speech.stop() }
        }
        .onChange(of: speakReplies) { enabled in
            if !enabled { speech.stop() }
        }
        .onDisappear {
            interpretation?.cancel()
            interpretation = nil
            voice.stop()
            speech.stop()
        }
    }

    private func liveProtocol(_ transcript: LiveTranscript) -> some View {
        let chunks = transcript.chunks.filter { $0.state == "completed" && !$0.segments.isEmpty }
        return DisclosureGroup("Живой протокол", isExpanded: $liveProtocolExpanded) {
            if let preview = transcript.aiPreview {
                DisclosureGroup("Предварительный анализ ИИ") {
                    if preview.running { ProgressView("Анализирую новые фрагменты…").progressViewStyle(.linear) }
                    if let error = preview.error { Text(error).font(.caption).foregroundStyle(.red) }
                    if let result = preview.result {
                        if let summary = result.summary { Text(summary).textSelection(.enabled) }
                        ForEach(Array((result.tasks ?? []).enumerated()), id: \.offset) { _, task in
                            if let title = task.title { Label(title, systemImage: "checklist") }
                        }
                    }
                }
            }
            if let reason = transcript.reason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            if chunks.isEmpty && transcript.reason == nil {
                Text("Ждём расшифровку…").font(.caption).foregroundStyle(.secondary)
            }
            if !chunks.isEmpty {
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(chunks) { chunk in
                                Text(chunk.segments.map(\.text).joined(separator: " "))
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 170)
                    .onAppear { if let id = chunks.last?.id { scroll.scrollTo(id, anchor: .bottom) } }
                    .onChange(of: chunks.last?.id) { id in
                        if let id { scroll.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .id(transcript.sessionId)
    }

    private func handleLiveRequests() {
        guard !liveRequests.isEmpty else { return }
        let requests = liveRequests
        liveRequests.removeAll()
        interpretation?.cancel()
        interpretation = nil
        reset()
        for request in requests {
            append("Валли, " + request, user: true)
            searchQuery = request
            append(searchResults.reply)
        }
    }

    @ViewBuilder
    private var choices: some View {
        switch step {
        case .action:
            ForEach([Creation.meeting, .task, .decision, .project]) { kind in
                Button(kind.rawValue) {
                    append(kind.rawValue, user: true)
                    begin(.init(kind: kind, title: "", projectName: nil, startsRecording: false))
                }
            }
        case .projectKind:
            Button("Существующий проект") { answerProjectKind(existing: true) }
            Button("Новый проект") { answerProjectKind(existing: false) }
            if draft?.kind != .decision {
                Button("Без проекта") {
                    append("Без проекта", user: true)
                    askForTitle()
                }
            }
        case .existingProject:
            if projects.isEmpty { Text("Рабочих проектов пока нет.").foregroundStyle(.secondary) }
            ForEach(projects) { project in
                Button(project.title) { choose(project) }
            }
            Button("Создать новый проект") { answerProjectKind(existing: false) }
        case .projectDateRole:
            Button("Дата начала") { setProjectDate(isStart: true) }
            Button("Срок завершения") { setProjectDate(isStart: false) }
        case .review:
            Button("Проверить и сохранить") { review() }.buttonStyle(.borderedProminent)
        case .newProject, .title:
            EmptyView()
        }
        if step != .action {
            Button("Отменить запрос") {
                reset()
                append("Запрос отменён. Что сделать дальше?")
            }.buttonStyle(.link)
        }
    }

    private func append(_ text: String, user: Bool = false) {
        messages.append(Message(text: text, isUser: user))
        if !user {
            if voiceEnabled && speakReplies && !meetingRecording {
                voice.stop()
                speech.speak(text)
            }
            listenTurn += 1
        }
    }

    private func reset() {
        step = .action
        draft = nil
        selectedProject = nil
        newProjectName = nil
        searchQuery = ""
        projectChoices = []
        clearRefinements()
    }

    private func statusTask(_ id: Int?) -> TaskItem? {
        guard let id else { return nil }
        return tasks.first { $0.id == id }
    }

    private func clearStatusRequest() {
        awaitingStatusForTask = nil
        awaitingStatusTaskName = false
        pendingStatusTarget = ""
        statusChoices = []
        statusTaskChoices = []
    }

    private func requestNamedStatus(_ phrase: String, fallbackTarget: String = "") {
        clearStatusRequest()
        let parts = AssistantTaskStatus.destinations(in: phrase)
        let candidates = [(name: phrase, target: fallbackTarget)] + parts
        for candidate in candidates where !candidate.name.isEmpty {
            let words = tokens(candidate.name)
            let exact = tasks.filter { tokens($0.title) == words }
            if exact.count == 1, let task = exact.first {
                requestTaskStatus(candidate.target, for: task)
                return
            }
            if !exact.isEmpty {
                offerStatusTasks(exact, target: candidate.target)
                return
            }
        }
        if let destination = parts.first(where: { $0.name.isEmpty }), let currentTask {
            requestTaskStatus(destination.target, for: currentTask)
            return
        }
        let candidate = parts.first ?? (name: phrase, target: fallbackTarget)
        if !candidate.name.isEmpty {
            let words = tokens(candidate.name)
            let related = words.isEmpty ? [] : tasks.filter { matches(words, in: [$0.title]) }
            if !related.isEmpty {
                offerStatusTasks(related, target: candidate.target)
                return
            }
        }
        awaitingStatusTaskName = true
        pendingStatusTarget = candidate.target
        append(candidate.name.isEmpty ? "Какую задачу перенести?" :
               "Не нашёл задачу «\(candidate.name)». Назовите её точнее.")
    }

    private func offerStatusTasks(_ options: [TaskItem], target: String) {
        statusTaskChoices = options
        pendingStatusTarget = target
        awaitingStatusTaskName = true
        append("Выберите задачу, которую нужно перенести.")
    }

    private func requestTaskStatus(_ target: String, for task: TaskItem) {
        clearStatusRequest()
        let stages = taskStages(task)
        let matches = AssistantTaskStatus.matches(target, stages: stages)
        if matches.count == 1, let stage = matches.first {
            applyTaskStatus(stage, to: task)
        } else {
            awaitingStatusForTask = task.id
            statusChoices = matches.isEmpty ? stages : matches
            append(target.isEmpty ? "В какой статус перевести «\(task.title)»?" :
                   "Уточните статус для «\(task.title)». Можно выбрать из списка.")
        }
    }

    private func applyTaskStatus(_ stage: Stage, to task: TaskItem) {
        guard !changingStatus, taskStages(task).contains(where: { $0.id == stage.id }) else { return }
        clearStatusRequest()
        if task.stageId == stage.id {
            append("«\(task.title)» уже в статусе «\(stage.title)».")
            return
        }
        changingStatus = true
        voice.stop()
        Task {
            let reply = await changeTaskStatus(task, stage)
            changingStatus = false
            append(reply)
        }
    }

    private func submit() {
        guard !changingStatus else { return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        query = ""
        guard !text.isEmpty else { return }
        interpretation?.cancel()
        interpretation = nil
        voice.stop()
        let choosingProject = !projectChoices.isEmpty
        projectChoices = []
        append(text, user: true)
        let normalized = AssistantCreation.normalize(text)
        if ["отмена", "отмени", "отменить"].contains(normalized) {
            clearStatusRequest()
            reset()
            append("Запрос отменён. Что сделать дальше?")
            return
        }
        if let phrase = AssistantTaskStatus.movePhrase(in: text) {
            requestNamedStatus(phrase)
            return
        }
        if let target = AssistantTaskStatus.target(in: text) {
            if let task = statusTask(awaitingStatusForTask) ?? currentTask {
                requestTaskStatus(target, for: task)
            } else {
                append("Откройте карточку задачи или скажите «Перенеси задачу» и назовите её.")
            }
            return
        }
        if let task = statusTask(awaitingStatusForTask) {
            requestTaskStatus(normalized, for: task)
            return
        }
        if awaitingStatusTaskName {
            requestNamedStatus(normalized, fallbackTarget: pendingStatusTarget)
            return
        }
        if let command = AssistantCreation.parse(text, today: today) {
            if semanticInterpretation && command.kind == .task && !command.title.isEmpty {
                interpretRequest(text, fallback: command)
            } else {
                begin(command)
            }
            return
        }
        switch step {
        case .action:
            if let prefix = normalized.range(of: #"^(?:открой|откройте|открыть)\s+(?:мне\s+)?проект(?:\s+|$)"#, options: .regularExpression) {
                openNamedProject(String(normalized[prefix.upperBound...]))
            } else if AssistantCreation.isCreationRequest(text) {
                if semanticInterpretation { interpretRequest(text) }
                else { append("Что нужно создать? Выберите действие.") }
            } else if choosingProject && projects.contains(where: { tokens($0.title) == tokens(text) }) {
                openNamedProject(text)
            } else if !handleRefinement(text) {
                let results = resultsForQuery(text)
                if semanticInterpretation && results.isEmpty && !results.recognized {
                    interpretRequest(text)
                } else {
                    clearRefinements()
                    searchQuery = text
                    append(searchResults.reply)
                }
            }
        case .projectKind:
            if normalized.hasPrefix("нов") { answerProjectKind(existing: false, echo: false) }
            else if normalized.hasPrefix("существ") { answerProjectKind(existing: true, echo: false) }
            else if normalized == "без проекта", draft?.kind != .decision { askForTitle() }
            else { findProject(text) }
        case .existingProject: findProject(text)
        case .newProject:
            newProjectName = text
            askForTitle()
        case .title:
            draft?.title = text
            askForTitle()
        case .projectDateRole:
            if normalized.contains("начал") { setProjectDate(isStart: true) }
            else if normalized.contains("срок") || normalized.contains("заверш") || normalized.contains("окончан") {
                setProjectDate(isStart: false)
            } else {
                append("Выберите дату начала или срок завершения.")
            }
        case .review:
            if ["да", "продолжить", "подтверждаю", "сохранить", "проверь"].contains(normalized) { review() }
            else { append("Откройте форму для проверки или отмените запрос.") }
        }
    }

    private func interpretRequest(_ text: String, fallback: AssistantCreation? = nil) {
        let hasSearch = !searchQuery.isEmpty && !searchResults.projectListOnly
        let hasProject = currentProject != nil
        interpretation = Task {
            do {
                let intent = try await interpret(text, hasSearch, hasProject)
                guard !Task.isCancelled else { return }
                interpretation = nil
                if let fallback, intent.action != .createTask {
                    begin(fallback)
                } else {
                    applyIntent(intent)
                }
            } catch {
                guard !Task.isCancelled else { return }
                interpretation = nil
                if let fallback {
                    append("Автозаполнение недоступно. Проверьте название и заполните поля задачи в форме.")
                    begin(fallback)
                } else {
                    append("Не удалось разобрать фразу по смыслу. " + error.localizedDescription +
                           " Можно уточнить запрос или выбрать действие ниже.")
                }
            }
        }
    }

    private func applyIntent(_ intent: AssistantIntent) {
        let title = intent.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch intent.action {
        case .createProject, .createTask, .createMeeting, .startMeeting, .createDecision:
            let kind: Creation
            switch intent.action {
            case .createProject: kind = .project
            case .createTask: kind = .task
            case .createDecision: kind = .decision
            default: kind = .meeting
            }
            var command = AssistantCreation(kind: kind, title: title, projectName: intent.project,
                                            startsRecording: intent.action == .startMeeting)
            if kind == .task {
                let name = intent.assignee ?? ""
                let exact = people.filter { tokens($0.name) == tokens(name) }
                let candidates = exact.isEmpty ? assigneeMatch(in: tokens(name))?.people ?? [] : exact
                let assignee = candidates.count == 1 ? candidates.first?.name : intent.assignee
                command.taskFields = .init(assignee: assignee, description: intent.description,
                                           dueDate: intent.dueDate, dueTime: intent.dueTime, priority: intent.priority)
            }
            begin(command)
        case .openProject:
            openNamedProject(intent.project ?? "")
        case .listProjects:
            clearRefinements()
            let filter = intent.filters ?? ""
            searchQuery = filter.contains("активн") || filter.contains("актуальн") ? "активные проекты" : "проекты"
            append(searchResults.reply)
        case .searchTasks, .refineTasks:
            applyTaskIntent(intent, title: title)
        case .clarify:
            append("Уточните, что показать, открыть или создать.")
        }
    }

    private func applyTaskIntent(_ intent: AssistantIntent, title: String) {
        if intent.action == .searchTasks || searchQuery.isEmpty || searchResults.projectListOnly {
            clearRefinements()
            searchQuery = ["задачи", title, intent.filters].compactMap { $0 }.joined(separator: " ")
        } else if let filters = intent.filters {
            let parsed = AssistantTaskFilters.parse(filters, today: today).filters
            if let deadline = parsed.deadline {
                refinedDeadline = deadline
                refinedDeadlineLabel = filters
            }
            semanticTaskFilters.stage = parsed.stage ?? semanticTaskFilters.stage
            semanticTaskFilters.priority = parsed.priority ?? semanticTaskFilters.priority
            semanticTaskFilters.blockedOnly = semanticTaskFilters.blockedOnly || parsed.blockedOnly
            semanticTaskFilters.overdueOnly = semanticTaskFilters.overdueOnly || parsed.overdueOnly
            semanticTaskFilters.unassignedOnly = semanticTaskFilters.unassignedOnly || parsed.unassignedOnly
            semanticTaskFilters.noProjectOnly = semanticTaskFilters.noProjectOnly || parsed.noProjectOnly
        }
        if let name = intent.project, !name.isEmpty {
            let matches = projects.filter { tokens($0.title) == tokens(name) }
            guard matches.count == 1, let project = matches.first else {
                askRefinement(.project)
                return
            }
            refinedProject = project
        }
        if let name = intent.assignee, !name.isEmpty {
            let exact = people.filter { tokens($0.name) == tokens(name) }
            let matches = exact.isEmpty ? assigneeMatch(in: tokens(name))?.people ?? [] : exact
            guard matches.count == 1, let person = matches.first else {
                askRefinement(.assignee)
                return
            }
            refinedAssignee = person
        }
        append(searchResults.reply)
    }

    @ViewBuilder
    private var searchRefinementOptions: some View {
        let details = [refinedAssignee?.name, refinedProject?.title, refinedDeadlineLabel].compactMap { $0 }
        if !details.isEmpty {
            Text("Уточнения · " + details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
        }
        switch refinement {
        case .assignee:
            ForEach(people) { person in
                Button(person.name) { applyAssignee(person) }
            }
        case .project:
            ForEach(projects) { project in
                Button(project.title) { applyProject(project) }
            }
        case .deadline:
            HStack {
                ForEach(["Сегодня", "Завтра", "Без срока"], id: \.self) { label in
                    Button(label) { applyDeadline(label) }
                }
            }
        case nil:
            HStack {
                Button("Исполнитель") { askRefinement(.assignee) }
                Button("Проект") { askRefinement(.project) }
                Button("Дата") { askRefinement(.deadline) }
            }
        }
    }

    private func clearRefinements() {
        refinement = nil
        refinedAssignee = nil
        refinedProject = nil
        refinedDeadline = nil
        refinedDeadlineLabel = nil
        semanticTaskFilters = AssistantTaskFilters()
    }

    private func askRefinement(_ field: Refinement) {
        refinement = field
        switch field {
        case .assignee: append("Укажите исполнителя.")
        case .project: append("Укажите проект.")
        case .deadline: append("Укажите срок, например «завтра» или «06.11».")
        }
    }

    private func handleRefinement(_ text: String) -> Bool {
        guard !searchQuery.isEmpty else { return false }
        let normalized = AssistantCreation.normalize(text)
        let fresh = ["покажи", "покажите", "найди", "найдите", "выведи"].contains(tokens(text).first ?? "")
        if fresh { return false }
        let value = normalized.replacingOccurrences(of: #"^а\s+"#, with: "", options: .regularExpression)
        let prefixes: [(String, Refinement)] = [
            (#"^по\s+исполнител[юя](?:\s+|$)"#, .assignee),
            (#"^по\s+проекту(?:\s+|$)"#, .project),
            (#"^по\s+(?:дате|сроку)(?:\s+|$)"#, .deadline)
        ]
        var answer = value
        var field = refinement
        for (pattern, candidate) in prefixes {
            if let prefix = value.range(of: pattern, options: .regularExpression) {
                field = candidate
                answer = String(value[prefix.upperBound...])
                break
            }
        }
        if field == nil {
            let parsed = AssistantTaskFilters.parse(answer, today: today)
            let words = tokens(answer)
            if parsed.filters.deadline != nil && tokens(parsed.remaining).isEmpty {
                field = .deadline
            } else if projects.contains(where: { tokens($0.title) == words }) {
                field = .project
            } else if people.contains(where: { tokens($0.name) == words }) ||
                        (words.count == 1 && assigneeMatch(in: words) != nil) {
                field = .assignee
            }
        }
        guard let field else { return false }
        guard !answer.isEmpty else {
            askRefinement(field)
            return true
        }
        switch field {
        case .assignee:
            let words = tokens(answer)
            let exact = people.filter { tokens($0.name) == words }
            let candidates = exact.isEmpty ? assigneeMatch(in: words)?.people ?? [] : exact
            if candidates.count == 1, let person = candidates.first { applyAssignee(person) }
            else { askRefinement(.assignee) }
        case .project:
            let candidates = projects.filter { tokens($0.title) == tokens(answer) }
            if candidates.count == 1, let project = candidates.first { applyProject(project) }
            else { askRefinement(.project) }
        case .deadline:
            applyDeadline(answer)
        }
        return true
    }

    private func applyAssignee(_ person: Person) {
        refinedAssignee = person
        refinement = nil
        append("Исполнитель «" + person.name + "». " + searchResults.reply)
    }

    private func applyProject(_ project: Project) {
        refinedProject = project
        refinement = nil
        append("Проект «" + project.title + "». " + searchResults.reply)
    }

    private func applyDeadline(_ text: String) {
        guard let deadline = AssistantTaskFilters.parse(text, today: today).filters.deadline else {
            askRefinement(.deadline)
            return
        }
        refinedDeadline = deadline
        refinedDeadlineLabel = text
        refinement = nil
        append("Срок «" + text + "». " + searchResults.reply)
    }

    private func openNamedProject(_ name: String) {
        searchQuery = ""
        clearRefinements()
        let words = tokens(name)
        let exact = projects.filter { tokens($0.title) == words }
        let candidates = exact.isEmpty ? similarProjects(to: words) : exact
        if candidates.count == 1, let project = candidates.first {
            showProject(project)
        } else {
            projectChoices = candidates.isEmpty ? projects : candidates
            append(projectChoices.isEmpty ? "Нет доступных проектов." :
                   candidates.isEmpty && !name.isEmpty ? "Проект «" + name + "» не найден. Выберите из списка." :
                   "Какой проект открыть?")
        }
    }

    private func similarProjects(to words: [String]) -> [Project] {
        projects.filter { project in
            let title = tokens(project.title)
            return !words.isEmpty && words.count == title.count &&
                zip(words, title).allSatisfy { oneEditApart($0.0, $0.1) }
        }
    }

    private func showProject(_ project: Project) {
        projectChoices = []
        openProject(project.id)
        append("Открыла проект «" + project.title + "».")
    }

    private func oneEditApart(_ first: String, _ second: String) -> Bool {
        if first == second { return true }
        let shorter = Array(first.count <= second.count ? first : second)
        let longer = Array(first.count <= second.count ? second : first)
        guard shorter.count >= 4, longer.count - shorter.count <= 1 else { return false }
        if shorter.count == longer.count {
            return zip(shorter, longer).filter { $0.0 != $0.1 }.count == 1
        }
        let difference = zip(shorter, longer).prefix { $0.0 == $0.1 }.count
        return shorter.dropFirst(difference).elementsEqual(longer.dropFirst(difference + 1))
    }

    private func begin(_ command: AssistantCreation) {
        voice.stop()
        reset()
        draft = command
        if command.kind == .project {
            askForTitle()
        } else if let projectName = command.projectName, !projectName.isEmpty {
            findProject(projectName)
        } else if command.projectName == nil, let currentProject, currentProject.archived != true {
            choose(currentProject, echo: false)
        } else {
            step = .projectKind
            append("Для нового или существующего проекта?")
        }
    }

    private func answerProjectKind(existing: Bool, echo: Bool = true) {
        if echo { append(existing ? "Существующий проект" : "Новый проект", user: true) }
        step = existing ? .existingProject : .newProject
        append(existing ? "Выберите проект или скажите его название." : "Как назвать новый проект?")
    }

    private func findProject(_ name: String) {
        let words = tokens(name)
        let matching = projects.filter { tokens($0.title) == words }
        if matching.count == 1, let project = matching.first {
            choose(project, echo: false)
        } else {
            step = .existingProject
            if matching.isEmpty, let suggestion = similarProjects(to: words).first {
                append("Возможно, вы имели в виду проект «" + suggestion.title + "». Выберите его или скажите точное название.")
                return
            }
            append(matching.isEmpty
                   ? "Проект «" + name + "» не найден. Выберите из списка или создайте новый."
                   : "Есть несколько проектов с названием «" + name + "». Выберите нужный из списка.")
        }
    }

    private func choose(_ project: Project, echo: Bool = true) {
        if echo { append(project.title, user: true) }
        selectedProject = project
        if let draft, draft.startsRecording && draft.title.isEmpty {
            self.draft = .init(kind: .meeting, title: "Совещание · " + project.title,
                               projectName: draft.projectName, startsRecording: true)
        }
        askForTitle()
    }

    private func askForTitle() {
        guard let draft else { return }
        if draft.title.isEmpty {
            step = .title
            append(draft.kind == .decision ? "Как сформулировать решение?" : "Как назвать?")
        } else if let date = draft.projectFields?.unspecifiedDate {
            step = .projectDateRole
            append("Дата «" + date + "» означает начало проекта или срок завершения?")
        } else {
            step = .review
            let context: String
            if let selectedProject {
                context = " · проект «" + selectedProject.title + "»"
            } else if let newProjectName {
                context = " · новый проект «" + newProjectName + "»"
            } else {
                context = ""
            }
            let next = draft.startsRecording
                ? " Скажите «да», чтобы открыть форму и сохранить совещание."
                : " Проверьте перед сохранением."
            append(draft.kind.rawValue + " · «" + draft.title + "»" + context + "." + next)
        }
    }

    private func setProjectDate(isStart: Bool) {
        guard let date = draft?.projectFields?.unspecifiedDate else { return }
        if isStart { draft?.projectFields?.start = date }
        else { draft?.projectFields?.end = date }
        draft?.projectFields?.unspecifiedDate = nil
        askForTitle()
    }

    private func review() {
        guard let draft else { return }
        voice.stop()
        let command = AssistantCreation(kind: draft.kind, title: draft.title, projectName: newProjectName,
                                        startsRecording: draft.startsRecording, projectFields: draft.projectFields,
                                        taskFields: draft.taskFields)
        let projectID = selectedProject?.id
        reset()
        append("Открыл форму для проверки. В ней можно подтвердить или отменить сохранение.")
        prepareCreation(command, projectID)
    }

    private func tokens(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private func similar(_ first: String, _ second: String) -> Bool {
        first == second || ["закуп", "ткан"].contains { first.hasPrefix($0) && second.hasPrefix($0) }
            || (first.count >= 5 && second.count >= 5 && first.dropLast() == second.dropLast())
    }

    private func matches(_ words: [String], in fields: [String?]) -> Bool {
        let searchable = tokens(fields.compactMap { $0 }.joined(separator: " "))
        return words.allSatisfy { word in searchable.contains { similar(word, $0) } }
    }

    private func assigneeMatch(in terms: [String]) -> (word: String, people: [Person])? {
        let sashaForms: Set<String> = ["саша", "саши", "саше", "сашу", "сашей", "саш"]
        for word in terms {
            let exact = people.filter { tokens($0.name).contains(word) }
            if !exact.isEmpty { return (word, exact) }
            if sashaForms.contains(word) {
                let matches = people.filter { person in
                    guard let firstName = tokens(person.name).first else { return false }
                    return sashaForms.contains(firstName) || ["александр", "александра"].contains(firstName)
                }
                if !matches.isEmpty { return (word, matches) }
            }
            let inflected = people.filter { person in
                guard let firstName = tokens(person.name).first else { return false }
                return similar(word, firstName) ||
                    (word.count > 4 && ["а", "я", "у", "ю", "ом", "ем"].contains { word == firstName + $0 })
            }
            if !inflected.isEmpty { return (word, inflected) }
        }
        return nil
    }

    private func projectScope(_ words: [String], at index: Int?) -> [Project] {
        guard let index else { return [] }
        let suffix = words.dropFirst(index + 1)
        let candidates = projects.compactMap { project -> (project: Project, length: Int)? in
            let name = tokens(project.title)
            guard !name.isEmpty, name.count <= suffix.count,
                  zip(name, suffix).allSatisfy({ similar($0.0, $0.1) }) else { return nil }
            return (project, name.count)
        }
        guard let longest = candidates.map(\.length).max() else { return [] }
        return candidates.filter { $0.length == longest }.map(\.project)
    }

}
