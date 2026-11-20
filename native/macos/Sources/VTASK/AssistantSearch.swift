import SwiftUI

struct AssistantSearch: View {
    let tasks: [TaskItem]
    let today: String
    let projects: [Project]
    let currentProject: Project?
    let searchProject: Project?
    let currentTask: TaskItem?
    let taskStages: (TaskItem) -> [Stage]
    let changeTaskStatus: (TaskItem, Stage) async -> String
    let people: [Person]
    let proposals: [Proposal]
    let meetings: [Meeting]
    let openTask: (Int) -> Void
    let openProject: (Int) -> Void
    let openProposal: (Proposal) -> Void
    let canUseMicrophone: Bool
    let meetingRecording: Bool
    let liveTranscript: LiveTranscript?
    @Binding var liveRequests: [String]
    let interpret: (String, Bool, Bool, Bool, AssistantTaskUpdate?) async throws -> AssistantIntent
    let submitLocalCommand: (String, Int?, Int?, AssistantTaskUpdate?) async -> (id: Int?, error: String?)
    let close: () -> Void

    private struct Message: Identifiable {
        let id = UUID()
        let text: String
        let isUser: Bool
    }

    private enum TaskCommandScope {
        case project(Int)
        case unassigned

        var projectID: Int? {
            if case .project(let id) = self { return id }
            return nil
        }
    }

    private struct PendingTaskCommand {
        var action: String
        var title: String
        var editsDeadline = false
        var update: AssistantTaskUpdate?
        var scope: TaskCommandScope?
        var search = ""
        var selected: TaskCommandTarget?
    }

    private enum TaskCommandTarget: Identifiable {
        case task(TaskItem)
        case proposal(Proposal)

        var id: String {
            switch self {
            case .task(let task): return "task-\(task.id)"
            case .proposal(let proposal): return "proposal-\(proposal.id)"
            }
        }

        var title: String {
            switch self {
            case .task(let task): return task.title
            case .proposal(let proposal): return proposal.reviewDraft?.data.title ?? proposal.displayTitle
            }
        }

        var label: String {
            switch self {
            case .task: return title
            case .proposal: return title + " · На подтверждении"
            }
        }
    }

    @State private var query = ""
    @State private var liveProtocolExpanded = true
    @State private var awaitingStatusForTask: Int?
    @State private var awaitingStatusTaskName = false
    @State private var pendingStatusTarget = ""
    @State private var statusTaskChoices: [TaskItem] = []
    @State private var statusChoices: [Stage] = []
    @State private var changingStatus = false
    @State private var sendingLocalCommand = false
    @State private var localProposalID: Int?
    @State private var pendingTaskCommand: PendingTaskCommand?
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
    @State private var messages = [Message(text: "Слушаю. Что найти или изменить?", isUser: false)]
    @AppStorage(AssistantVoicePreferences.silenceKey)
    private var silenceMilliseconds = AssistantVoicePreferences.defaultSilence
    @AppStorage(AssistantVoicePreferences.speakRepliesKey)
    private var speakReplies = true
    @StateObject private var voice = VoiceSearch()
    @StateObject private var speech = AssistantSpeech()
    @State private var voiceEnabled = false
    @State private var listenTurn = 0
    @State private var interpretation: Task<Void, Never>?
    @AppStorage("assistantSemanticInterpretation") private var semanticInterpretation = true
    @State private var projectChoices: [Project] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var listeningRequest: Int? {
        voiceEnabled && canUseMicrophone && !speech.isSpeaking && interpretation == nil && !changingStatus && !sendingLocalCommand ? listenTurn : nil
    }

    private struct SearchResults {
        let projectListOnly: Bool
        let projectScope: String?
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

    private func proposalProjectID(_ proposal: Proposal) -> Int? {
        if let draft = proposal.reviewDraft { return draft.data.projectId }
        return proposal.projectId ?? tasks.first { $0.id == proposal.taskId }?.projectId
    }

    private func projectName(_ id: Int?) -> String {
        projects.first { $0.id == id }?.title ?? "Без проекта"
    }

