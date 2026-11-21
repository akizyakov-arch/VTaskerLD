import SwiftUI

struct WorkspaceSettings: Decodable {
    var theme: String
    var timezone: String
    var autoProcess: Bool
    var meId: Int?
    var savedViews: [SavedTaskView]?

    var colorScheme: ColorScheme? {
        switch theme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}

struct SettingsForm: View {
    @ObservedObject var model: WorkspaceModel
    let people: [Person]
    @State private var draft: WorkspaceSettings

    init(model: WorkspaceModel, settings: WorkspaceSettings, people: [Person]) {
        self.model = model
        self.people = people
        _draft = State(initialValue: settings)
    }

    var body: some View {
        Form {
            Picker("Тема", selection: $draft.theme) {
                Text("Как в системе").tag("system")
                Text("Светлая").tag("light")
                Text("Тёмная").tag("dark")
            }
            TextField("Часовой пояс", text: $draft.timezone)
            Picker("Кто я", selection: $draft.meId) {
                Text("Не выбрано").tag(nil as Int?)
                ForEach(people) { person in Text(person.name).tag(Optional(person.id)) }
            }
            Toggle("Распознавать после остановки записи", isOn: $draft.autoProcess)
            Button("Сохранить") {
                Task {
                    await model.command(["op": "settings", "data": [
                        "theme": draft.theme,
                        "timezone": draft.timezone.trimmingCharacters(in: .whitespacesAndNewlines),
                        "auto_process": draft.autoProcess,
                        "me_id": draft.meId.map { $0 as Any } ?? NSNull()
                    ]])
                }
            }
            .disabled(model.loading || model.saving)
        }
        .formStyle(.grouped)
    }
}


struct AssistantVoiceSettingsForm: View {
    let canPreview: Bool
    @AppStorage(AssistantReplyVoice.preferenceKey) private var replyVoice: AssistantReplyVoice = .irina
    @StateObject private var preview = AssistantSpeech()
    @AppStorage(AssistantVoicePreferences.speakRepliesKey)
    private var speakReplies = true
    @AppStorage("assistantSemanticInterpretation") private var semanticInterpretation = true

    @AppStorage(AssistantVoicePreferences.silenceKey)
    private var silenceMilliseconds = AssistantVoicePreferences.defaultSilence
    @AppStorage(AssistantVoicePreferences.engineKey)
    private var recognitionEngine: AssistantRecognitionEngine = .macOS
    @State private var analyzerMessage = ""
    @State private var analyzerNeedsModel = false
    @State private var analyzerInstalling = false


    var body: some View {
        Form {
            Section("Ассистент") {
                Toggle("Озвучивать ответы", isOn: $speakReplies)
                Picker("Голос Валли", selection: $replyVoice) {
                    ForEach(AssistantReplyVoice.allCases) { voice in
                        Text(voice.title).tag(voice)
                    }
                }
                Button(preview.isSpeaking ? "Остановить" : "Прослушать голос") {
                    if preview.isSpeaking { preview.stop() }
                    else { preview.speak("Привет! Я Валли, ваш помощник в задачах и совещаниях.", voice: replyVoice) }
                }
                .disabled(!canPreview)
                Toggle("Понимать свободные фразы через выбранный ИИ", isOn: $semanticInterpretation)
                Text("Выбранная модель получает текст нераспознанной команды. Поиск по проектам и задачам выполняется на Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Распознавание команд", selection: $recognitionEngine) {
                    ForEach(AssistantRecognitionEngine.allCases) { engine in
                        Text(engine.title).tag(engine)
                            .disabled(engine == .speechAnalyzer && !supportsSpeechAnalyzer)
                    }
                }
                if recognitionEngine == .whisper {
                    Text("Используется локальная модель из настроек распознавания. Текст появляется после паузы.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if recognitionEngine == .speechAnalyzer {
                    Text(analyzerMessage).font(.caption).foregroundStyle(.secondary)
                    if analyzerInstalling {
                        ProgressView("Загружается модель Apple")
                    } else if analyzerNeedsModel {
                        Button("Загрузить русскую модель") { Task { await checkAnalyzer(install: true) } }
                    }
                }
                Stepper(value: $silenceMilliseconds, in: AssistantVoicePreferences.silenceRange, step: 100) {
                    LabeledContent("Пауза перед отправкой") {
                        let seconds = Double(silenceMilliseconds) / 1000
                        Text(seconds.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "ru_RU"))) +
                             " с")
                            .monospacedDigit()
                    }
                }
                Text("После паузы ассистент автоматически отправит распознанное сообщение.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: recognitionEngine) {
            if recognitionEngine == .speechAnalyzer { await checkAnalyzer() }
        }
        .onChange(of: replyVoice) { _ in preview.stop() }
        .onChange(of: canPreview) { allowed in if !allowed { preview.stop() } }
        .onDisappear { preview.stop() }
    }

    private var supportsSpeechAnalyzer: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    @MainActor
    private func checkAnalyzer(install: Bool = false) async {
        guard #available(macOS 26.0, *) else {
            analyzerMessage = "Для SpeechAnalyzer требуется macOS 26."
            return
        }
        if install { analyzerInstalling = true }
        defer { if install { analyzerInstalling = false } }
        do {
            let module = try await AppleSpeechAnalyzer.russianModule()
            if install { try await AppleSpeechAnalyzer.install(module) }
            let installed = await AppleSpeechAnalyzer.isInstalled(module)
            guard !Task.isCancelled else { return }
            analyzerNeedsModel = !installed
            if installed {
                analyzerMessage = module.usesDictation
                    ? "Русская модель диктовки Apple установлена. Распознавание работает на Mac."
                    : "Русская модель SpeechTranscriber установлена. Распознавание работает на Mac."
            } else {
                analyzerMessage = "Для работы скачайте системную языковую модель Apple."
            }
        } catch {
            if !Task.isCancelled { analyzerMessage = error.localizedDescription }
        }
    }
}
