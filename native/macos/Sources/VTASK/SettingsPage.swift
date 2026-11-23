import AppKit
import SwiftUI

enum SettingsArea: String, CaseIterable, Identifiable {
    case general, providers, analysis, speech, valli, terminology, account

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "Основные"
        case .providers: return "Модели и провайдеры"
        case .analysis: return "Профили анализа"
        case .speech: return "Распознавание речи"
        case .valli: return "Голосовой помощник Валли"
        case .terminology: return "Отрасли и словари"
        case .account: return "Рабочее пространство"
        }
    }

    var detail: String {
        switch self {
        case .general: return "Ключевые параметры работы приложения"
        case .providers: return "Модели разбора протокола и команд Валли"
        case .analysis: return "Автоматический анализ, лайв-режим и лимиты токенов"
        case .speech: return "Микрофон, транскрипция и сопоставление голосов"
        case .valli: return "Голос, движок распознавания команд и пауза перед отправкой"
        case .terminology: return "Отрасль компании и словарь для совещаний"
        case .account: return "Ваш профиль и настройки записи"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .providers: return "sparkles"
        case .analysis: return "chart.bar.xaxis"
        case .speech: return "mic"
        case .valli: return "waveform"
        case .terminology: return "book"
        case .account: return "square.3.layers.3d"
        }
    }

    var searchText: String {
        let keywords: String
        switch self {
        case .general: keywords = "язык регион часовой пояс время дата оформление темы светлая темная как в системе"
        case .providers: keywords = "ИИ API ключ Groq DeepSeek Ollama Qwen OpenAI Gemini Claude Mistral"
        case .analysis: keywords = "ИИ статистика токены бюджет лимит live итоги протокол автоматически"
        case .speech: keywords = "ASR Whisper голоса слепки шум микрофон"
        case .valli: keywords = "SpeechAnalyzer Apple голос озвучка команда Вэлли Vally Wally"
        case .terminology: keywords = "словарь справочник отраслевая специализация термины этапы работ импорт экспорт"
        case .account: keywords = "кто я профиль сотрудник автообработка после записи"
        }
        return title + " " + detail + " " + keywords
    }
}

struct SettingsPage: View {
    @ObservedObject var model: WorkspaceModel
    let workspace: Workspace
    @Binding var area: SettingsArea
    let openGlossary: () -> Void
    let openWorkPeriodCatalog: () -> Void
    let openProcessing: () -> Void

    @Environment(\.colorScheme) private var scheme
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var timezone = ""
    @State private var aiExpanded = true

    private static let ribbon: NSImage? = {
        let url = Bundle.main.url(forResource: "settings-ribbon", withExtension: "png")
            ?? Bundle.module.url(forResource: "settings-ribbon", withExtension: "png")
        return url.flatMap(NSImage.init(contentsOf:))
    }()
    private let aiAreas: [SettingsArea] = [.providers, .analysis, .speech, .valli]
    private var palette: PanelPalette { PanelPalette(dark: scheme == .dark) }
    private var accent: Color { scheme == .dark ? palette.accent : Color(red: 0.34, green: 0.24, blue: 0.85) }
    private var saving: Bool { model.loading || model.saving }
    private var searchResults: [SettingsArea] {
        let words = query.split(whereSeparator: \.isWhitespace)
        return SettingsArea.allCases.filter { item in
            words.allSatisfy { item.searchText.localizedStandardContains(String($0)) }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 850
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    if !wide {
                        Picker("Раздел настроек", selection: $area) {
                            ForEach(SettingsArea.allCases) { section in Text(section.title).tag(section) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 235)
                    }
                    Spacer(minLength: 0)
                    settingsSearch
                        .onSubmit {
                            if let first = searchResults.first, !query.isEmpty { select(first) }
                        }
                        .frame(maxWidth: 310)
                    Button { searchFocused = true } label: {
                        Text("⌘K").font(.caption.monospaced())
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("k", modifiers: .command)
                    .accessibilityLabel("Перейти к поиску по настройкам")
                }
                HStack(alignment: .top, spacing: 12) {
                    if wide {
                        sidebar.frame(width: 205)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                banner
                                sectionContent(twoColumns: geometry.size.width >= 595)
                            } else {
                                results
                            }
                            if let error = model.error {
                                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(1)
                    }
                }
            }
            .padding(14)
        }
        .background(palette.background)
        .tint(accent)
        .onAppear { timezone = workspace.settings.timezone }
        .onChange(of: workspace.settings.timezone) { timezone = $0 }
        .onChange(of: area) { if aiAreas.contains($0) { aiExpanded = true } }
    }

