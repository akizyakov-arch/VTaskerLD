import SwiftUI

struct CompanyTerm: Decodable, Identifiable, Equatable {
    struct Variant: Decodable, Equatable {
        var text: String
        var language: String
    }

    let id: Int
    let revision: Int
    let term: String
    let language: String
    let section: String
    let variants: [Variant]
}

struct CompanyGlossary {
    private struct Spelling {
        let words: [String]
        let entry: CompanyTerm
    }

    private let spellings: [String: [Spelling]]

    init(_ entries: [CompanyTerm] = []) {
        let all = entries.flatMap { entry in
            ([entry.term] + entry.variants.map(\.text)).map { Spelling(words: Self.words($0), entry: entry) }
        }.filter { !$0.words.isEmpty }
        spellings = Dictionary(grouping: all, by: { $0.words[0] }).mapValues {
            $0.sorted { $0.words.count > $1.words.count }
        }
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    func contains(_ spelling: String) -> Bool {
        let words = Self.words(spelling)
        guard !words.isEmpty, let match = match(at: words[...]) else { return false }
        return match.words.count == words.count
    }

    func expand(_ words: [String]) -> [String] {
        guard !spellings.isEmpty else { return words }
        var result = [String]()
        var offset = 0
        while offset < words.count {
            if let spelling = match(at: words[offset...]) {
                result += Self.words(spelling.entry.term)
                offset += spelling.words.count
            } else {
                result.append(words[offset])
                offset += 1
            }
        }
        return result
    }

    func section(for text: String) -> String? {
        guard !spellings.isEmpty else { return nil }
        let words = Self.words(text)
        var sections = Set<String>()
        var offset = 0
        while offset < words.count {
            if let spelling = match(at: words[offset...]) {
                if !spelling.entry.section.isEmpty { sections.insert(spelling.entry.section) }
                offset += spelling.words.count
            } else {
                offset += 1
            }
        }
        return sections.count == 1 ? sections.first : nil
    }

    private func match(at words: ArraySlice<String>) -> Spelling? {
        guard let first = words.first else { return nil }
        return spellings[first]?.first { words.starts(with: $0.words) }
    }
}

private struct CompanyGlossaryKey: EnvironmentKey {
    static let defaultValue = CompanyGlossary()
}

extension EnvironmentValues {
    var companyGlossary: CompanyGlossary {
        get { self[CompanyGlossaryKey.self] }
        set { self[CompanyGlossaryKey.self] = newValue }
    }
}

struct CompanyTermDraft: Identifiable {
    let id = UUID()
    var existing: CompanyTerm?
    var term = ""
    var language = ""
    var section = ""
    var variants = [CompanyTerm.Variant(text: "", language: "")]

    init(existing: CompanyTerm? = nil, term: String = "", variants: [CompanyTerm.Variant] = []) {
        self.existing = existing
        self.term = existing?.term ?? term
        language = existing?.language ?? ""
        section = existing?.section ?? ""
        if let existing { self.variants = existing.variants }
        else if !variants.isEmpty { self.variants = variants }
    }

    var valid: Bool {
        !CompanyGlossary.words(term).isEmpty && variants.contains { !CompanyGlossary.words($0.text).isEmpty }
    }

    func save(using model: WorkspaceModel) async -> Bool {
        var request: [String: Any] = [
            "op": "save_company_term",
            "data": [
                "term": term,
                "language": language,
                "section": section,
                "variants": variants.filter { !CompanyGlossary.words($0.text).isEmpty }
                    .map { ["text": $0.text, "language": $0.language] }
            ]
        ]
        if let existing {
            request["id"] = existing.id
            request["revision"] = existing.revision
        }
        return await model.command(request)
    }
}

struct CompanyGlossaryView: View {
    @ObservedObject var model: WorkspaceModel
    let entries: [CompanyTerm]
    let industry: IndustryTemplate
    let starterTerms: [CompanyTerm]
    let meetings: [Meeting]
    let openMeeting: (Int) -> Void
    @Environment(\.companyGlossary) private var glossary
    @State private var query = ""
    @State private var source = Source.all
    @State private var editing: CompanyTermDraft?
    @State private var deleting: CompanyTerm?
    @State private var showingSuggestions = false

    private enum Source: String, CaseIterable, Identifiable {
        case all = "Все"
        case industry = "Отрасль"
        case company = "Компания"

        var id: Self { self }
    }

    private struct Suggestion: Identifiable {
        let id: String
        let text: String
        let meeting: Meeting
        let quote: String?
    }

