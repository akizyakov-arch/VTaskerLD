import SwiftUI
import UniformTypeIdentifiers

struct VoiceStatus: Decodable, Equatable {
    struct Capture: Decodable, Equatable {
        let draft: Draft?
    }

    struct Draft: Decodable, Equatable {
        let id: String
        let personId: Int
        let state: String
        let error: String?
        let phrases: [String]?
        let phraseIndex: Int?
        let elapsedMs: Int?
        let limitSeconds: Int?
        let level: Double?

        var statusLabel: String {
            switch state {
            case "starting": return "Подключение микрофона"
            case "recording": return "Идёт запись"
            case "stopping", "preparing": return "Подготовка образца"
            case "ready": return "Образец готов к прослушиванию"
            default: return "Образец не принят"
            }
        }
    }

    struct Data: Decodable, Equatable {
        let profiles: [Profile]
        let sampleLimit: Int?
        let jobs: [Job]
        let matchJobs: [MatchJob]?
        let settings: VoiceMatchingSettings?

        struct MatchJob: Decodable, Equatable {
            let id: Int
            let modelRunId: Int
            let state: String
            let error: String?
        }
    }

    struct Profile: Decodable, Equatable {
        let personId: Int
        let sampleCount: Int
    }

    struct Job: Decodable, Equatable {
        let personId: Int
        let state: String
        let error: String?
    }

    let voiceCapture: Capture
    let voiceData: Data
}

struct VoiceProfileView: View {
    @ObservedObject var model: WorkspaceModel
    let person: Person
    @State private var status: VoiceStatus?
    @State private var consent = false
    @State private var phraseIndex = 0
    @State private var singleSpeaker = false
    @State private var confirmDeletion = false
    @State private var statusError: String?
    @State private var pickingSample = false
    @State private var showingUpload = false

    var body: some View {
        Section("Голосовой профиль") {
            if let statusError { Text(statusError).foregroundStyle(.red) }
            if let status {
                let profiles = status.voiceData.profiles.filter { $0.personId == person.id }
                let count = profiles.reduce(0) { $0 + $1.sampleCount }
                let limit = status.voiceData.sampleLimit
                LabeledContent("Образцы в профиле", value: limit.map { "\(count) из \($0)" } ?? String(count))
                if let job = status.voiceData.jobs.first(where: { $0.personId == person.id }) {
                    if job.state == "pending" || job.state == "running" {
                        Text("Создаётся голосовой профиль…")
                    }
                    if let error = job.error { Text(error).foregroundStyle(.red) }
                }
                if let draft = status.voiceCapture.draft {
                    if draft.personId == person.id {
                        draftControls(draft)
                    } else {
                        Text("Открыт образец другого участника.")
                    }
                } else {
                    Toggle("Участник согласен на запись и создание голосового профиля", isOn: $consent)
                    Text("Прочитайте каждую фразу обычным голосом и сделайте паузу примерно на полторы секунды.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Записать образец") { Task { await start() } }.disabled(!consent)
                    DisclosureGroup("Загрузить готовый образец WAV", isExpanded: $showingUpload) {
                        Toggle("В файле звучит только голос этого участника", isOn: $singleSpeaker)
                        Button("Выбрать WAV") { pickingSample = true }
                            .disabled(!consent || !singleSpeaker || model.capture?.active != nil)
                    }
                }
                if !profiles.isEmpty {
                    Button("Удалить голосовой профиль", role: .destructive) { confirmDeletion = true }
                        .confirmationDialog("Удалить образцы и голосовой профиль?", isPresented: $confirmDeletion) {
                            Button("Удалить", role: .destructive) {
                                Task { await perform("api/voice/delete", fields: ["confirmed": true]) }
                            }
                        }
                }
            } else if statusError == nil {
                ProgressView()
            }
        }
        .onChange(of: status?.voiceCapture.draft?.id) { _ in phraseIndex = 0 }
        .disabled(model.loading || model.saving)
        .fileImporter(isPresented: $pickingSample, allowedContentTypes: [.wav]) { result in
            switch result {
            case .success(let url):
                guard consent && singleSpeaker else { return }
                Task {
                    if await model.enrollVoice(from: url, personID: person.id) {
                        consent = false
                        singleSpeaker = false
                        showingUpload = false
                    }
                    await refresh()
                }
            case .failure(let error): statusError = error.localizedDescription
            }
        }
        .task {
            while !Task.isCancelled {
                await refresh()
                let recording = status?.voiceCapture.draft?.state == "recording"
                try? await Task.sleep(for: .milliseconds(recording ? 400 : 1500))
            }
        }
    }

