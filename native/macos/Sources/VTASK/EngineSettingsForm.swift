import SwiftUI

struct AIBudget: Decodable {
    struct Usage: Decodable, Identifiable {
        let stage: String
        let phase: String
        let todayTokens: Int
        let monthTokens: Int
        let monthRequests: Int
        let inputTokens: Int
        let outputTokens: Int

        var id: String { stage + "/" + phase }
        var title: String {
            let name = ["manual": "Ручной анализ", "automatic": "После записи", "live": "Во время записи",
                        "assistant": "Валли"][stage] ?? stage
            let detail = ["synthesis": "сводка", "extraction": "извлечение", "interpret": "команды"][phase] ?? phase
            return "\(name) · \(detail)"
        }
    }

    let dailyTokens: Int
    let monthlyTokens: Int
    let todayTokens: Int
    let monthTokens: Int
    let estimatedTokens: Int
    let stages: [Usage]
}

struct EngineSettings: Decodable {
    struct Speech: Decodable {
        var settings: SpeechPreferences
        let keyPresent: Bool
    }

    struct Groq: Decodable {
        let model: String
        let liveModel: String?
        let livePreview: Bool?
        let hasKey: Bool
        let busy: Bool
        let automatic: Bool
    }

    let microphone: MicrophoneStatus?
    let speech: Speech
    let groq: Groq
}

struct SpeechPreferences: Decodable {
    var provider: String?
    var localModel: String?
    var url: String?
    var model: String?
    var format: String?
    var processingMode: String?
    var speakerDetection: Bool?
}

struct EngineSettingsForm: View {
    @ObservedObject var model: WorkspaceModel
    @State private var status: EngineSettings?
    @State private var provider = "local"
    @State private var localModel = ""
    @State private var endpoint = ""
    @State private var cloudModel = ""
    @State private var format = "json"
    @State private var mode = "post"
    @State private var speakerDetection = true
    @State private var speechKey = ""
    @State private var groqKey = ""
    @State private var aiProvider = "groq"
    @State private var aiModel = "openai/gpt-oss-120b"
    @State private var persistAIKey = true
    @State private var automaticAI = false
    @State private var livePreview = false
    @State private var useFullProfile = true
    @State private var liveProvider = "groq"
    @State private var liveModel = "openai/gpt-oss-120b"
    @State private var liveKey = ""
    @State private var persistLiveKey = true
    @State private var budget: AIBudget?
    @State private var dailyTokens = 0
    @State private var monthlyTokens = 0
    private let aiProviders = ["groq", "deepseek", "openai", "anthropic", "gemini", "mistral"]
    private let aiNames = ["groq": "Groq", "deepseek": "DeepSeek", "openai": "OpenAI",
                           "anthropic": "Anthropic · Claude", "gemini": "Google · Gemini", "mistral": "Mistral"]
    private let aiDefaults = ["groq": "openai/gpt-oss-120b", "deepseek": "deepseek-flash",
                              "openai": "gpt-4.1-mini", "anthropic": "claude-sonnet-4-5",
                              "gemini": "gemini-2.5-flash", "mistral": "mistral-small-latest"]
    @State private var error: String?
    @State private var message: String?