    private var suggestions: [Suggestion] {
        var seen = Set<String>()
        return meetings.sorted { $0.id > $1.id }.flatMap { meeting in
            (meeting.analysis?.saved?.result?.findings ?? []).compactMap { finding in
                let normalized = CompanyGlossary.words(finding.text).joined(separator: " ")
                guard finding.kind == "unclear_term", !normalized.isEmpty, !glossary.contains(finding.text),
                      seen.insert(normalized).inserted else { return nil }
                return Suggestion(id: normalized, text: finding.text, meeting: meeting, quote: finding.source?.quote)
            }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack { searchField; controls }
                    VStack(alignment: .leading, spacing: 8) { searchField; controls }
                }
                Picker("Источник терминов", selection: $source) {
                    ForEach(Source.allCases) { item in Text(item.rawValue).tag(item) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                if showingSuggestions { suggestionList }

                let industryResults = matches(in: starterTerms)
                let companyResults = matches(in: entries)
                if source != .company && !industryResults.isEmpty {
                    Text("Словарь отрасли · \(industry.title)").font(.headline).accessibilityAddTraits(.isHeader)
                    ForEach(industryResults, content: starterRow)
                }
                if source != .industry && !companyResults.isEmpty {
                    Text("Термины компании").font(.headline).accessibilityAddTraits(.isHeader)
                    ForEach(companyResults, content: termRow)
                }
                if (source == .company || industryResults.isEmpty) && (source == .industry || companyResults.isEmpty) {
                    Label(query.isEmpty && source == .company ? "У компании пока нет своих терминов" : "Термины не найдены",
                          systemImage: query.isEmpty ? "book.closed" : "magnifyingglass")
                        .foregroundStyle(.secondary).panelCard()
                }
            }
            .padding(24)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $editing) { draft in
            CompanyTermEditor(model: model, draft: draft)
                .sheetCloseButton(disabled: model.saving)
        }
        .alert("Удалить термин?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
               presenting: deleting) { term in
            Button("Отмена", role: .cancel) {}
            Button("Удалить", role: .destructive) {
                Task { await model.command(["op": "delete_company_term", "id": term.id, "revision": term.revision]) }
            }
        } message: { term in Text(term.term) }
    }

