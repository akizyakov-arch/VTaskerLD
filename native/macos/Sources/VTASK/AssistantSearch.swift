import SwiftUI

struct AssistantSearch: View {
    let tasks: [TaskItem]
    let today: String
    let projects: [Project]
    let glossaryModel: WorkspaceModel
    let currentProject: Project?
    let currentTask: TaskItem?
    let taskStages: (TaskItem) -> [Stage]
    let changeTaskStatus: (TaskItem, Stage) async -> (message: String, saved: Bool)
    let people: [Person]
    let proposals: [Proposal]
    let meetings: [Meeting]
    let openTask: (Int) -> Void
    let openProject: (Int) -> Void
    let openProposal: (Proposal) -> Void
    let canUseMicrophone: Bool
    let meetingRecording: Bool
    let takingNotes: Bool
    let liveTranscript: LiveTranscript?
    @Binding var liveRequests: [String]
    let transcribe: (Data, Int) async throws -> String
    let interpret: (String, Bool, Bool, Bool, AssistantTaskUpdate?) async throws -> AssistantIntent
    let submitLocalCommand: (String, Int?, Int?, AssistantTaskUpdate?) async -> (id: Int?, error: String?)
    let close: () -> Void

    private struct Message: Identifiable {
        let id = UUID()
        let text: String
        let isUser: Bool
    }

    private struct PendingTaskCommand {
        var action: String
        var title: String
        var editsDeadline = false
        var unresolvedAssignee: String?
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
    @Environment(\.companyGlossary) private var glossary
    @Environment(\.meetingTopics) private var meetingTopics
    @State private var pendingTerm: CompanyTermDraft?
    @State private var awaitingTerm = false
    @State private var editingTerm: CompanyTermDraft?
    @State private var savingTerm = false
    private enum Refinement {
        case assignee, project, deadline
    }

    @State private var searchQuery = ""
    @State private var showAllTaskResults = false
    @Environment(\.colorScheme) private var scheme
    @State private var refinement: Refinement?
    @State private var refinedAssignee: Person?
    @State private var refinedProject: Project?
    @State private var refinedDeadline: AssistantTaskFilters.Deadline?
    @State private var refinedDeadlineLabel: String?
    @State private var semanticTaskFilters = AssistantTaskFilters()
    @State private var messages = [Message(text: "Слушаю. Что найти или изменить?", isUser: false)]
    @AppStorage(AssistantVoicePreferences.engineKey) private var voiceEngine: AssistantRecognitionEngine = .macOS
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
    @State private var interpretingSearch = false
    @State private var replyState: ValliState = .idle

    private var listeningRequest: Int? {
        voiceEnabled && canUseMicrophone && !speech.isSpeaking && interpretation == nil && !changingStatus && !sendingLocalCommand && !savingTerm && editingTerm == nil ? listenTurn : nil
    }

    private var avatarState: ValliState {
        if voice.needsRepeat { return .audioUnclear }
        if interpretation != nil { return interpretingSearch ? .searching : .thinking }
        if voice.transcribing || voice.preparing || changingStatus || sendingLocalCommand || savingTerm { return .thinking }
        if pendingTerm != nil || localProposalID != nil { return .needsReview }
        if let command = pendingTaskCommand {
            if command.selected != nil && command.unresolvedAssignee == nil && command.update?.fields.isEmpty == false {
                return .needsReview
            }
            return .question
        }
        if awaitingTerm || awaitingStatusTaskName || awaitingStatusForTask != nil ||
            refinement != nil || !projectChoices.isEmpty || replyState == .question {
            return .question
        }
        if voice.listening { return .listening }
        if replyState == .done { return .done }
        return takingNotes ? .takingNotes : .idle
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
        let exact = lookup(searchQuery, includeRefinements: includeRefinements, tolerateTaskVariations: false)
        guard !searchQuery.isEmpty && exact.isEmpty && !exact.projectListOnly else { return exact }
        return lookup(searchQuery, includeRefinements: includeRefinements, tolerateTaskVariations: true)
    }