    private var settingsSearch: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(palette.muted).accessibilityHidden(true)
            TextField("Поиск по настройкам…", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.muted)
                    .accessibilityLabel("Очистить поиск по настройкам")
            }
        }
        .padding(7)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(searchFocused ? accent : palette.border) }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                row(.general)
                DisclosureGroup(isExpanded: $aiExpanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(aiAreas) { row($0).padding(.leading, 8) }
                    }
                    .padding(.top, 4)
                } label: {
                    Label("Анализ и ИИ", systemImage: "sparkles").font(.callout.weight(.semibold))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                Divider()
                row(.terminology)
                row(.account)
            }
            .padding(8)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .panelCard(inset: 0)
    }

    private func row(_ section: SettingsArea) -> some View {
        Button { select(section) } label: {
            Label(section.title, systemImage: section.icon)
                .font(.callout.weight(section == area ? .semibold : .regular))
                .foregroundStyle(section == area ? accent : palette.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .padding(.horizontal, 9)
                .background(section == area ? accent.opacity(0.14) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(section == area ? .isSelected : [])
    }

    private var banner: some View {
        HStack(spacing: 13) {
            Image(systemName: area.icon)
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(accent.gradient, in: RoundedRectangle(cornerRadius: 13))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(area == .general ? "Основные настройки" : area.title)
                    .font(.title2.bold())
                    .foregroundStyle(palette.text)
                    .accessibilityAddTraits(.isHeader)
                Text(area.detail).font(.callout).foregroundStyle(palette.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(15)
        .background(alignment: .trailing) {
            if let ribbon = Self.ribbon {
                Image(nsImage: ribbon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 380, maxHeight: 90)
                    .opacity(scheme == .dark ? 0.19 : 0.9)
                    .mask(LinearGradient(colors: [.clear, .white, .white], startPoint: .leading, endPoint: .trailing))
                    .accessibilityHidden(true)
            }
        }
        .background(accent.opacity(scheme == .dark ? 0.10 : 0.06), in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .panelCard(inset: 7)
    }

    private var results: some View {
        card("Результаты поиска", icon: "magnifyingglass") {
            if searchResults.isEmpty {
                Text("Настройки по этому запросу не найдены.").foregroundStyle(palette.muted)
            }
            ForEach(searchResults) { item in
                Button { select(item) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(item.title, systemImage: item.icon).font(.headline)
                            Text(item.detail).foregroundStyle(palette.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(accent)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func sectionContent(twoColumns: Bool) -> some View {
        switch area {
        case .general:
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                                     count: twoColumns ? 2 : 1), alignment: .leading, spacing: 12) {
                regionCard
                appearanceCard
                valliCard
                shortcutsCard
                recordingCard
                dataCard
            }
        case .providers, .analysis, .speech:
            EngineSettingsForm(model: model, area: area == .speech ? .speech : area == .analysis ? .analysis : .providers)
                .fixedSize(horizontal: false, vertical: true)
            if area == .speech {
                VoiceMatchingSettingsForm(model: model)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .valli:
            AssistantVoiceSettingsForm(canPreview: model.capture?.active == nil)
                .fixedSize(horizontal: false, vertical: true)
        case .terminology:
            card("Отраслевой словарь", icon: "book", subtitle: "Шаблон терминов для новых проектов и совещаний") {
                LabeledContent("Словарь Валли по умолчанию") {
                    IndustryTemplateMenu(model: model)
                }
                Button("Открыть справочник терминов", action: openGlossary).buttonStyle(.link)
                Divider()
                Button("Открыть справочник этапов работ", action: openWorkPeriodCatalog)
                    .buttonStyle(.link)
            }
        case .account:
            card("Профиль", icon: "person.crop.circle") {
                Picker("Кто я", selection: Binding(get: { workspace.settings.meId }, set: { id in
                    save(["me_id": id.map { $0 as Any } ?? NSNull()])
                })) {
                    Text("Не выбрано").tag(nil as Int?)
                    ForEach(workspace.people) { person in Text(person.speakerPickerName).tag(Optional(person.id)) }
                }
                .disabled(saving)
            }
            recordingCard
        }
    }

    private var regionCard: some View {
        card("Язык, регион и время", icon: "globe", subtitle: "Интерфейс, формат даты и часовой пояс") {
            settingsValue("Язык интерфейса", value: "Русский")
            Divider()
            HStack {
                Text("Часовой пояс")
                Spacer()
                TextField("Часовой пояс", text: $timezone)
                    .labelsHidden()
                    .frame(maxWidth: 180)
                    .onSubmit(saveTimezone)
                if timezone != workspace.settings.timezone {
                    Button("Сохранить", action: saveTimezone)
                        .disabled(saving || timezone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Divider()
            settingsValue("Формат даты", value: Date.now.formatted(.dateTime.day().month(.twoDigits).year()))
            Divider()
            settingsValue("Формат времени", value: Date.now.formatted(date: .omitted, time: .shortened))
        }
    }

    private var appearanceCard: some View {
        card("Оформление", icon: "paintbrush.pointed", subtitle: "Тема интерфейса") {
            HStack(spacing: 7) {
                theme("Светлая", icon: "sun.max", value: "light")
                theme("Тёмная", icon: "moon", value: "dark")
                theme("Как в системе", icon: "desktopcomputer", value: "system")
            }
        }
    }

    private func theme(_ label: String, icon: String, value: String) -> some View {
        let selected = workspace.settings.theme == value
        return Button {
            if !selected { save(["theme": value]) }
        } label: {
            VStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 19, weight: .medium))
                Text(label).font(.caption).multilineTextAlignment(.center)
            }
            .foregroundStyle(selected ? accent : palette.text)
            .frame(maxWidth: .infinity, minHeight: 59)
            .background(accent.opacity(selected ? 0.12 : 0.03), in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? accent : palette.border) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(saving)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var valliCard: some View {
        card("Голосовой помощник Валли", icon: "waveform", subtitle: "Голос и озвучивание ответов") {
            AssistantVoiceSettingsForm(canPreview: model.capture?.active == nil, compact: true)
            Divider()
            Button("Настройки распознавания команд") { select(.valli) }.buttonStyle(.link)
        }
    }

    private var shortcutsCard: some View {
        card("Быстрые действия", icon: "command", subtitle: "Навигация и горячие клавиши") {
            settingsValue("Поиск по настройкам", value: "⌘K")
            Divider()
            settingsValue("Обновить рабочие данные", value: "⌘R")
            Divider()
            Button("Открыть справочник", action: openGlossary).buttonStyle(.link)
        }
    }

    private var recordingCard: some View {
        card("Запись и расшифровка", icon: "waveform.badge.mic", subtitle: "Обработка аудио после совещания") {
            Toggle("Распознавать после остановки записи", isOn: Binding(
                get: { workspace.settings.autoProcess }, set: { save(["auto_process": $0]) }
            ))
            .disabled(saving)
            Divider()
            Button("Параметры микрофона и транскрипции") { select(.speech) }.buttonStyle(.link)
        }
    }

    private var dataCard: some View {
        card("Использование данных", icon: "chart.bar", subtitle: "Расход ИИ и обработка совещаний") {
            Button("Расход токенов и лимиты ИИ") { select(.analysis) }.buttonStyle(.link)
            Divider()
            Button("Открыть очередь обработки", action: openProcessing).buttonStyle(.link)
        }
    }

    private func settingsValue(_ label: String, value: String) -> some View {
        LabeledContent(label) { Text(value).foregroundStyle(palette.muted).monospacedDigit() }
    }

    private func card<Content: View>(_ title: String, icon: String, subtitle: String = "",
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(accent)
                    .frame(width: 35, height: 35)
                    .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(palette.text).accessibilityAddTraits(.isHeader)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(palette.muted)
                    }
                }
            }
            .padding(.bottom, 3)
            content()
        }
        .panelCard(inset: 13)
    }

    private func select(_ target: SettingsArea) {
        area = target
        query = ""
        searchFocused = false
    }

    private func saveTimezone() {
        let value = timezone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != workspace.settings.timezone else { return }
        save(["timezone": value])
    }

    private func save(_ fields: [String: Any]) {
        Task { await model.command(["op": "settings", "data": fields]) }
    }
}