    private var searchField: some View {
        PanelSearchField(placeholder: "Поиск по терминам и вариантам", query: $query)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                showingSuggestions.toggle()
            } label: {
                Label("Анализ протоколов", systemImage: "text.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .accessibilityValue(showingSuggestions ? "Развёрнуто" : "Свёрнуто")
            Button {
                editing = CompanyTermDraft()
            } label: {
                Label("Добавить термин", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.saving)
        }
        .fixedSize()
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Термины для уточнения").font(.headline).accessibilityAddTraits(.isHeader)
            if suggestions.isEmpty {
                Text("В сохранённых разборах пока нет терминов для уточнения.")
                    .foregroundStyle(.secondary)
            }
            ForEach(suggestions) { item in
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.text).font(.callout.weight(.semibold))
                        if let quote = item.quote, !quote.isEmpty {
                            Text(quote).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                        Button(item.meeting.visibleTitle) { openMeeting(item.meeting.id) }.buttonStyle(.link)
                    }
                    Spacer(minLength: 8)
                    Button("Добавить") {
                        editing = CompanyTermDraft(variants: [.init(text: item.text, language: "")])
                    }
                    .accessibilityLabel("Добавить термин «" + item.text + "»")
                }
            }
        }
        .panelCard()
    }

    private func matches(in terms: [CompanyTerm]) -> [CompanyTerm] {
        let words = CompanyGlossary.words(query)
        return terms.filter { term in
            let searchable = ([term.term, term.section, term.language] +
                              term.variants.flatMap { [$0.text, $0.language] }).joined(separator: " ")
            return words.allSatisfy { searchable.localizedStandardContains($0) }
        }.sorted { $0.term.localizedStandardCompare($1.term) == .orderedAscending }
    }

    private func starterRow(_ starter: CompanyTerm) -> some View {
        HStack(spacing: 10) {
            termText(starter)
            if !starter.section.isEmpty {
                Text(starter.section).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Button {
                let termWords = CompanyGlossary.words(starter.term)
                let existing = entries.first { CompanyGlossary.words($0.term) == termWords }
                var draft = CompanyTermDraft(existing: existing, term: starter.term)
                if existing == nil {
                    draft.language = starter.language
                    draft.section = starter.section
                } else if draft.variants.count < 30 {
                    draft.variants.append(.init(text: "", language: ""))
                }
                editing = draft
            } label: {
                Label("Добавить вариант", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .disabled(model.saving)
        }
        .panelCard()
    }

    private func termText(_ term: CompanyTerm) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(term.term).font(.headline)
            Text(term.variants.map(\.text).joined(separator: " · "))
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func termRow(_ term: CompanyTerm) -> some View {
        HStack(spacing: 10) {
            Button {
                editing = CompanyTermDraft(existing: term)
            } label: {
                termText(term)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !term.language.isEmpty {
                Text(term.language).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if !term.section.isEmpty {
                Text(term.section).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Menu {
                Button("Редактировать") { editing = CompanyTermDraft(existing: term) }
                Button("Удалить", role: .destructive) { deleting = term }
            } label: {
                Image(systemName: "ellipsis.circle").accessibilityLabel("Действия термина")
            }
            .fixedSize()
            .disabled(model.saving)
        }
        .panelCard()
    }
}

struct CompanyTermEditor: View {
    @ObservedObject var model: WorkspaceModel
    @State var draft: CompanyTermDraft
    var onSave: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(draft.existing == nil ? "Новый термин" : "Термин справочника", systemImage: "book")
                .font(.title3.bold()).padding(16).accessibilityAddTraits(.isHeader)
            Divider()
            Form {
                Section("Значение") {
                    TextField("Основной термин", text: $draft.term, prompt: Text("Сотовый поликарбонат"))
                    TextField("Язык", text: $draft.language, prompt: Text("Например, ru или en"))
                    TextField("Раздел", text: $draft.section, prompt: Text("Необязательно"))
                }
                Section("Как ещё говорят") {
                    ForEach(draft.variants.indices, id: \.self) { index in
                        HStack {
                            TextField("Вариант", text: $draft.variants[index].text)
                            TextField("Язык", text: $draft.variants[index].language).frame(width: 80)
                            Button {
                                draft.variants.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle").accessibilityLabel("Убрать вариант")
                            }
                            .buttonStyle(.borderless)
                            .disabled(draft.variants.count == 1)
                        }
                    }
                    Button("Добавить вариант") {
                        draft.variants.append(.init(text: "", language: ""))
                    }
                    .disabled(draft.variants.count >= 30)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("Отмена", role: .cancel) { dismiss() }
                    Button("Сохранить") {
                        Task {
                            if await draft.save(using: model) {
                                onSave?()
                                dismiss()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.valid)
                }
            }
            .padding(16)
        }
        .frame(width: 520, height: 460)
        .disabled(model.saving)
        .interactiveDismissDisabled(model.saving)
    }
}

enum CompanyTermRequest {
    private static let wake = #"^валли[\s,:!—-]+"#
    private static let remember = #"^запомни(?:те)?\b[\s,:—-]*(?:термин\s+)?"#
    private static let explain = #"^(?:в\s+эт(?:ой|ом)\s+(?:задаче|решении)\s+)?под\s+(.+?)\s+(?:(?:я|мы)\s+)?имел[аи]?\s+в\s*виду\s+(.+)$"#

    static func isRequest(_ text: String) -> Bool {
        let phrase = text.replacingOccurrences(of: wake, with: "", options: [.regularExpression, .caseInsensitive])
        return phrase.range(of: remember, options: [.regularExpression, .caseInsensitive]) != nil
            || captures(explain, in: phrase) != nil
    }

    static func draft(from text: String) -> CompanyTermDraft? {
        let phrase = text.replacingOccurrences(of: wake, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: remember, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"[\s,.:]+запомни(?:те)?[.!?]*$"#, with: "",
                                  options: [.regularExpression, .caseInsensitive])
        let explanation = captures(explain, in: phrase)
        let pair = explanation ?? captures(#"^(.+?)\s*(?:[=—–]|\s-\s)\s*(?:это\s+)?(.+)$"#, in: phrase)
            ?? captures(#"^(.+?)\s+это\s+(.+)$"#, in: phrase)
        guard let (spoken, term) = pair, !CompanyGlossary.words(spoken).isEmpty,
              !CompanyGlossary.words(term).isEmpty else { return nil }
        let singleWord = CompanyGlossary.words(spoken).count == 1
        let alias = explanation != nil && singleWord && spoken.lowercased().hasSuffix("иком")
            ? String(spoken.dropLast(2)) : spoken
        let variants = singleWord && alias.lowercased().hasSuffix("ик")
            ? [alias, alias + "а", alias + "у", alias + "ом", alias + "е"] : [alias]
        return CompanyTermDraft(term: term, variants: variants.map { .init(text: $0, language: "") })
    }

    private static func captures(_ pattern: String, in text: String) -> (String, String)? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let first = Range(match.range(at: 1), in: text),
              let second = Range(match.range(at: 2), in: text) else { return nil }
        let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "«»“”\".?!,;:"))
        return (text[first].trimmingCharacters(in: trim), text[second].trimmingCharacters(in: trim))
    }
}
