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
}

struct MeetingVoiceSource: Identifiable {
    let run: Int
    let speaker: String
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
    @State private var timeline: [MeetingAudioOccurrence]?
    @State private var error: String?

    var body: some View {
        Form {
            Text(segment.text).textSelection(.enabled)
            if let timeline {
                AudioIntervalPlayers(model: model, timeline: timeline, start: segment.startMs, end: segment.endMs)
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

    var body: some View {
        Form {
            if let plan {
                Section("Прослушайте выбранные участки") {
                    Text("\(source.speaker) · \(Double(plan.durationMs) / 1000, specifier: "%.1f") с чистой речи")
                    ForEach(plan.intervals, id: \.self) { interval in
                        AudioIntervalPlayers(model: model, timeline: timeline, start: interval.startMs, end: interval.endMs)
                    }
                }
                Picker("Участник", selection: $personID) {
                    Text("Выберите участника").tag(nil as Int?)
                    ForEach((model.workspace?.people ?? []).filter { meeting.participants.contains($0.id) }) {
                        Text($0.name).tag(Optional($0.id))
                    }
                }
                Toggle("Участник согласен на создание голосового профиля", isOn: $consent)
                Toggle("На выбранных участках звучит только этот участник", isOn: $singleSpeaker)
                Button("Создать профиль") {
                    guard let personID else { return }
                    Task {
                        if await model.command([
                            "person_id": personID, "model_run_id": source.run, "speaker_id": source.speaker,
                            "consent": consent, "single_speaker": singleSpeaker
                        ], path: "api/voice/from-meeting") {
                            dismiss()
                        }
                    }
                }
                .disabled(!consent || !singleSpeaker || personID == nil || timeline.isEmpty)
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
        .task {
            do {
                let result = try await model.voiceSource(run: source.run, speaker: source.speaker)
                timeline = try await model.audioTimeline(for: meeting.id)
                plan = result
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}

private struct AudioIntervalPlayers: View {
    @ObservedObject var model: WorkspaceModel
    let timeline: [MeetingAudioOccurrence]
    let start: Int
    let end: Int

    var body: some View {
        let parts = timeline.filter { $0.startMs < end && $0.endMs > start }
        if parts.isEmpty { Text("Аудио для этого фрагмента недоступно.").foregroundStyle(.secondary) }
        ForEach(parts, id: \.occurrenceId) { part in
            let from = max(part.startMs, start)
            let to = min(part.endMs, end)
            LabeledContent(meetingTime(from) + " – " + meetingTime(to)) {
                RecordingPlayer(url: model.recordingURL(Recording(id: part.recordingId)),
                                startMs: from - part.startMs, endMs: to - part.startMs)
            }
        }
    }
}