    private func resultsForQuery(_ searchQuery: String, includeRefinements: Bool = false) -> SearchResults {
        let refinedAssignee = includeRefinements ? self.refinedAssignee : nil
        let refinedProject = includeRefinements ? self.refinedProject : nil
        let refinedDeadline = includeRefinements ? self.refinedDeadline : nil
        let extra = includeRefinements ? semanticTaskFilters : AssistantTaskFilters()
        let ignored: Set<String> = [
            "найди", "найдите", "найти", "покажи", "покажите", "выведи", "задачу", "задачи", "задача",
            "поручение", "в", "по", "с", "к", "все", "только", "задач", "теме", "исполнитель", "исполнителю", "для", "ранее",
            "запущенную", "была", "ее", "у", "на", "про", "о", "об", "и", "мне", "пожалуйста",
            "валли", "открой", "откройте"
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
        let allProjects = searchQuery.range(of: #"\b(?:по\s+всем\s+проектам|во\s+всех\s+проектах)\b"#,
                                           options: [.regularExpression, .caseInsensitive])
        let topicQuery = searchQuery
            .replacingOccurrences(of: #"\b(?:по\s+всем\s+проектам|во\s+всех\s+проектах|в\s+(?:этом|текущем)\s+проекте|по\s+(?:этому|текущему)\s+проекту)\b"#,
                                  with: "", options: [.regularExpression, .caseInsensitive])
        let parsed = AssistantTaskFilters.parse(topicQuery, today: today)
        let filters = parsed.filters
        let words = tokens(parsed.remaining).filter { !ignored.contains($0) }
        let projectWords: Set<String> = ["проект", "проекте", "проекту", "проекта"]
        let scopeIndex = words.firstIndex { projectWords.contains($0) }
        let scope = projectScope(words, at: scopeIndex)
        let terms = scopeIndex.flatMap { index in
            scope.first.map { Array(words.prefix(index)) + Array(words.dropFirst(index + 1 + tokens($0.title).count)) }
        } ?? words
        let assignees = assigneeMatch(in: terms)
        let searchTopic = MeetingTopics.searchTerms(terms.filter { $0 != assignees?.word })
        let assigneeIDs = Set(refinedAssignee.map { [$0.id] } ?? assignees?.people.map(\.id) ?? [])
        let taskOnly = filters.isActive || assignees != nil || refinedAssignee != nil ||
            refinedProject != nil || refinedDeadline != nil || tokens(searchQuery).contains { $0.hasPrefix("задач") }
        let canMatch = (scopeIndex == nil || !scope.isEmpty || refinedProject != nil) && assigneeIDs.count <= 1
        let defaultScope = allProjects == nil && !filters.noProjectOnly && !extra.noProjectOnly
            ? searchProject.map { [$0.id] } ?? [] : []
        let scopeIDs = Set(refinedProject.map { [$0.id] } ?? (scopeIndex != nil ? scope.map(\.id) : defaultScope))
        let projectScope = scopeIDs.count == 1
            ? (scopeIDs.first == searchProject?.id ? searchProject?.title : projectName(scopeIDs.first))
            : (filters.noProjectOnly || extra.noProjectOnly ? "Без проекта" : nil)
        let matchingProposals = proposals.filter { proposal in
            guard !projectListOnly, canMatch, !filters.isActive, !extra.isActive, refinedDeadline == nil,
                  !words.isEmpty || taskOnly, proposal.status == "pending", proposal.kind != "decision" else { return false }
            let target = tasks.first { $0.id == proposal.taskId }
            let meeting = meetings.first { $0.id == proposal.source?.meetingId }
            let projectID = proposalProjectID(proposal)
            guard projectID.map({ id in id == searchProject?.id || projects.contains { $0.id == id } }) ?? true,
                  scopeIDs.isEmpty || projectID.map(scopeIDs.contains) == true else { return false }
            let assignee = proposal.reviewDraft.map { $0.data.assigneeId }
                ?? (proposal.proposed?.assigneeId ?? proposal.assigneeId ?? target?.assigneeId)
            guard assigneeIDs.isEmpty || assignee.map(assigneeIDs.contains) == true else { return false }
            let person = people.first { $0.id == assignee }?.name
            let project = projects.first { $0.id == projectID }?.title
            let fields = [proposal.reviewDraft?.data.title ?? proposal.title,
                          proposal.reviewDraft?.data.description ?? proposal.description,
                          proposal.source?.quote, proposal.source?.topic, target?.title, target?.description]
            return MeetingTopics.matchesSearchTopics(searchTopic.topics, fields: fields)
                && matches(searchTopic.words, in: fields + [project, person, meeting?.title])
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
            let fields = [task.title, task.description] + (task.sources ?? []).map(\.quote)
            return MeetingTopics.matchesSearchTopics(searchTopic.topics, fields: fields)
                && matches(searchTopic.words, in: [task.title, task.description, project, person] + context)
        }
        let foundProjects = scopeIndex == nil
            ? projects.filter { !words.isEmpty && matches(words, in: [$0.title, $0.description]) }
            : scope
        let listedProjects = projects.filter { project in
            (!activeProjectsOnly || project.status == "active") &&
                matches(projectListTopic, in: [project.title, project.description])
        }
        let matchingProjects = projectListOnly ? listedProjects : (taskOnly ? [] : foundProjects)
        return SearchResults(projectListOnly: projectListOnly, projectScope: projectScope,
                             recognized: (projectListOnly && projectListTopic.isEmpty) ||
                                 ((taskOnly || !searchTopic.topics.isEmpty) && searchTopic.words.isEmpty),
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
                        if let command = pendingTaskCommand {
                            taskCommandChoices(command)
                        } else {
                            ForEach(projectChoices) { project in
                                Button(project.title) { showProject(project) }
                            }
                        }
                        if !searchQuery.isEmpty {
                            if !results.projectListOnly {
                                Label(results.projectScope ?? "Все проекты", systemImage: "folder")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                searchRefinementOptions
                            }
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
                                    if results.projectScope == nil {
                                        Text(projectName(task.projectId)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if meetingRecording {
                                        let assignee = people.first { $0.id == task.assigneeId }?.name ?? "Без исполнителя"
                                        let due = task.dueDate.map { [$0, task.dueTime].compactMap { $0 }.joined(separator: " ") }
                                        Text(assignee + " · " + (due ?? "Без срока"))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            ForEach(results.proposals) { proposal in
                                VStack(alignment: .leading, spacing: 3) {
                                    Button((proposal.reviewDraft?.data.title ?? proposal.displayTitle) + " · На подтверждение") {
                                        openProposal(proposal)
                                    }.buttonStyle(.link)
                                    if results.projectScope == nil {
                                        Text(projectName(proposalProjectID(proposal))).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
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
            if let proposal = proposals.first(where: { $0.id == localProposalID && $0.status == "pending" }) {
                Button("Открыть предложение") { openProposal(proposal) }.buttonStyle(.link)
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
                    .disabled(sendingLocalCommand || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
            if !available {
                voiceEnabled = false
                voice.stop()
            }
        }
        .onAppear(perform: handleLiveRequests)
        .onChange(of: currentTask?.id) { _ in clearStatusRequest() }
        .onChange(of: searchProject?.id) { _ in
            interpretation?.cancel()
            interpretation = nil
            clearStatusRequest()
            reset()
        }
        .onChange(of: liveRequests) { _ in handleLiveRequests() }
        .onChange(of: meetingRecording) { recording in
            if recording { speech.stop() }
        }
        .onChange(of: speakReplies) { enabled in
            if !enabled { speech.stop() }
        }
        .onDisappear {
            voiceEnabled = false
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
        searchQuery = ""
        localProposalID = nil
        projectChoices = []
        pendingTaskCommand = nil
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

    private func localTaskCommand(_ text: String) -> PendingTaskCommand? {
        let text = text.replacingOccurrences(of: #"^валли[,!:]?\s+"#, with: "",
                                              options: [.regularExpression, .caseInsensitive])
        let lower = text.lowercased()
        let deadlinePrefixes = ["перенеси срок на ", "перенести срок на ", "поставь срок на ", "срок до "]
        if deadlinePrefixes.contains(where: { lower.hasPrefix($0) }) {
            return PendingTaskCommand(action: text, title: "", editsDeadline: true)
        }
        if ["заблокировать:", "снять блокировку", "назначить "]
            .contains(where: { lower.hasPrefix($0) }) {
            return PendingTaskCommand(action: text, title: "")
        }
        let pattern = #"^(?:(?:перенеси|перенести|поставь)\s+(?:задачу|срок\s+(?:задачи|по\s+задаче))\s+(.+?)\s+на\s+|задачу\s+(.+?)\s+поставь\s+на\s+)((?:сегодня|завтра|послезавтра|[0-9]).*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let title = Range(match.range(at: 1), in: text) ?? Range(match.range(at: 2), in: text),
              let deadline = Range(match.range(at: 3), in: text) else { return nil }
        return PendingTaskCommand(action: "Поставь срок на " + String(text[deadline]),
                                  title: String(text[title]), editsDeadline: true)
    }

    private var pendingNewTasks: [Proposal] {
        proposals.filter { $0.kind == "create_task" && $0.status == "pending" }
    }

    private func commandTargets(_ command: PendingTaskCommand, in scope: TaskCommandScope,
                                matching query: String) -> [TaskCommandTarget] {
        let projectID = scope.projectID
        var targets = tasks.filter { $0.projectId == projectID }.map(TaskCommandTarget.task)
        if command.editsDeadline || command.update != nil {
            targets += pendingNewTasks.filter { proposal in
                let draftProject = proposal.reviewDraft.map { $0.data.projectId }
                return (draftProject ?? proposal.projectId) == projectID
            }.map(TaskCommandTarget.proposal)
        }
        let words = tokens(query).filter { !["про", "по", "о", "об", "ту", "где", "которая", "которую"].contains($0) }
        return targets.filter { target in
            let title = tokens(target.title)
            return words.allSatisfy { word in
                title.contains { candidate in
                    similar(word, candidate) ||
                        (min(word.count, candidate.count) >= 4 &&
                         ["а", "я", "у", "ю", "е", "ы", "и"].contains {
                             word == candidate + $0 || candidate == word + $0
                         })
                }
            }
        }
    }

    private func beginTaskCommand(_ command: PendingTaskCommand, scope: TaskCommandScope?) {
        var next = command
        next.scope = scope
        next.search = scope == nil ? "" : command.title
        pendingTaskCommand = next
        guard let scope else {
            append("О каком проекте идёт речь? Назовите его или выберите ниже.")
            return
        }
        let matches = commandTargets(command, in: scope, matching: command.title)
        if !command.title.isEmpty, matches.count == 1, let task = matches.first,
           command.update != nil || tokens(task.title) == tokens(command.title) {
            chooseTaskCommand(next, target: task)
            return
        }
        if !command.title.isEmpty, matches.count == 1, let task = matches.first {
            append("Нашёл «\(task.label)». Изменить эту задачу?")
            return
        }
        let project = projects.first { $0.id == scope.projectID }
        append(matches.isEmpty && !command.title.isEmpty
               ? "Не нашёл задачу «\(command.title)». Уточните название или напишите «Все»."
               : project.map { "Какую задачу в проекте «\($0.title)» изменить?" } ??
                    "Какую задачу без проекта изменить?")
    }

    private func answerTaskCommand(_ command: PendingTaskCommand, text: String) {
        let normalized = AssistantRequest.normalize(text)
        let accepted = ["да", "эту", "подтверждаю", "сохрани", "сохранить"].contains(normalized)
        if var update = command.update, let date = update.correctedDay(in: normalized) {
            update.dueDate = date
            refreshTaskCommand(command, update: update, title: "", text: text)
            return
        }
        if let target = command.selected {
            if accepted {
                if command.update?.fields.isEmpty == true {
                    append("Укажите срок или исполнителя.")
                } else {
                    sendTaskCommand(command.action, to: target, update: command.update)
                }
            } else if ["нет", "другая", "другую"].contains(normalized) {
                var next = command
                next.selected = nil
                next.title = ""
                beginTaskCommand(next, scope: command.scope)
            } else if semanticInterpretation, let update = command.update {
                interpretRequest(text, followup: update)
            }
            return
        }
        if let scope = command.scope {
            if accepted, !command.search.isEmpty {
                let options = commandTargets(command, in: scope, matching: command.search)
                if options.count == 1, let target = options.first {
                    chooseTaskCommand(command, target: target)
                    return
                }
            }
            let query = normalized == "все" ? "" : text
            let matches = commandTargets(command, in: scope, matching: query)
            if !query.isEmpty, matches.count == 1, let task = matches.first,
               command.update != nil || tokens(task.title) == tokens(query) {
                chooseTaskCommand(command, target: task)
            } else if matches.isEmpty, semanticInterpretation, let update = command.update {
                interpretRequest(text, followup: update)
            } else {
                pendingTaskCommand?.search = query
                append(matches.isEmpty ? "Не нашёл такую задачу. Назовите её точнее или напишите «Все»." :
                       "Выберите подходящую задачу.")
            }
        } else if normalized == "без проекта" {
            beginTaskCommand(command, scope: .unassigned)
        } else {
            let query = text.replacingOccurrences(of: #"^(?:в\s+проекте|проект)\s+"#, with: "",
                                                  options: [.regularExpression, .caseInsensitive])
            let words = tokens(query)
            let options = projects.filter { matches(words, in: [$0.title]) }
            if options.count == 1, let project = options.first, tokens(project.title) == words {
                beginTaskCommand(command, scope: .project(project.id))
            } else {
                pendingTaskCommand?.search = normalized == "все" ? "" : query
                append(options.isEmpty && normalized != "все"
                       ? "Не нашёл такой проект. Уточните название или напишите «Все»."
                       : "Выберите проект.")
            }
        }
    }

    @ViewBuilder
    private func taskCommandChoices(_ command: PendingTaskCommand) -> some View {
        if let target = command.selected, command.update?.fields.isEmpty == false {
            Button("Сохранить предложение") {
                sendTaskCommand(command.action, to: target, update: command.update)
            }
            .buttonStyle(.borderedProminent)
            .disabled(interpretation != nil)
        } else if command.selected != nil {
            EmptyView()
        } else if let scope = command.scope {
            ForEach(commandTargets(command, in: scope, matching: command.search).prefix(8)) { task in
                Button(task.label) { chooseTaskCommand(command, target: task) }
                    .buttonStyle(.link)
                    .disabled(interpretation != nil)
            }
        } else {
            let words = tokens(command.search)
            ForEach(projects.filter { matches(words, in: [$0.title]) }.prefix(8)) { project in
                Button(project.title) { beginTaskCommand(command, scope: .project(project.id)) }
                    .buttonStyle(.link)
            }
            if !commandTargets(command, in: .unassigned, matching: "").isEmpty {
                Button("Без проекта") { beginTaskCommand(command, scope: .unassigned) }.buttonStyle(.link)
            }
        }
        Button("Отменить запрос") {
            interpretation?.cancel()
            interpretation = nil
            reset()
            append("Запрос отменён. Что сделать дальше?")
        }.buttonStyle(.link)
    }

    private func chooseTaskCommand(_ command: PendingTaskCommand, target: TaskCommandTarget) {
        guard let update = command.update else {
            sendTaskCommand(command.action, to: target)
            return
        }
        var next = command
        next.selected = target
        pendingTaskCommand = next
        if update.fields.isEmpty {
            append("Выбрана задача «\(target.label)». Укажите срок или исполнителя.")
            return
        }
        append([target.label, update.preview].filter { !$0.isEmpty }.joined(separator: " · ") +
               ". Сохранить предложение?")
    }

    private func sendTaskCommand(_ action: String, to target: TaskCommandTarget?, update: AssistantTaskUpdate? = nil) {
        guard !sendingLocalCommand else { return }
        let previous = pendingTaskCommand
        pendingTaskCommand = nil
        sendingLocalCommand = true
        let taskID: Int?
        let proposalID: Int?
        switch target {
        case .task(let task): (taskID, proposalID) = (task.id, nil)
        case .proposal(let proposal): (taskID, proposalID) = (nil, proposal.id)
        case nil: (taskID, proposalID) = (nil, nil)
        }
        Task {
            let response = await submitLocalCommand(action, taskID, proposalID, update)
            sendingLocalCommand = false
            if let id = response.id {
                localProposalID = id
                if let target, proposalID != nil {
                    append("Обновил черновик задачи «\(target.title)». Проверьте изменения перед подтверждением.")
                } else {
                    append(target.map { "Предложение по задаче «\($0.title)» добавлено на согласование." } ??
                           "Предложение добавлено на согласование.")
                }
            } else {
                if update != nil { pendingTaskCommand = previous }
                append(response.error ?? "Не удалось сохранить предложение.")
            }
        }
    }

    private func submit() {
        guard !changingStatus && !sendingLocalCommand else { return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        query = ""
        guard !text.isEmpty else { return }
        interpretation?.cancel()
        interpretation = nil
        voice.stop()
        let choosingProject = !projectChoices.isEmpty
        projectChoices = []
        append(text, user: true)
        let normalized = AssistantRequest.normalize(text)
        if ["отмена", "отмени", "отменить"].contains(normalized) {
            clearStatusRequest()
            reset()
            append("Запрос отменён. Что сделать дальше?")
            return
        }
        if AssistantRequest.isCreationRequest(text) {
            append("Чтобы создать задачу, проект, совещание или решение, откройте меню «+».")
            return
        }
        if AssistantRequest.isSearchRequest(text) {
            clearStatusRequest()
            pendingTaskCommand = nil
            localProposalID = nil
            clearRefinements()
            search(text, readOnly: true)
            return
        }
        let localPrefix = text.lowercased()
        if localPrefix.hasPrefix("по задаче #") || localPrefix.hasPrefix("задача #") {
            sendTaskCommand(text, to: nil)
            return
        }
        if pendingTaskCommand?.update != nil, let command = pendingTaskCommand {
            answerTaskCommand(command, text: text)
            return
        }
        if let command = localTaskCommand(text) {
            if command.title.isEmpty, let currentTask {
                sendTaskCommand(command.action, to: .task(currentTask))
            } else {
                let scope: TaskCommandScope?
                if let currentTask {
                    scope = currentTask.projectId.map(TaskCommandScope.project) ?? .unassigned
                } else {
                    scope = currentProject.map { .project($0.id) }
                }
                beginTaskCommand(command, scope: scope)
            }
            return
        }
        if let command = pendingTaskCommand {
            answerTaskCommand(command, text: text)
            return
        }
        if let phrase = AssistantTaskStatus.movePhrase(in: text) {
            let dateWords = AssistantTaskStatus.destinations(in: phrase).first.map { tokens($0.target) } ?? []
            let hasDate = dateWords.contains { word in
                ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа",
                 "сентября", "октября", "ноября", "декабря", "завтра", "послезавтра", "сегодня"].contains(word)
            }
            if semanticInterpretation && hasDate { interpretRequest(text) }
            else { requestNamedStatus(phrase) }
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
        if let prefix = normalized.range(of: #"^(?:открой|откройте|открыть)\s+(?:мне\s+)?проект(?:\s+|$)"#, options: .regularExpression) {
            openNamedProject(String(normalized[prefix.upperBound...]))
        } else if choosingProject && projects.contains(where: { tokens($0.title) == tokens(text) }) {
            openNamedProject(text)
        } else if !handleRefinement(text) {
            search(text)
        }
    }

    private func search(_ text: String, readOnly: Bool = false) {
        let results = resultsForQuery(text)
        if semanticInterpretation && results.isEmpty && !results.recognized {
            interpretRequest(text, readOnly: readOnly)
        } else {
            showSearch(text)
        }
    }

    private func showSearch(_ text: String) {
        clearRefinements()
        searchQuery = text
        append(searchResults.reply)
    }

    private func interpretRequest(_ text: String, followup: AssistantTaskUpdate? = nil, readOnly: Bool = false) {
        let hasSearch = !searchQuery.isEmpty && !searchResults.projectListOnly
        let hasProject = currentProject != nil
        interpretation = Task {
            do {
                let intent = try await interpret(text, hasSearch, hasProject, currentTask != nil, followup)
                guard !Task.isCancelled else { return }
                interpretation = nil
                if followup != nil {
                    applyTaskUpdateFollowup(intent, text: text)
                } else if readOnly && ![.searchTasks, .refineTasks, .listProjects].contains(intent.action) {
                    showSearch(text)
                } else {
                    applyIntent(intent, text: text)
                }
            } catch {
                guard !Task.isCancelled else { return }
                interpretation = nil
                append("Не удалось разобрать фразу по смыслу. " + error.localizedDescription +
                       " Попробуйте уточнить запрос.")
            }
        }
    }

    private func applyIntent(_ intent: AssistantIntent, text: String) {
        let title = intent.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch intent.action {
        case .openProject:
            openNamedProject(intent.project ?? "")
        case .listProjects:
            clearRefinements()
            let filter = intent.filters ?? ""
            searchQuery = filter.contains("активн") || filter.contains("актуальн") ? "активные проекты" : "проекты"
            append(searchResults.reply)
        case .searchTasks, .refineTasks:
            applyTaskIntent(intent, title: title, request: text)
        case .updateTask:
            let update = AssistantTaskUpdate(intent)
            let command = PendingTaskCommand(action: text, title: title, update: update)
            let projectName = intent.project?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !projectName.isEmpty {
                let exact = projects.filter { tokens($0.title) == tokens(projectName) }
                if exact.count == 1, let project = exact.first {
                    beginTaskCommand(command, scope: .project(project.id))
                } else {
                    beginTaskCommand(command, scope: nil)
                    pendingTaskCommand?.search = projectName
                }
            } else if let currentTask {
                let scope = currentTask.projectId.map(TaskCommandScope.project) ?? .unassigned
                if title.isEmpty {
                    var next = command
                    next.scope = scope
                    chooseTaskCommand(next, target: .task(currentTask))
                } else {
                    beginTaskCommand(command, scope: scope)
                }
            } else {
                beginTaskCommand(command, scope: currentProject.map { .project($0.id) })
            }
        case .clarify:
            append("Уточните, что показать, открыть или изменить.")
        }
    }

    private func applyTaskUpdateFollowup(_ intent: AssistantIntent, text: String) {
        guard let command = pendingTaskCommand, var update = command.update else { return }
        let revision = AssistantTaskUpdate(intent)
        let title = intent.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard intent.action == .updateTask,
              !revision.fields.isEmpty || !title.isEmpty || (revision.dueTime != nil && update.dueDate != nil) else {
            append("Уточните задачу, срок или исполнителя. Можно выбрать вариант в чате.")
            return
        }
        if let date = revision.dueDate { update.dueDate = date }
        if let time = revision.dueTime, update.dueDate != nil { update.dueTime = time }
        if let assignee = revision.assignee { update.assignee = assignee }
        refreshTaskCommand(command, update: update, title: title, text: text)
    }

    private func refreshTaskCommand(_ original: PendingTaskCommand, update: AssistantTaskUpdate, title: String, text: String) {
        var command = original
        command.update = update
        let quote = command.action + "\n" + text
        if quote.count <= 1000 { command.action = quote }
        if !title.isEmpty {
            command.title = title
            command.selected = nil
        } else if command.selected == nil, command.scope != nil, !command.search.isEmpty {
            command.title = command.search
        }
        if let target = command.selected { chooseTaskCommand(command, target: target) }
        else { beginTaskCommand(command, scope: command.scope) }
    }

    private func applyTaskIntent(_ intent: AssistantIntent, title: String, request: String) {
        if intent.action == .searchTasks || searchQuery.isEmpty || searchResults.projectListOnly {
            clearRefinements()
            let allProjects = request.range(of: #"\b(?:по\s+всем\s+проектам|во\s+всех\s+проектах)\b"#,
                                            options: [.regularExpression, .caseInsensitive]) != nil
            searchQuery = ["задачи", title, intent.filters, allProjects ? "по всем проектам" : nil]
                .compactMap { $0 }.joined(separator: " ")
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
        if let name = intent.project, !name.isEmpty, matches(tokens(name), in: [request]) {
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
        let normalized = AssistantRequest.normalize(text)
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
