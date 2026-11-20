import SwiftUI

struct TranscriptVoiceSelection: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: WorkspaceModel
    let meeting: Meeting
    let segments: [Transcript.Segment]
    let anchor: Transcript.Segment
    let initialSelection: Set<Int>
    let run: Int
    let onSaved: () -> Void

    @State private var marked: Set<Int> = []
    @State private var personID: Int?
    @State private var everyone = false
    @State private var query = ""
    @State private var onlyMarked = false
    @State private var previewID: Int?
    @State private var previewSelection = false
    @State private var playbackRevision = 0
    @State private var timeline: [MeetingAudioOccurrence] = []
    @State private var audioError: String?
    @State private var error: String?
    @State private var consent = false
    @State private var verified = false
    @State private var assignmentMessage: String?
    @State private var voiceStatus: VoiceStatus?
    @State private var sampleJobID: Int?
    @State private var sampleStatusError: String?

    private var sampleJob: VoiceStatus.Job? {
        voiceStatus?.voiceData.jobs.first { $0.id == sampleJobID }
    }

    private var meetingCapacity: VoiceStatus.MeetingCapacity? {
        personID.flatMap { voiceStatus?.voiceData.meetingCapacity(for: $0) }
    }

    private func sampleBlocker(duration: Int) -> String? {
        if timeline.isEmpty { return "Для образца нужно доступное аудио встречи." }
        if personID == nil { return "Выберите участника." }
        if marked.isEmpty { return "Отметьте реплики для образца." }
        if duration < 6_000 {
            return "До минимума 6 секунд не хватает " + String(format: "%.1f", Double(6_000 - duration) / 1_000) + " с."
        }
        if duration > 60_000 { return "Для одного образца оставьте не более 60 секунд." }
        if model.capture?.active != nil { return "Образец можно сохранить после остановки записи." }
        if let blocker = meetingCapacity?.blocker(for: duration) { return blocker }
        if sampleStatusError == nil, let sampleJobID,
           sampleJob?.id != sampleJobID || ["pending", "running"].contains(sampleJob?.state ?? "") {
            return "Предыдущий образец ещё обрабатывается. Реплики можно назначать."
        }
        if !consent || !verified { return "Подтвердите согласие и что в выбранном аудио один голос." }
        return nil
    }

    private var people: [Person] {
        (model.workspace?.people ?? []).filter {
            everyone || meeting.participants.contains($0.id) || $0.id == personID
        }
    }

    private var visibleSegments: [Transcript.Segment] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return segments.filter { segment in
            (!onlyMarked || marked.contains(segment.id)) &&
            (search.isEmpty || segment.text.localizedCaseInsensitiveContains(search)
                || segment.speakerLabel.localizedCaseInsensitiveContains(search))
        }
    }

    private var unassignedVoiceFragments: Set<Int> {
        guard let speaker = anchor.speakerId else { return [] }
        return Set(segments.filter { $0.speakerId == speaker && $0.personId == nil }.map(\.id))
            .subtracting(marked)
    }

    private var selectedIntervals: [MeetingVoicePlan.Interval] {
        let selected = segments.filter { marked.contains($0.id) && $0.startMs < $0.endMs }
            .sorted { $0.startMs < $1.startMs }
        var intervals: [MeetingVoicePlan.Interval] = []
        for segment in selected {
            if let last = intervals.last, segment.startMs <= last.endMs {
                intervals[intervals.count - 1] = .init(startMs: last.startMs, endMs: max(last.endMs, segment.endMs))
            } else {
                intervals.append(.init(startMs: segment.startMs, endMs: segment.endMs))
            }
        }
        return intervals
    }

    var body: some View {
        let intervals = selectedIntervals
        let selectedDuration = intervals.reduce(0) { $0 + $1.endMs - $1.startMs }
        let blocker = sampleBlocker(duration: selectedDuration)
        let sameVoice = unassignedVoiceFragments
        VStack(alignment: .leading, spacing: 12) {
            Text("Назначить говорящего по репликам").font(.title2.bold())
            HStack {
                Picker("Участник", selection: $personID) {
                    Text("Выберите участника").tag(nil as Int?)
                    ForEach(people) { Text($0.speakerPickerName).tag(Optional($0.id)) }
                }
                Toggle("Все участники", isOn: $everyone)
                if let meetingCapacity {
                    Text("Из совещаний · \(meetingCapacity.label)").foregroundStyle(.secondary)
                }
            }
            HStack {
                TextField("Найти реплику или говорящего", text: $query)
                    .textFieldStyle(.roundedBorder)
                Toggle("Только выбранные", isOn: $onlyMarked)
                Button("Снять выделение") {
                    marked.removeAll()
                    onlyMarked = false
                }
                .disabled(marked.isEmpty)
            }
            ScrollViewReader { scroll in
                let visible = visibleSegments
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(visible) { segment in
                            segmentRow(segment).id(segment.id)
                        }
                    }
                    .padding(4)
                }
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if visible.isEmpty {
                        Text("Нет подходящих реплик").foregroundStyle(.secondary)
                    }
                }
                .task(id: anchor.id) {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    scroll.scrollTo(anchor.id, anchor: .center)
                }
            }
            playbackBar(intervals: intervals, duration: selectedDuration)
            VStack(alignment: .leading, spacing: 5) {
                if !sameVoice.isEmpty {
                    Button("Отметить остальные реплики этого голоса (\(sameVoice.count))") {
                        marked.formUnion(sameVoice)
                    }
                    .buttonStyle(.link)
                }
                if !timeline.isEmpty {
                    Toggle("Участник согласен сохранить голосовой образец", isOn: $consent)
                    Toggle("В выбранных репликах звучит только его голос", isOn: $verified)
                }
                if let blocker { Text(blocker).font(.caption).foregroundStyle(.secondary) }
                if let audioError { Text(audioError).font(.caption).foregroundStyle(.secondary) }
                feedback
            }
            HStack {
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Назначить реплики") { save(includeSample: false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(personID == nil || marked.isEmpty)
                Button("Сохранить образец") { save(includeSample: true) }
                    .disabled(blocker != nil)
            }
        }
        .padding(20)
        .frame(width: 690, height: 620)
        .disabled(model.saving)
        .interactiveDismissDisabled(model.saving)
        .onChange(of: marked) { _ in
            verified = false
            previewSelection = false
            assignmentMessage = nil
        }
        .onChange(of: personID) { _ in
            consent = false
            verified = false
            assignmentMessage = nil
        }
        .task(id: sampleJobID) { await observeSample() }
        .task {
            marked = initialSelection
            personID = anchor.resolvedSpeakerID
            guard !meeting.recordings.isEmpty else { return }
            do {
                timeline = try await model.audioTimeline(for: meeting.id)
            } catch {
                if !Task.isCancelled { audioError = error.localizedDescription }
            }
        }
    }

    private func playbackBar(intervals: [MeetingVoicePlan.Interval], duration: Int) -> some View {
        HStack {
            Button {
                previewID = nil
                previewSelection = true
            } label: {
                Label("Прослушать выбранные", systemImage: "play.circle")
            }
            .disabled(timeline.isEmpty || intervals.isEmpty || previewSelection)
            if previewSelection {
                AudioIntervalPlayers(model: model, timeline: timeline, intervals: intervals,
                                     autoplay: true, compact: true)
            } else if let previewID, let segment = segments.first(where: { $0.id == previewID }) {
                Text(meetingTime(segment.startMs)).monospacedDigit()
                AudioIntervalPlayers(model: model, timeline: timeline,
                                     intervals: [.init(startMs: segment.startMs, endMs: segment.endMs)],
                                     autoplay: true, compact: true)
                    .id(playbackRevision)
            }
            Spacer()
            Text("\(marked.count) реплик · \(Double(duration) / 1000, specifier: "%.1f") с")
                .monospacedDigit().foregroundStyle(.secondary)
        }
        .frame(height: 34)
    }

    @ViewBuilder
    private var feedback: some View {
        if let error {
            Text(error).foregroundStyle(.red)
        } else if let sampleStatusError {
            Text(sampleStatusError).foregroundStyle(.red)
        } else if let sampleJob {
            switch sampleJob.state {
            case "completed":
                Label("Образец сохранён в голосовом профиле.", systemImage: "checkmark.circle")
            case "failed":
                Text(sampleJob.error ?? "Не удалось обработать образец.").foregroundStyle(.red)
            default:
                Label("Образец поставлен в очередь.", systemImage: "clock")
            }
        }
        if let assignmentMessage { Text(assignmentMessage).foregroundStyle(.secondary) }
    }

    private func segmentRow(_ segment: Transcript.Segment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: Binding(get: { marked.contains(segment.id) }, set: { selected in
                if selected { marked.insert(segment.id) } else { marked.remove(segment.id) }
            })) {
                Text("Выбрать реплику на \(meetingTime(segment.startMs))")
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            Button {
                previewSelection = false
                previewID = segment.id
                playbackRevision += 1
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(segment.text).lineLimit(2)
                        Text(meetingTime(segment.startMs) + " · " + segment.speakerLabel)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "play.circle")
                        .foregroundStyle(Color.accentColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(timeline.isEmpty)
            .accessibilityHint("Воспроизвести реплику")
        }
        .padding(8)
        .background(
            Color.accentColor.opacity(segment.id == previewID && !previewSelection ? 0.19 : segment.id == anchor.id ? 0.10 : 0),
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    private func save(includeSample: Bool) {
        guard let personID, !marked.isEmpty else { return }
        var payload: [String: Any] = ["model_run_id": run, "segment_ids": marked.sorted(),
                                      "person_id": personID, "assign": !includeSample]
        if includeSample {
            payload["enrollment"] = ["consent": consent, "single_speaker": verified]
        }
        Task {
            error = nil
            if let result = await model.assignTranscriptFragments(payload) {
                onSaved()
                if result.assigned > 0 {
                    assignmentMessage = "Реплики назначены: \(result.assigned). Можно отметить следующие."
                }
                if let job = result.jobId {
                    sampleJobID = job
                }
            } else {
                error = model.error
            }
        }
    }

    private func observeSample() async {
        sampleStatusError = nil
        while !Task.isCancelled {
            do {
                let status = try await model.voiceStatus()
                guard !Task.isCancelled else { return }
                voiceStatus = status
                if sampleJobID != nil, sampleJob == nil {
                    sampleStatusError = "Статус образца пока недоступен."
                    return
                }
                guard let job = sampleJob, ["pending", "running"].contains(job.state) else { return }
                try await Task.sleep(for: .seconds(2))
            } catch {
                if !Task.isCancelled { sampleStatusError = error.localizedDescription }
                return
            }
        }
    }
}