    var body: some View {
        Form {
            if let error { Text(error).foregroundStyle(.red) }
            if let message { Text(message).foregroundStyle(.secondary) }
            if let status {
                Section("ИИ для полного анализа и Валли") {
                    Picker("Провайдер", selection: Binding(get: { aiProvider }, set: { id in
                        aiProvider = id
                        aiModel = aiDefaults[id] ?? ""
                        groqKey = ""
                    })) {
                        ForEach(aiProviders, id: \.self) { id in Text(aiNames[id] ?? id).tag(id) }
                    }
                    TextField("Модель API", text: $aiModel)
                    Text(status.groq.hasKey ? "Для активного провайдера ключ подключён." : "Добавьте API-ключ, чтобы подключить провайдера.")
                        .font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("API-ключ").font(.headline)
                        SecureField("Вставьте ключ " + (aiNames[aiProvider] ?? aiProvider), text: $groqKey)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("API-ключ выбранного провайдера")
                    }
                    Toggle("Сохранить ключ в Связке ключей macOS", isOn: $persistAIKey)
                    Text("Протокол и запросы Валли отправляются выбранному провайдеру. Для каждого провайдера хранится отдельный ключ.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Сохранить настройки ИИ") {
                        Task {
                            let selected = aiProvider == "groq" ? aiModel : aiProvider + ":" + aiModel
                            if await model.command(["api_key": groqKey, "model": selected,
                                                    "persist": persistAIKey],
                                                   path: "api/groq/settings") {
                                groqKey = ""
                                message = "Настройки ИИ сохранены."
                                await load()
                            }
                        }
                    }
                    .disabled(aiModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || status.groq.busy)
                    Button("Удалить ключ выбранного провайдера", role: .destructive) {
                        Task {
                            if await model.command(["clear_key": true], path: "api/groq/settings") {
                                message = "Ключ активного провайдера удалён."
                                await load()
                            }
                        }
                    }
                    .disabled(status.groq.busy || !status.groq.hasKey ||
                              status.groq.model != (aiProvider == "groq" ? aiModel : aiProvider + ":" + aiModel))
                }
                budgetSection
                Section("ИИ для анализа на лету") {
                    Toggle("Анализировать фрагменты во время записи Live", isOn: $livePreview)
                    Toggle("Автоматически анализировать после записи", isOn: $automaticAI)
                    Toggle("Использовать профиль полного анализа", isOn: $useFullProfile)
                    if !useFullProfile {
                        Picker("Провайдер", selection: Binding(get: { liveProvider }, set: { id in
                            liveProvider = id
                            liveModel = aiDefaults[id] ?? ""
                            liveKey = ""
                        })) {
                            ForEach(aiProviders, id: \.self) { id in Text(aiNames[id] ?? id).tag(id) }
                        }
                        TextField("Модель API", text: $liveModel)
                        SecureField("API-ключ " + (aiNames[liveProvider] ?? liveProvider), text: $liveKey)
                            .textFieldStyle(.roundedBorder)
                        Toggle("Сохранить ключ в Связке ключей macOS", isOn: $persistLiveKey)
                        Text("Если ключ этого провайдера уже сохранён, поле можно оставить пустым.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Во время записи Live выбранный провайдер получает текст фрагментов. Предварительные итоги видны у Валли.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Сохранить профиль анализа на лету") {
                        Task {
                            let name = liveModel.trimmingCharacters(in: .whitespacesAndNewlines)
                            let selected = liveProvider == "groq" ? name : liveProvider + ":" + name
                            var settings: [String: Any] = ["profile": "live", "automatic": automaticAI, "live_preview": livePreview,
                                                           "use_full_profile": useFullProfile]
                            if !useFullProfile {
                                settings["model"] = selected
                                settings["api_key"] = liveKey
                                settings["persist"] = persistLiveKey
                            }
                            if await model.command(settings, path: "api/groq/settings") {
                                liveKey = ""
                                message = "Профиль анализа на лету сохранён."
                                await load()
                            }
                        }
                    }
                    .disabled(status.groq.busy || (!useFullProfile && liveModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
                MicrophoneSettingsForm(model: model)
                Section("Распознавание речи") {
                    Toggle("Определять говорящих", isOn: Binding(
                        get: { speakerDetection },
                        set: { enabled in
                            Task {
                                if await model.command(["enabled": enabled], path: "api/speech/speakers") {
                                    speakerDetection = enabled
                                } else {
                                    error = model.error
                                }
                            }
                        }
                    ))
                    Text("Сохраняется сразу. Для новых записей и заданий выключение пропускает определение голосов. Расшифровка текста остаётся доступной.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Поставщик", selection: $provider) {
                        Text("Локальная модель").tag("local")
                        Text("Облачный API").tag("cloud")
                    }
                    TextField("Путь к модели Whisper", text: $localModel)
                    Picker("Режим", selection: $mode) {
                        Text("После записи").tag("post")
                        Text("Во время записи").tag("live")
                    }
                    if provider == "cloud" {
                        TextField("HTTPS-адрес API", text: $endpoint)
                        TextField("Имя модели", text: $cloudModel)
                        Picker("Формат ответа", selection: $format) {
                            Text("JSON").tag("json")
                            Text("JSON с таймкодами").tag("verbose_json")
                        }
                        SecureField(status.speech.keyPresent ? "Заменить ключ API" : "Ключ API", text: $speechKey)
                    }
                    Button("Сохранить распознавание") { Task { await saveSpeech() } }
                }

            } else if error == nil {
                ProgressView()
            } else {
                Button("Повторить загрузку") { Task { await load() } }
            }
        }
        .formStyle(.grouped)
        .disabled(model.saving || model.loading)
        .task { await load() }
        .task(id: status?.groq.busy) {
            while status?.groq.busy == true {
                do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
                guard !Task.isCancelled else { return }
                await load()
            }
        }
    }

    private var budgetSection: some View {
        Section("Бюджет внешнего ИИ") {
            TextField("Дневной лимит токенов", value: $dailyTokens, format: .number)
            TextField("Месячный лимит токенов", value: $monthlyTokens, format: .number)
            Text("0 — без лимита. Периоды считаются по UTC. Учитываются анализ совещаний и команды Валли.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Сохранить лимиты") {
                    Task {
                        if await model.command(["daily_tokens": dailyTokens, "monthly_tokens": monthlyTokens],
                                               path: "api/groq/budget") {
                            message = "Лимиты сохранены."
                            await loadBudget()
                        } else {
                            error = model.error
                        }
                    }
                }
                .disabled(!(0...1_000_000_000).contains(dailyTokens) || !(0...1_000_000_000).contains(monthlyTokens))
                Button("Обновить расход") { Task { await loadBudget(resetLimits: false) } }
            }
            if let budget {
                LabeledContent("Сегодня", value: budget.todayTokens.formatted())
                LabeledContent("В этом месяце", value: budget.monthTokens.formatted())
                ForEach(budget.stages) { usage in
                    LabeledContent(usage.title, value: "\(usage.monthTokens.formatted()) ток. · \(usage.monthRequests.formatted()) запр.")
                }
                if budget.estimatedTokens > 0 {
                    Text("Учтено по оценке или зарезервировано: \(budget.estimatedTokens.formatted()) ток. за месяц.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func loadBudget(resetLimits: Bool = true) async {
        do {
            let current = try await model.aiBudget()
            budget = current
            if resetLimits {
                dailyTokens = current.dailyTokens
                monthlyTokens = current.monthlyTokens
            }
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func load() async {
        do {
            let result = try await model.engineSettings()
            let prefs = result.speech.settings
            provider = prefs.provider ?? "local"
            localModel = prefs.localModel ?? ""
            endpoint = prefs.url ?? "https://api.openai.com/v1/audio/transcriptions"
            cloudModel = prefs.model ?? "gpt-transcribe"
            format = prefs.format ?? "json"
            mode = prefs.processingMode ?? "post"
            speakerDetection = prefs.speakerDetection ?? true
            let parts = result.groq.model.split(separator: ":", maxSplits: 1).map(String.init)
            aiProvider = parts.count == 2 ? parts[0] : "groq"
            aiModel = parts.count == 2 ? parts[1] : result.groq.model
            automaticAI = result.groq.automatic
            livePreview = result.groq.livePreview ?? false
            useFullProfile = result.groq.liveModel == nil
            let live = (result.groq.liveModel ?? result.groq.model).split(separator: ":", maxSplits: 1).map(String.init)
            liveProvider = live.count == 2 ? live[0] : "groq"
            liveModel = live.last ?? ""
            status = result
            error = nil
            if budget == nil { await loadBudget() }
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func saveSpeech() async {
        let payload = [
            "provider": provider, "local_model": localModel, "url": endpoint, "model": cloudModel,
            "format": format, "processing_mode": provider == "cloud" ? "post" : mode,
            "api_key": speechKey
        ]
        if await model.command(payload, path: "api/speech/settings") {
            speechKey = ""
            await load()
            message = "Настройки распознавания сохранены."
        }
    }
}