    private func lookup(_ searchQuery: String, includeRefinements: Bool, tolerateTaskVariations: Bool) -> SearchResults {
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
        let words = tokens(parsed.remaining)
        let usefulWords = words.filter { !ignored.contains($0) }
        let projectWords: Set<String> = ["проект", "проекте", "проекту", "проекта"]
        let scopeIndex = words.firstIndex { projectWords.contains($0) }
        let scope = projectScope(words, at: scopeIndex)
        let terms = scopeIndex.flatMap { index in
            scope.first.map { Array(words.prefix(index)) + Array(words.dropFirst(index + 1 + tokens($0.title).count)) }
        } ?? words
        let assignees = assigneeMatch(in: terms.filter { !ignored.contains($0) })
        let searchWords = glossary.expand(terms.filter { $0 != assignees?.word }).filter { !ignored.contains($0) }
        let searchTopic = meetingTopics.searchTerms(searchWords)
        let assigneeIDs = Set(refinedAssignee.map { [$0.id] } ?? assignees?.people.map(\.id) ?? [])
        let taskOnly = filters.isActive || assignees != nil || refinedAssignee != nil ||
            refinedProject != nil || refinedDeadline != nil || tokens(searchQuery).contains { $0.hasPrefix("задач") }
        let canMatch = (scopeIndex == nil || !scope.isEmpty || refinedProject != nil) && assigneeIDs.count <= 1
        let defaultScope = allProjects == nil && !filters.noProjectOnly && !extra.noProjectOnly
            ? currentProject.map { [$0.id] } ?? [] : []
        let scopeIDs = Set(refinedProject.map { [$0.id] } ?? (scopeIndex != nil ? scope.map(\.id) : defaultScope))
        let projectScope = scopeIDs.count == 1
            ? (scopeIDs.first == currentProject?.id ? currentProject?.title : projectName(scopeIDs.first))
            : (filters.noProjectOnly || extra.noProjectOnly ? "Без проекта" : nil)
        let matchingProposals = proposals.filter { proposal in
            guard !projectListOnly, canMatch, !filters.isActive, !extra.isActive, refinedDeadline == nil,
                  !usefulWords.isEmpty || taskOnly, proposal.status == "pending", proposal.kind != "decision" else { return false }
            let target = tasks.first { $0.id == proposal.taskId }
            let meeting = meetings.first { $0.id == proposal.source?.meetingId }
            let projectID = proposalProjectID(proposal)
            guard projectID.map({ id in id == currentProject?.id || projects.contains { $0.id == id } }) ?? true,
                  scopeIDs.isEmpty || projectID.map(scopeIDs.contains) == true else { return false }
            let assignee = proposal.reviewDraft.map { $0.data.assigneeId }
                ?? (proposal.proposed?.assigneeId ?? proposal.assigneeId ?? target?.assigneeId)
            guard assigneeIDs.isEmpty || assignee.map(assigneeIDs.contains) == true else { return false }
            let person = people.first { $0.id == assignee }?.name
            let project = projects.first { $0.id == projectID }?.title
            let fields = [proposal.reviewDraft?.data.title ?? proposal.title,
                          proposal.reviewDraft?.data.description ?? proposal.description,
                          proposal.source?.quote, proposal.source?.topic, target?.title, target?.description]
            return meetingTopics.matchesSearchTopics(searchTopic.topics, fields: glossaryTopicFields(fields))
                && matches(searchTopic.words, in: fields + [project, person, meeting?.visibleTitle],
                           tolerateTaskVariations: tolerateTaskVariations)
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
                [source.quote, meetings.first { $0.id == source.meetingId }?.visibleTitle]
            }
            let fields = [task.title, task.description] + (task.sources ?? []).map(\.quote)
            return meetingTopics.matchesSearchTopics(searchTopic.topics, fields: glossaryTopicFields(fields))
                && matches(searchTopic.words, in: [task.title, task.description, project, person] + context,
                           tolerateTaskVariations: tolerateTaskVariations)
        }
        let foundProjects = scopeIndex == nil
            ? projects.filter { !usefulWords.isEmpty && matches(usefulWords, in: [$0.title, $0.description]) }
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
        let state = avatarState
        VStack(spacing: 0) {
            HStack {
                WindowCloseButton(label: "Закрыть ассистента", action: close)
                    .keyboardShortcut(.cancelAction)
                NavigationBackButton(action: close)
                ValliAvatar(state: state, size: 44, animated: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Валли").font(.title3.weight(.semibold))
                    Text(state.title).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
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
                        ForEach(statusTaskChoices.filter { statusTask($0.id) != nil }) { task in
                            let project = projects.first { $0.id == task.projectId }?.title ?? "Без проекта"
                            Button(task.title + " · " + project) {
                                if let latest = statusTask(task.id) {
                                    requestTaskStatus(pendingStatusTarget, for: latest)
                                }
                            }
                        }
                        if let draft = pendingTerm {
                            HStack {
                                Button("Сохранить термин") { saveCompanyTerm(draft) }
                                    .buttonStyle(.borderedProminent)
                                Button("Исправить") { editingTerm = draft }
                                Button("Отмена") { cancelCompanyTerm() }
                            }
                            .disabled(savingTerm)
                        }
                        if let command = pendingTaskCommand {
                            taskCommandChoices(command)
                        } else {
                            ForEach(projectChoices) { project in
                                Button(project.title) { showProject(project) }
                            }
                        }
                        if !searchQuery.isEmpty {
                            Color.clear.frame(height: 0).id("search-results")
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
                            if !results.tasks.isEmpty || !results.proposals.isEmpty {
                                taskResults(results)
                            }
                            ForEach(results.projects) { project in
                                Button("Проект · " + project.title) { openProject(project.id) }.buttonStyle(.link)
                            }
                        }
                        Color.clear.frame(height: 1).id("chat-end")
                    }
                    .padding(14)
                }
                .onChange(of: messages.count) { _ in
                    showAllTaskResults = false
                    if searchQuery.isEmpty || pendingTerm != nil || pendingTaskCommand != nil || !statusTaskChoices.isEmpty {
                        scroll.scrollTo("chat-end", anchor: .bottom)
                    } else {
                        scroll.scrollTo("search-results", anchor: .top)
                    }
                }
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
            } else if voice.listening && state != .listening {
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
        .task(id: replyState == .done ? messages.last?.id : nil) {
            guard replyState == .done else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            replyState = .idle
        }
        .task(id: listeningRequest) {
            guard listeningRequest != nil else { return }
            // Give the output device time to finish playing the synthesized audio.
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard listeningRequest != nil, !Task.isCancelled else { return }
            await voice.start(silenceMilliseconds: silenceMilliseconds, recognitionEngine: voiceEngine, transcribe: transcribe)
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
        .sheet(item: $editingTerm) { draft in
            CompanyTermEditor(model: glossaryModel, draft: draft) {
                pendingTerm = nil
                awaitingTerm = false
                append("Термин сохранён в справочнике компании.", feedback: .done)
            }
            .sheetCloseButton(disabled: glossaryModel.saving)
        }
        .onAppear(perform: handleLiveRequests)
        .onChange(of: currentTask?.id) { _ in clearStatusRequest() }
        .onChange(of: taskCommandScope) { _ in clearStatusRequest() }
        .onChange(of: currentProject?.id) { _ in
            interpretation?.cancel()
            interpretation = nil
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

    private func taskResults(_ results: SearchResults) -> some View {
        let total = results.tasks.count + results.proposals.count
        let limit = showAllTaskResults ? total : 6
        let shownTasks = results.tasks.prefix(limit)
        let shownProposals = results.proposals.prefix(limit - shownTasks.count)
        let palette = PanelPalette(dark: scheme == .dark)
        let showsProject = results.projectScope == nil

        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(shownTasks) { task in
                taskSearchRow(
                    title: task.title, project: showsProject ? projectName(task.projectId) : nil,
                    assignee: people.first { $0.id == task.assigneeId }?.name, due: task.dueDate, time: task.dueTime,
                    status: task.overdue ? "Просрочена" : task.stageTitle,
                    color: task.overdue ? palette.recordingInk : palette.muted
                ) { openTask(task.id) }
                if task.id != shownTasks.last?.id || !shownProposals.isEmpty { Divider() }
            }
            ForEach(shownProposals) { proposal in
                let deadline = proposal.reviewDeadline
                taskSearchRow(
                    title: proposal.reviewDraft?.data.title ?? proposal.displayTitle,
                    project: showsProject ? projectName(proposalProjectID(proposal)) : nil,
                    assignee: people.first { $0.id == proposal.reviewAssigneeId }?.name,
                    due: deadline.date, time: deadline.time, status: "На подтверждении", color: palette.accent
                ) { openProposal(proposal) }
                if proposal.id != shownProposals.last?.id { Divider() }
            }
            if total > limit {
                Divider()
                Button("Показать ещё \(total - limit)") {
                    showAllTaskResults = true
                }
                .buttonStyle(.link)
                .padding(10)
            }
        }
        .panelCard(inset: 0)
    }

    private func taskSearchRow(title: String, project: String?, assignee: String?, due: String?, time: String?,
                               status: String, color: Color, action: @escaping () -> Void) -> some View {
        let deadline = due.map { [ProjectDateField.display($0), time].compactMap { $0 }.joined(separator: " ") }
        let context = [project, assignee, deadline].compactMap { $0 }.joined(separator: " · ")
        return Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                    if !context.isEmpty {
                        Text(context).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(status).font(.caption.weight(.medium)).foregroundStyle(color)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            reportSearchResults()
        }
    }

    private func append(_ text: String, user: Bool = false, feedback: ValliState = .idle) {
        replyState = feedback
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
        replyState = .idle
        localProposalID = nil
        projectChoices = []
        pendingTaskCommand = nil
        pendingTerm = nil
        awaitingTerm = false
        clearRefinements()
    }

    private var taskCommandScope: TaskCommandScope? {
        TaskCommandScope(projectID: currentProject?.id, task: currentTask)
    }

    private var statusTasks: [TaskItem] {
        TaskCommandScope.tasks(tasks, in: taskCommandScope)
    }

    private func statusTask(_ id: Int?) -> TaskItem? {
        guard let id else { return nil }
        return statusTasks.first { $0.id == id }
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
        let availableTasks = statusTasks
        for candidate in candidates where !candidate.name.isEmpty {
            let words = tokens(candidate.name)
            let exact = availableTasks.filter { tokens($0.title) == words }
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
            let related = words.isEmpty ? [] : availableTasks.filter { matches(words, in: [$0.title]) }
            if !related.isEmpty {
                offerStatusTasks(related, target: candidate.target)
                return
            }
        }
        awaitingStatusTaskName = true
        pendingStatusTarget = candidate.target
        if candidate.name.isEmpty {
            append("Какую задачу перенести?")
        } else if let scope = taskCommandScope {
            let location = scope.projectID.map { "в проекте «" + projectName($0) + "»" } ?? "среди задач без проекта"
            append("Не нашёл задачу «\(candidate.name)» \(location). Уточните название или откройте нужный проект.")
        } else {
            append("Не нашёл задачу «\(candidate.name)». Назовите её точнее.")
        }
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
        guard !changingStatus, statusTask(task.id) != nil,
              taskStages(task).contains(where: { $0.id == stage.id }) else { return }
        clearStatusRequest()
        if task.stageId == stage.id {
            append("«\(task.title)» уже в статусе «\(stage.title)».", feedback: .done)
            return
        }
        changingStatus = true
        voice.stop()
        Task {
            let (reply, saved) = await changeTaskStatus(task, stage)
            changingStatus = false
            append(reply, feedback: saved ? .done : .idle)
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
        var targets = TaskCommandScope.tasks(tasks, in: scope).map(TaskCommandTarget.task)
        if command.editsDeadline || command.update != nil {
            targets += pendingNewTasks.filter { proposal in
                let draftProject = proposal.reviewDraft.map { $0.data.projectId }
                return (draftProject ?? proposal.projectId) == projectID
            }.map(TaskCommandTarget.proposal)
        }
        let words = tokens(query).filter { !["про", "по", "о", "об", "ту", "где", "которая", "которую"].contains($0) }
        let exact = targets.filter { target in
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
        guard exact.isEmpty, !words.isEmpty else { return exact }
        let varied = targets.filter { matches(words, in: [$0.title], tolerateTaskVariations: true) }
        guard varied.isEmpty, command.update != nil, words.count > 1 else { return varied }
        return targets.filter { AssistantTaskText.matchesAnchor(words, in: tokens($0.title)) }
    }

    private func beginTaskCommand(_ command: PendingTaskCommand, scope: TaskCommandScope?) {
        var next = command
        next.scope = scope
        next.search = scope == nil ? "" : command.title
        pendingTaskCommand = next
        guard let scope else {
            if command.update != nil && !command.title.isEmpty && command.search.isEmpty {
                let scopes = projects.map { TaskCommandScope.project($0.id) } + [.unassigned]
                let found = scopes.filter { !commandTargets(command, in: $0, matching: command.title).isEmpty }
                if found.count == 1, let only = found.first {
                    beginTaskCommand(command, scope: only)
                    return
                }
            }
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
            if command.unresolvedAssignee != nil && !accepted && !["нет", "другая", "другую"].contains(normalized) {
                if let person = assignmentPerson(text) {
                    chooseAssignee(person, command: command, target: target)
                } else {
                    pendingTaskCommand?.unresolvedAssignee = text
                    append("Уточните исполнителя или выберите его ниже.")
                }
                return
            }
            if accepted {
                if command.unresolvedAssignee != nil {
                    append("Сначала выберите исполнителя.")
                    return
                }
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
        if let target = command.selected, let unresolved = command.unresolvedAssignee {
            let prefix = tokens(unresolved).first?.prefix(3) ?? ""
            let suggestions = prefix.count == 3 ? people.filter {
                tokens($0.speakerPickerName).contains { $0.hasPrefix(prefix) }
            } : []
            ForEach((suggestions.isEmpty ? people : suggestions).prefix(8)) { person in
                Button(person.speakerPickerName) { chooseAssignee(person, command: command, target: target) }
                    .buttonStyle(.link)
            }
        } else if let target = command.selected, command.update?.fields.isEmpty == false {
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
        if let unresolved = command.unresolvedAssignee {
            let heard = unresolved.isEmpty ? "" : " Услышал «\(unresolved)»."
            let date = update.preview.isEmpty ? "" : " Срок · " + update.preview + "."
            append("«\(target.label)»." + date + heard + " Укажите исполнителя или выберите его ниже.")
            return
        }
        if update.fields.isEmpty {
            append("Выбрана задача «\(target.label)». Укажите срок или исполнителя.")
            return
        }
        append([target.label, update.preview].filter { !$0.isEmpty }.joined(separator: " · ") +
               ". Сохранить предложение?")
    }

    private func assignmentPerson(_ text: String) -> Person? {
        let words = tokens(text)
        guard !words.isEmpty else { return nil }
        let exact = people.filter {
            [$0.name, $0.nickname, $0.lastName, $0.speakerPickerName].compactMap { $0 }.contains { tokens($0) == words }
        }
        if exact.count == 1 { return exact.first }
        guard exact.isEmpty, words.count == 1 else { return nil }
        let inflected = people.filter {
            guard let name = tokens($0.name).first else { return false }
            let root = name.last.map { "ая".contains($0) } == true ? String(name.dropLast()) : name
            return root.count >= 3 && ["е", "у", "ю"].contains { words[0] == root + $0 }
        }
        return inflected.count == 1 ? inflected.first : nil
    }

    private func chooseAssignee(_ person: Person, command: PendingTaskCommand, target: TaskCommandTarget) {
        var next = command
        next.unresolvedAssignee = nil
        next.update?.assignee = person.speakerPickerName
        chooseTaskCommand(next, target: target)
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

    private func handleCompanyTerm(_ text: String, normalized: String) -> Bool {
        if let draft = pendingTerm {
            if ["да", "сохрани", "сохранить", "запомни", "подтверждаю"].contains(normalized) {
                saveCompanyTerm(draft)
                return true
            }
            if ["нет", "отмена"].contains(normalized) {
                cancelCompanyTerm()
                return true
            }
            if ["исправь", "исправить", "редактировать"].contains(normalized) {
                editingTerm = draft
                return true
            }
        }
        let teaching = CompanyTermRequest.isRequest(text)
        guard teaching || awaitingTerm || pendingTerm != nil else { return false }
        if let draft = CompanyTermRequest.draft(from: text) {
            reset()
            clearStatusRequest()
            pendingTerm = draft
            let variant = draft.variants.first?.text ?? ""
            append("Запомнить «" + variant + "» как «" + draft.term + "» для всей компании?")
        } else if teaching || awaitingTerm {
            awaitingTerm = true
            pendingTerm = nil
            append("Какое выражение запомнить и что оно означает? Например: «сотик — сотовый поликарбонат».")
        } else {
            return false
        }
        return true
    }

    private func saveCompanyTerm(_ draft: CompanyTermDraft) {
        guard !savingTerm else { return }
        savingTerm = true
        voice.stop()
        Task {
            let saved = await draft.save(using: glossaryModel)
            savingTerm = false
            if saved {
                pendingTerm = nil
                awaitingTerm = false
                append("Запомнил «" + draft.term + "» для всей компании.", feedback: .done)
            } else {
                append(glossaryModel.error ?? "Не удалось сохранить термин.")
            }
        }
    }

    private func cancelCompanyTerm() {
        pendingTerm = nil
        awaitingTerm = false
        append("Сохранение термина отменено.")
    }

    private func submit() {
        guard !changingStatus && !sendingLocalCommand && !savingTerm else { return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        query = ""
        guard !text.isEmpty else { return }
        interpretation?.cancel()
        interpretation = nil
        voice.clearFeedback()
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
        if handleCompanyTerm(text, normalized: normalized) { return }
        if AssistantRequest.isCreationRequest(text) {
            append("Чтобы создать задачу, проект, совещание или решение, откройте меню «+».")
            return
        }
        if let assignment = AssistantRequest.searchAndAssignment(text) {
            clearStatusRequest()
            pendingTaskCommand = nil
            localProposalID = nil
            clearRefinements()
            let due = assignment.deadline.flatMap { AssistantRequest.assignmentDeadline($0, today: today) }
            if assignment.deadline != nil && due == nil {
                if semanticInterpretation { interpretRequest(text) }
                else { append("Уточните срок, указав дату или ближайшее число.") }
                return
            }
            let person = assignmentPerson(assignment.assignee)
            let update = AssistantTaskUpdate(dueDate: due, assignee: person?.speakerPickerName)
            let command = PendingTaskCommand(action: text, title: assignment.title,
                                             unresolvedAssignee: person == nil ? assignment.assignee : nil,
                                             update: update)
            beginTaskCommand(command, scope: currentProject.map { .project($0.id) })
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
                beginTaskCommand(command, scope: taskCommandScope)
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
                append("Откройте карточку задачи или скажите «Перенеси задачу» и назовите её.", feedback: .question)
            }
            return
        }
        if let prefix = normalized.range(of: #"^(?:открой|откройте|открыть)\s+(?:мне\s+)?проект(?:\s+|$)"#, options: .regularExpression) {
            clearStatusRequest()
            openNamedProject(String(normalized[prefix.upperBound...]))
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
        if choosingProject && projects.contains(where: { tokens($0.title) == tokens(text) }) {
            openNamedProject(text)
        } else if !handleRefinement(text) {
            search(text)
        }
    }

    private func search(_ text: String, readOnly: Bool = false) {
        let results = resultsForQuery(text)
        if semanticInterpretation && results.isEmpty && !results.recognized {
            interpretRequest(text, readOnly: readOnly, searching: true)
        } else {
            showSearch(text)
        }
    }

    private func showSearch(_ text: String) {
        clearRefinements()
        searchQuery = text
        reportSearchResults()
    }

    private func reportSearchResults(prefix: String = "") {
        let results = searchResults
        let feedback: ValliState = results.ambiguousAssignees.isEmpty ? .done : .question
        append(prefix + results.reply, feedback: feedback)
    }

    private func interpretRequest(_ text: String, followup: AssistantTaskUpdate? = nil,
                                  readOnly: Bool = false, searching: Bool = false) {
        interpretingSearch = searching
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
            reportSearchResults()
        case .searchTasks, .refineTasks:
            applyTaskIntent(intent, title: title, request: text)
        case .updateTask:
            var update = AssistantTaskUpdate(intent)
            let heard = update.assignee
            if let heard { update.assignee = assignmentPerson(heard)?.speakerPickerName }
            let command = PendingTaskCommand(action: text, title: title,
                                             unresolvedAssignee: update.assignee == nil ? heard : nil,
                                             update: update)
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
            append("Уточните, что показать, открыть или изменить.", feedback: .question)
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
        reportSearchResults()
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
        reportSearchResults(prefix: "Исполнитель «" + person.name + "». ")
    }

    private func applyProject(_ project: Project) {
        refinedProject = project
        refinement = nil
        reportSearchResults(prefix: "Проект «" + project.title + "». ")
    }

    private func applyDeadline(_ text: String) {
        guard let deadline = AssistantTaskFilters.parse(text, today: today).filters.deadline else {
            askRefinement(.deadline)
            return
        }
        refinedDeadline = deadline
        refinedDeadlineLabel = text
        refinement = nil
        reportSearchResults(prefix: "Срок «" + text + "». ")
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
        append("Открыла проект «" + project.title + "».", feedback: .done)
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

    private func glossarySearchFields(_ fields: [String?]) -> [String?] {
        fields.map { field in field.map { glossary.expand(tokens($0)).joined(separator: " ") } }
    }

    private func glossaryTopicFields(_ fields: [String?]) -> [String?] {
        fields + glossarySearchFields(fields) + fields.map { $0.flatMap { glossary.section(for: $0) } }
    }

    private func matches(_ words: [String], in fields: [String?], tolerateTaskVariations: Bool = false) -> Bool {
        let searchable = tokens(fields.compactMap { $0 }.joined(separator: " ")) +
            glossarySearchFields(fields).compactMap { $0 }.flatMap(tokens)
        return glossary.expand(words).allSatisfy { word in
            searchable.contains { candidate in
                similar(word, candidate) ||
                    (tolerateTaskVariations && AssistantTaskText.matchesVariation(word, candidate))
            }
        }
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