    @ViewBuilder
    private func draftControls(_ draft: VoiceStatus.Draft) -> some View {
        Text(draft.statusLabel)
        if let error = draft.error { Text(error).foregroundStyle(.red) }
        if draft.state == "recording" {
            let limit = max(1, draft.limitSeconds ?? 45)
            let elapsed = min(limit * 1000, max(0, draft.elapsedMs ?? 0))
            ProgressView(value: Double(elapsed), total: Double(limit * 1000)) {
                Text("Время записи")
            } currentValueLabel: {
                Text(meetingTime(elapsed) + " / " + meetingTime(limit * 1000)).monospacedDigit()
            }
            ProgressView("Уровень микрофона", value: min(1, max(0, (draft.level ?? 0) * 4)))
                .tint(.green)
            let index = draft.phraseIndex ?? phraseIndex
            if let phrases = draft.phrases, phrases.indices.contains(index) {
                Text("Фраза \(index + 1) из \(phrases.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(phrases[index]).font(.headline).fixedSize(horizontal: false, vertical: true)
                if index + 1 < phrases.count {
                    Button("Следующая фраза") {
                        if draft.phraseIndex != nil {
                            Task { await perform("api/voice/capture/next", draft: draft, fields: ["phrase_index": index]) }
                        } else {
                            phraseIndex += 1
                        }
                    }
                }
            } else if draft.phrases != nil {
                Label("Все фразы прочитаны", systemImage: "checkmark.circle")
            } else {
                Text("Попросите участника говорить обычным голосом.")
            }
            Button("Остановить запись") { Task { await perform("api/voice/capture/stop", draft: draft) } }
        }
        if ["ready", "rejected"].contains(draft.state) {
            RecordingPlayer(url: model.voiceSampleURL(draft.id)).id(draft.id)
        }
        if draft.state == "ready" {
            Toggle("Участник подтвердил согласие", isOn: $consent)
            Toggle("В записи звучит только голос этого участника", isOn: $singleSpeaker)
            Button("Создать профиль") {
                Task { await perform("api/voice/capture/accept", draft: draft, fields: ["consent": true, "single_speaker": true]) }
            }
            .disabled(!consent || !singleSpeaker)
        }
        Button("Отменить образец") { Task { await perform("api/voice/capture/cancel", draft: draft) } }
    }

    private func start() async {
        singleSpeaker = false
        await perform("api/voice/capture/start", fields: ["consent": consent])
    }

    private func perform(_ path: String, draft: VoiceStatus.Draft? = nil, fields: [String: Any] = [:]) async {
        var payload = fields
        payload["person_id"] = person.id
        payload["draft_id"] = draft?.id
        await model.command(payload, path: path)
        await refresh()
    }

    private func refresh() async {
        do {
            let latest = try await model.voiceStatus()
            if status != latest { status = latest }
            if statusError != nil { statusError = nil }
        } catch {
            if !Task.isCancelled && statusError != error.localizedDescription {
                statusError = error.localizedDescription
            }
        }
    }
}


struct VoiceMatchingSettings: Decodable, Equatable {
    let enabled: Bool
    let threshold: Double
    let margin: Double
}

struct VoiceMatchingSettingsForm: View {
    @ObservedObject var model: WorkspaceModel
    @State private var enabled = false
    @State private var threshold = 0.75
    @State private var margin = 0.1
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("Сопоставление голосов") {
                if let error { Text(error).foregroundStyle(.red) }
                if loaded {
                    Toggle("Искать совпадения после распознавания", isOn: $enabled)
                    Stepper(value: $threshold, in: 0.50...0.99, step: 0.01) {
                        Text("Порог сходства · \(threshold, specifier: "%.2f")")
                    }
                    Stepper(value: $margin, in: 0.05...0.50, step: 0.01) {
                        Text("Отрыв от второго кандидата · \(margin, specifier: "%.2f")")
                    }
                    Text("Подсказки по именам подтверждаются в протоколе.").foregroundStyle(.secondary)
                    Button("Сохранить параметры голосов") {
                        Task {
                            await model.command(["enabled": enabled,
                                                 "threshold": (threshold * 100).rounded() / 100,
                                                 "margin": (margin * 100).rounded() / 100],
                                                path: "api/voice/matching/settings")
                        }
                    }
                    .disabled(model.saving)
                } else if error == nil {
                    ProgressView()
                }
            }
        }
        .formStyle(.grouped)
        .task {
            do {
                guard let settings = try await model.voiceStatus().voiceData.settings else {
                    error = "Ядро не вернуло параметры сопоставления."
                    return
                }
                enabled = settings.enabled
                threshold = settings.threshold
                margin = settings.margin
                loaded = true
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}
