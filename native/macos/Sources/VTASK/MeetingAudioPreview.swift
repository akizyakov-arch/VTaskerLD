import AVFoundation
import SwiftUI

struct MeetingAudioOccurrence: Decodable {
    let occurrenceId: Int
    let recordingId: Int
    let startMs: Int
    let endMs: Int
}

struct MeetingVoicePlan: Decodable {
    struct Interval: Decodable, Hashable {
        let startMs: Int
        let endMs: Int
    }

    let durationMs: Int
    let intervals: [Interval]
    let minimumEnrollmentMs: Int?
}

struct MeetingVoiceSource: Identifiable {
    let run: Int
    let speaker: String
    var personID: Int? = nil
    var id: String { "\(run)-\(speaker)" }
}

func meetingTime(_ milliseconds: Int) -> String {
    let seconds = milliseconds / 1000
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
}

struct MeetingAudioPreview: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: WorkspaceModel
    let meetingID: Int
    let segment: Transcript.Segment
    var endMs: Int? = nil
    var previewText: String? = nil
    var autoplay = false
    @State private var timeline: [MeetingAudioOccurrence]?
    @State private var error: String?

    var body: some View {
        Form {
            Text(previewText ?? segment.text).textSelection(.enabled)
            if let timeline {
                AudioIntervalPlayers(model: model, timeline: timeline, start: segment.startMs,
                                     end: endMs ?? segment.endMs, autoplay: autoplay)
            } else if let error {
                Text(error).foregroundStyle(.red)
            } else {
                ProgressView()
            }
            Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 380)
        .task {
            do { timeline = try await model.audioTimeline(for: meetingID) }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

struct MeetingVoiceEnrollment: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: WorkspaceModel
    let meeting: Meeting
    let source: MeetingVoiceSource
    @State private var plan: MeetingVoicePlan?
    @State private var timeline: [MeetingAudioOccurrence] = []
    @State private var personID: Int?
    @State private var consent = false
    @State private var singleSpeaker = false
    @State private var error: String?
    @State private var queued = false
    @State private var recordingPerson: Person?
    @State private var voiceStatus: VoiceStatus?

    private var selectedPerson: Person? {
        model.workspace?.people.first { $0.id == personID }
    }

    var body: some View {
        Form {
            if queued {
                Label("Образец в очереди обработки", systemImage: "checkmark.circle")
                Text("После обработки он пополнит голосовой профиль участника и будет доступен для будущих совещаний.")
                    .foregroundStyle(.secondary)
            } else if let plan, plan.durationMs < (plan.minimumEnrollmentMs ?? 6_000) {
                let minimum = plan.minimumEnrollmentMs ?? 6_000
                Section("Для образца нужно больше речи") {
                    Text("В записи доступно \(Double(plan.durationMs) / 1_000, specifier: "%.1f") с чистой речи этого участника. Для профиля нужно минимум \(minimum / 1_000) с.")
                        .foregroundStyle(.secondary)
                    participantField
                    if let selectedPerson {
                        Button("Записать образец по фразам") { recordingPerson = selectedPerson }
                            .disabled(model.capture?.active != nil)
                    }
                }
            } else if let plan {
                let capacity = personID.flatMap { voiceStatus?.voiceData.meetingCapacity(for: $0) }
                let blocker = capacity?.blocker(for: plan.durationMs)
                Section("Прослушайте выбранные участки") {
                    Text("\(source.speaker) · \(Double(plan.durationMs) / 1000, specifier: "%.1f") с чистой речи")
                    AudioIntervalPlayers(model: model, timeline: timeline, intervals: plan.intervals)
                }
                participantField
                if let capacity { LabeledContent("Реплики из совещаний", value: capacity.label) }
                if blocker != nil {
                    Text("Для этого образца недостаточно места. Более короткий отрывок можно выбрать в списке реплик.")
                        .foregroundStyle(.secondary)
                }
                Toggle("Участник согласен на создание голосового профиля", isOn: $consent)
                Toggle("На выбранных участках звучит только этот участник", isOn: $singleSpeaker)
                Button("Сохранить образец для будущих встреч") {
                    guard let personID else { return }
                    Task {
                        if await model.command([
                            "person_id": personID, "model_run_id": source.run, "speaker_id": source.speaker,
                            "consent": consent, "single_speaker": singleSpeaker
                        ], path: "api/voice/from-meeting") {
                            queued = true
                        }
                    }
                }
                .disabled(!consent || !singleSpeaker || personID == nil || timeline.isEmpty || blocker != nil)
                if let error = model.error { Text(error).foregroundStyle(.red) }
            } else if let error {
                Text(error).foregroundStyle(.red)
            } else {
                ProgressView()
            }
            Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
        .disabled(model.saving)
        .interactiveDismissDisabled(model.saving)
        .sheet(item: $recordingPerson) { person in
            Form {
                Text(person.speakerPickerName).font(.headline)
                VoiceProfileView(model: model, person: person)
            }
            .formStyle(.grouped)
            .frame(width: 520, height: 560)
            .sheetCloseButton(disabled: model.saving)
        }
        .task {
            personID = source.personID
            do {
                let result = try await model.voiceSource(run: source.run, speaker: source.speaker)
                if result.durationMs >= (result.minimumEnrollmentMs ?? 6_000) {
                    timeline = try await model.audioTimeline(for: meeting.id)
                }
                plan = result
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
        .task {
            voiceStatus = try? await model.voiceStatus()
        }
    }

    @ViewBuilder
    private var participantField: some View {
        if source.personID != nil, let selectedPerson {
            LabeledContent("Участник", value: selectedPerson.speakerPickerName)
        } else {
            Picker("Участник", selection: $personID) {
                Text("Выберите участника").tag(nil as Int?)
                ForEach((model.workspace?.people ?? []).filter { meeting.participants.contains($0.id) }) {
                    Text($0.speakerPickerName).tag(Optional($0.id))
                }
            }
        }
    }
}

struct AudioIntervalPlayers: View {
    @ObservedObject var model: WorkspaceModel
    let timeline: [MeetingAudioOccurrence]
    let intervals: [MeetingVoicePlan.Interval]
    let autoplay: Bool
    let compact: Bool

    init(model: WorkspaceModel, timeline: [MeetingAudioOccurrence], intervals: [MeetingVoicePlan.Interval],
         autoplay: Bool = false, compact: Bool = false) {
        self.model = model
        self.timeline = timeline
        self.intervals = intervals
        self.autoplay = autoplay
        self.compact = compact
    }

    init(model: WorkspaceModel, timeline: [MeetingAudioOccurrence], start: Int, end: Int, autoplay: Bool = false) {
        self.init(model: model, timeline: timeline, intervals: [.init(startMs: start, endMs: end)], autoplay: autoplay)
    }

    var body: some View {
        let parts = intervals.flatMap { interval in
            timeline.compactMap { occurrence -> AudioSequencePlayer.Part? in
                let start = max(occurrence.startMs, interval.startMs)
                let end = min(occurrence.endMs, interval.endMs)
                guard start < end else { return nil }
                return .init(url: model.recordingURL(Recording(id: occurrence.recordingId)),
                             startMs: start - occurrence.startMs, endMs: end - occurrence.startMs)
            }
        }
        if parts.isEmpty {
            Text("Аудио для этих реплик недоступно.").foregroundStyle(.secondary)
        } else {
            AudioSequencePlayer(parts: parts, autoplay: autoplay, compact: compact).id(parts)
        }
    }
}

private struct AudioSequencePlayer: View {
    struct Part: Hashable {
        let url: URL
        let startMs: Int
        let endMs: Int
    }

    let parts: [Part]
    let autoplay: Bool
    let compact: Bool
    @State private var player: AVPlayer?
    @State private var index = 0
    @State private var error: String?
    @State private var finished = false
    @State private var playing = false

    var body: some View {
        if let player {
            VStack(alignment: .leading, spacing: 4) {
                if compact {
                    HStack(spacing: 8) {
                        Button {
                            if finished {
                                replay(on: player)
                            } else if playing {
                                player.pause()
                            } else {
                                player.play()
                            }
                        } label: {
                            Image(systemName: playing ? "pause.fill" : "play.fill")
                                .frame(width: 22)
                        }
                        .accessibilityLabel(playing ? "Пауза" : "Воспроизвести")
                        Button {
                            player.replaceCurrentItem(with: nil)
                            finished = true
                        } label: {
                            Image(systemName: "stop.fill").frame(width: 22)
                        }
                        .accessibilityLabel("Остановить")
                        .disabled(finished)
                        if let error {
                            Text(error).foregroundStyle(.red).lineLimit(1)
                        }
                    }
                } else {
                    RecordingPlayerView(player: player).frame(height: 58)
                }
                if !compact && finished {
                    Button("Прослушать снова") {
                        replay(on: player)
                    }
                }
                if !compact, let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .task(id: index) { startPart(on: player) }
            .onReceive(player.publisher(for: \.timeControlStatus)) { status in
                playing = status != .paused
            }
            .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { event in
                guard (event.object as? AVPlayerItem) === player.currentItem else { return }
                if index + 1 < parts.count { index += 1 } else { finished = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification)) { event in
                guard (event.object as? AVPlayerItem) === player.currentItem else { return }
                error = "Не удалось воспроизвести аудио выбранной реплики."
                finished = true
            }
            .onDisappear { player.replaceCurrentItem(with: nil) }
        } else {
            Button("Воспроизвести") { player = AVPlayer() }
                .task {
                    if autoplay && player == nil { player = AVPlayer() }
                }
        }
    }

    private func replay(on player: AVPlayer) {
        finished = false
        if index == 0 {
            startPart(on: player)
        } else {
            index = 0
        }
    }

    private func startPart(on player: AVPlayer) {
        let part = parts[index]
        let item = AVPlayerItem(url: part.url)
        error = nil
        item.forwardPlaybackEndTime = CMTime(value: Int64(part.endMs), timescale: 1_000)
        player.replaceCurrentItem(with: item)
        let start = CMTime(value: Int64(part.startMs), timescale: 1_000)
        player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { ready in
            Task { @MainActor in
                guard player.currentItem === item else { return }
                if ready {
                    player.play()
                } else {
                    error = "Не удалось открыть аудио выбранной реплики."
                    finished = true
                }
            }
        }
    }
}
