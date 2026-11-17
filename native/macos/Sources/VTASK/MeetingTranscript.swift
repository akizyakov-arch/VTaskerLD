import SwiftUI
import UniformTypeIdentifiers

struct MeetingTranscript: View {
    @ObservedObject var model: WorkspaceModel
    let meeting: Meeting
    @State private var transcript: Transcript?
    @State private var error: String?
    @State private var loading = true
    @State private var refreshCount = 0
    @State private var editedSegment: Transcript.Segment?
    @State private var editedText = ""
    @State private var order = TranscriptOrder.chronological
    @State private var readingPage = 0
    private let paragraphsPerPage = 20
    @State private var editing = false
    @State private var editPage = 0
    private let fragmentsPerPage = 24
    private enum TranscriptOrder: Hashable {
        case chronological, byTopic
    }

    private struct Paragraph: Identifiable {
        let segments: [Transcript.Segment]
        var first: Transcript.Segment { segments[0] }
        var id: Int { first.id }
        var text: String {
            segments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " ")
        }
        var topic: String { MeetingTopics.title(topic: nil, text: text) }
    }

    private enum SpeakerFilter: Hashable {
        case all, unknown, person(Int)

        func includes(_ segment: Transcript.Segment) -> Bool {
            switch self {
            case .all: return true
            case .unknown: return segment.resolvedSpeakerID == nil
            case .person(let id): return segment.resolvedSpeakerID == id
            }
        }
    }

    private struct SpeakerAssignmentRequest: Identifiable {
        let segment: Transcript.Segment
        let run: Int
        var id: Int { segment.id }
    }

    @State private var speakerFilter = SpeakerFilter.all
    @State private var speakerAssignment: SpeakerAssignmentRequest?
    @State private var query = ""
    @State private var confirmingVoice: Transcript.VoiceMatch?
    @State private var listeningSegment: Transcript.Segment?
    @State private var enrollingSpeaker: MeetingVoiceSource?
    @State private var draftingProposal: Proposal?

    private func paragraphs(_ segments: [Transcript.Segment]) -> [Paragraph] {
        var result: [[Transcript.Segment]] = []
        var length = 0
        for segment in segments where !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let previous = result.last?.last,
               previous.resolvedSpeakerID == segment.resolvedSpeakerID, previous.speakerId == segment.speakerId,
               segment.startMs - previous.endMs < 1600, length < 600,
               length < 300 || previous.text.trimmingCharacters(in: .whitespacesAndNewlines).last.map({ !".!?…".contains($0) }) == true {
                result[result.count - 1].append(segment)
            } else {
                result.append([segment])
                length = 0
            }
            length += segment.text.count + 1
        }
        return result.map { Paragraph(segments: $0) }
    }

    var body: some View {
        MeetingDisclosure(title: "Расшифровка", icon: "text.bubble", count: transcript?.segments.count) {
            transcriptContent
        }
        .onChange(of: query) { _ in
            editPage = 0
            readingPage = 0
        }
        .onChange(of: speakerFilter) { _ in
            editPage = 0
            readingPage = 0
        }
        .onChange(of: order) { _ in
            editPage = 0
            readingPage = 0
        }
        .onChange(of: transcript?.segments) { segments in
            if case .person = speakerFilter, segments?.contains(where: speakerFilter.includes) == false {
                speakerFilter = .all
            }
        }
        .sheet(item: $speakerAssignment) { request in
            TranscriptSpeakerPicker(model: model, meeting: meeting, segment: request.segment) { person, wholeVoice in
                await assign(person, segment: request.segment, run: request.run,
                             speaker: wholeVoice ? request.segment.speakerId : nil)
            }
            .sheetCloseButton(disabled: model.saving)
        }
        .sheet(item: $draftingProposal) { proposal in
            Group {
                if let workspace = model.workspace {
                    ProposalEditor(model: model, workspace: workspace, proposal: proposal)
                }
            }
            .sheetCloseButton(disabled: model.saving)
        }
        .sheet(item: $listeningSegment) { segment in
            MeetingAudioPreview(model: model, meetingID: meeting.id, segment: segment)
                .sheetCloseButton()
        }
        .sheet(item: $enrollingSpeaker) { source in
            MeetingVoiceEnrollment(model: model, meeting: meeting, source: source)
                .sheetCloseButton(disabled: model.saving)
        }
        .sheet(item: $editedSegment) { segment in
            VStack(alignment: .leading, spacing: 12) {
                Text("Исправить фрагмент").font(.headline)
                TextEditor(text: $editedText).frame(minHeight: 120)
                if let error = model.error { Text(error).foregroundStyle(.red) }
                HStack {
                    Button("Отмена") { editedSegment = nil }
                    Spacer()
                    Button("Сохранить") {
                        guard let run = transcript?.modelRunId else { return }
                        Task {
                            if await model.command(["model_run_id": run, "segment_id": segment.id, "text": editedText], path: "api/segment/edit") {
                                editedSegment = nil
                                refreshCount += 1
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding().frame(width: 460)
            .disabled(model.saving || model.loading)
            .sheetCloseButton(disabled: model.saving)
            .interactiveDismissDisabled(model.saving)
        }
        .confirmationDialog("Подтвердить имя говорящего", isPresented: Binding(
            get: { confirmingVoice != nil },
            set: { if !$0 { confirmingVoice = nil } }
        ), presenting: confirmingVoice) { candidate in
            if let person = candidate.personId, let run = transcript?.modelRunId {
                Button(candidate.personName ?? "Подтвердить") {
                    Task {
                        if await model.command(["model_run_id": run, "speaker_id": candidate.speakerId,
                                                "person_id": person], path: "api/speaker/assign") {
                            refreshCount += 1
                        }
                    }
                }
            }
        } message: { _ in
            Text("Имя будет назначено всем репликам этого голоса в текущей версии протокола.")
        }
        .onChange(of: meeting.processing?.status) { _ in refreshCount += 1 }
        .onChange(of: transcript?.modelRunId) { _ in
            readingPage = 0
            editPage = 0
        }
        .task(id: matchingQueued) {
            guard matchingQueued, let run = transcript?.modelRunId else { return }
            while !Task.isCancelled {
                do {
                    let status = try await model.voiceStatus()
                    let job = status.voiceData.matchJobs?.first { $0.modelRunId == run }
                    guard !Task.isCancelled else { return }
                    if let job, !["pending", "running"].contains(job.state) {
                        matchingError = job.error
                        matchingQueued = false
                        refreshCount += 1
                        return
                    }
                    if job == nil {
                        matchingError = "Задание сопоставления отсутствует в очереди."
                        matchingQueued = false
                        return
                    }
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    guard !Task.isCancelled else { return }
                    matchingError = error.localizedDescription
                    matchingQueued = false
                }
            }
        }
        .task(id: refreshCount) {
            loading = true
            defer { loading = false }
            do {
                transcript = try await model.transcript(for: meeting)
                error = nil
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    @ViewBuilder
    private var transcriptContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if loading {
                ProgressView()
            } else if let error {
                Text(error).foregroundStyle(.red)
            } else if let transcript, !transcript.segments.isEmpty {
                let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
                let includes: (Transcript.Segment) -> Bool = {
                    speakerFilter.includes($0) && (search.isEmpty || $0.text.localizedCaseInsensitiveContains(search))
                }
                let matches = transcript.segments.filter(includes)
                TextField("Найти в протоколе", text: $query)
                speakerFilterPicker(transcript)
                Picker("Порядок реплик", selection: $order) {
                    Text("По порядку").tag(TranscriptOrder.chronological)
                    Text("По темам").tag(TranscriptOrder.byTopic)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if !search.isEmpty || speakerFilter != .all {
                    Text("Найдено фрагментов: \(matches.count)").foregroundStyle(.secondary)
                }
                Button {
                    editing.toggle()
                    editPage = 0
                } label: {
                    Label(editing ? "К чтению" : "Редактировать",
                          systemImage: editing ? "doc.text" : "square.and.pencil")
                }
                .buttonStyle(.bordered)
                if editing {
                    let topics = topicsBySegment(in: transcript)
                    transcriptPage(rows: matches, pageSize: fragmentsPerPage, selectedPage: $editPage,
                                   topic: { topics[$0.id] ?? MeetingTopics.ungrouped }) { segment in
                        fragmentRow(segment, run: transcript.modelRunId)
                    }
                } else {
                    let flow = paragraphs(transcript.segments).filter { $0.segments.contains(where: includes) }
                    transcriptPage(rows: flow, pageSize: paragraphsPerPage, selectedPage: $readingPage,
                                   topic: { $0.topic }, content: paragraphRow)
                }
                voiceMatching(transcript)
            } else {
                Text("Готового протокола пока нет.").foregroundStyle(.secondary)
            }
            HStack {
                Menu {
                    Button("Текст (.txt)") { Task { await model.exportMeeting(meeting, asText: true) } }
                    Button("Данные (.json)") { Task { await model.exportMeeting(meeting, asText: false) } }
                } label: {
                    Label("Экспорт", systemImage: "square.and.arrow.up")
                }
                Button { refreshCount += 1 } label: {
                    Label("Обновить", systemImage: "arrow.clockwise")
                }
                .disabled(loading)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func topicsBySegment(in transcript: Transcript) -> [Int: String] {
        guard order == .byTopic else { return [:] }
        return paragraphs(transcript.segments).reduce(into: [:]) { topics, paragraph in
            let topic = paragraph.topic
            for segment in paragraph.segments { topics[segment.id] = topic }
        }
    }

    @ViewBuilder
    private func transcriptPage<Row: Identifiable, Content: View>(
        rows: [Row], pageSize: Int, selectedPage: Binding<Int>, topic: @escaping (Row) -> String,
        @ViewBuilder content: @escaping (Row) -> Content
    ) -> some View {
        if rows.isEmpty {
            Text("Совпадений в протоколе нет.").foregroundStyle(.secondary)
        } else {
            let pageCount = (rows.count + pageSize - 1) / pageSize
            let page = min(selectedPage.wrappedValue, pageCount - 1)
            let start = page * pageSize
            let range = start..<min(start + pageSize, rows.count)
            transcriptPager(page: page, pageCount: pageCount) { selectedPage.wrappedValue = $0 }
            if order == .byTopic {
                MeetingTopicList(rows: rows, topic: topic, visibleRange: range, content: content)
            } else {
                ForEach(rows[range], content: content)
            }
            transcriptPager(page: page, pageCount: pageCount) { selectedPage.wrappedValue = $0 }
        }
    }

    private func paragraphRow(_ paragraph: Paragraph) -> some View {
        let first = paragraph.first
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                Text(first.speakerLabel)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if !meeting.recordings.isEmpty {
                    Button { listeningSegment = first } label: {
                        Label(meetingTime(first.startMs), systemImage: "play.circle")
                            .font(.caption.monospacedDigit())
                    }
                    .buttonStyle(.link)
                    .accessibilityLabel("Воспроизвести с " + meetingTime(first.startMs))
                }
            }
            ProtocolProse(text: paragraph.text)
        }
        .frame(maxWidth: 740)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fragmentRow(_ segment: Transcript.Segment, run: Int) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(segment.speakerLabel).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !meeting.recordings.isEmpty {
                    Button { listeningSegment = segment } label: {
                        Label("Прослушать · " + meetingTime(segment.startMs), systemImage: "play.circle")
                            .font(.caption.monospacedDigit())
                    }
                    .buttonStyle(.link)
                }
            }
            Text(segment.text).textSelection(.enabled)
            Button("Назначить говорящего") {
                speakerAssignment = SpeakerAssignmentRequest(segment: segment, run: run)
            }
            .disabled(model.saving || model.loading)
            Menu("Предложение из реплики") {
                Button("Новая задача") { propose("create_task", from: segment) }
                Button("Изменить срок") { propose("change_due", from: segment) }
                Button("Сменить исполнителя") { propose("change_assignee", from: segment) }
                Button("Изменить статус") { propose("change_status", from: segment) }
                Button("Решение") { propose("decision", from: segment) }
            }
            .disabled(model.saving)
            Button("Исправить текст") {
                editedText = segment.text
                editedSegment = segment
            }
            .disabled(model.saving || model.loading)
        }
    }

    private func speakerFilterPicker(_ transcript: Transcript) -> some View {
        let people = model.workspace?.people ?? []
        let names = transcript.segments.reduce(into: [Int: String]()) { names, segment in
            if let id = segment.resolvedSpeakerID {
                names[id] = people.first { $0.id == id }?.speakerPickerName ?? segment.speakerLabel
            }
        }
        let ids = names.keys.sorted {
            let order = names[$0, default: ""].localizedStandardCompare(names[$1, default: ""])
            return order == .orderedSame ? $0 < $1 : order == .orderedAscending
        }
        return Picker("Говорящий", selection: $speakerFilter) {
            Text("Все говорящие").tag(SpeakerFilter.all)
            Text("Говорящий не определён").tag(SpeakerFilter.unknown)
            ForEach(ids, id: \.self) { id in
                Text(names[id, default: "Участник"]).tag(SpeakerFilter.person(id))
            }
        }
    }

    @ViewBuilder
    private func transcriptPager(page: Int, pageCount: Int, select: @escaping (Int) -> Void) -> some View {
        if pageCount > 1 {
            HStack {
                Button { select(page - 1) } label: { Label("Назад", systemImage: "chevron.left") }
                    .disabled(page == 0)
                Menu {
                    Picker("Страница", selection: Binding(get: { page }, set: select)) {
                        ForEach(0..<pageCount, id: \.self) { index in
                            Text("Страница \(index + 1)").tag(index)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text("Страница \(page + 1) из \(pageCount)")
                        .monospacedDigit()
                }
                .help("Перейти к странице")
                Button { select(page + 1) } label: { Label("Далее", systemImage: "chevron.right") }
                    .disabled(page + 1 >= pageCount)
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func voiceMatching(_ transcript: Transcript) -> some View {
        if transcript.speakerTurns?.isEmpty == false {
            Button("Сопоставить голоса с профилями") {
                Task {
                    matchingError = nil
                    if await model.command(["model_run_id": transcript.modelRunId], path: "api/voice/match") {
                        matchingQueued = true
                    }
                }
            }
            .disabled(model.saving || model.capture?.active != nil || matchingQueued)
            if matchingQueued {
                Text("Сопоставление поставлено в очередь.").foregroundStyle(.secondary)
            }
            Menu("Создать профиль из встречи") {
                ForEach(Array(Set((transcript.speakerTurns ?? []).map(\.speakerId))).sorted(), id: \.self) { speaker in
                    Button(speaker) { enrollingSpeaker = MeetingVoiceSource(run: transcript.modelRunId, speaker: speaker) }
                }
            }
            .disabled(model.saving || model.capture?.active != nil || meeting.participants.isEmpty)
            if let matchingError { Text(matchingError).foregroundStyle(.red) }
            let assigned = Set((transcript.speakerAssignments ?? []).compactMap(\.speakerId))
            ForEach((transcript.voiceMatches ?? []).filter { $0.status == "candidate" && !assigned.contains($0.speakerId) }) { candidate in
                Button("\(candidate.speakerId) · \(candidate.personName ?? "Участник")") {
                    confirmingVoice = candidate
                }
                .disabled(model.saving)
            }
        }
    }

    @State private var matchingQueued = false
    @State private var matchingError: String?

    private func propose(_ kind: String, from segment: Transcript.Segment) {
        draftingProposal = Proposal(id: 0, kind: kind, status: "draft", title: nil,
                                    description: nil, projectId: meeting.projectId, assigneeId: nil,
                                    dueDate: nil, dueTime: nil,
                                    source: .init(quote: segment.text, meetingId: meeting.id, startMs: segment.startMs, topic: nil),
                                    taskId: nil, proposed: nil)
    }

    private func assign(_ person: Int?, segment: Transcript.Segment, run: Int, speaker: String?) async -> Bool {
        var payload: [String: Any] = ["model_run_id": run, "person_id": person.map { $0 as Any } ?? NSNull()]
        if let speaker { payload["speaker_id"] = speaker } else { payload["segment_id"] = segment.id }
        guard await model.command(payload, path: "api/speaker/assign") else { return false }
        refreshCount += 1
        return true
    }
}
