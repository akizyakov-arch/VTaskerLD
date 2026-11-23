import SwiftUI

struct CompanyTerm: Decodable, Identifiable, Equatable {
    struct Variant: Decodable, Equatable {
        var text: String
        var language: String
        var context: String? = nil
    }

    let id: Int
    let revision: Int
    let term: String
    let language: String
    let section: String
    let definition: String?
    let lookupOnly: Bool?
    let industryId: String?
    let category: String?
    let variants: [Variant]
}

struct CompanyGlossary {
    private struct Spelling {
        let words: [String]
        let context: [String]
        let entry: CompanyTerm
    }

    private let spellings: [String: [Spelling]]

    init(_ entries: [CompanyTerm] = []) {
        let all = entries.flatMap { entry in
            [Spelling(words: Self.words(entry.term), context: [], entry: entry)] +
                entry.variants.map { Spelling(words: Self.words($0.text), context: Self.words($0.context ?? ""), entry: entry) }
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
        guard let first = words.first else { return false }
        return spellings[first]?.contains { $0.words == words } ?? false
    }

    func expand(_ words: [String]) -> [String] {
        guard !spellings.isEmpty else { return words }
        var result = [String]()
        var offset = 0
        while offset < words.count {
            if let spelling = match(in: words, at: offset) {
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
            if let spelling = match(in: words, at: offset) {
                if !spelling.entry.section.isEmpty { sections.insert(spelling.entry.section) }
                offset += spelling.words.count
            } else {
                offset += 1
            }
        }
        return sections.count == 1 ? sections.first : nil
    }

    private func match(in tokens: [String], at offset: Int) -> Spelling? {
        let matches = (spellings[tokens[offset]] ?? []).filter {
            $0.entry.lookupOnly != true && tokens[offset...].starts(with: $0.words)
        }
        guard let length = matches.first?.words.count else { return nil }
        let end = offset + length
        let nearby = [tokens[max(0, offset - 5)..<offset], tokens[end..<min(tokens.count, end + 5)]]
        let longest = matches.prefix { $0.words.count == length }
        let contextual = longest.filter { item in
            !item.context.isEmpty && nearby.contains { words in
                words.indices.contains { words[$0...].starts(with: item.context) }
            }
        }
        let choices = contextual.isEmpty ? longest.filter { $0.context.isEmpty } : contextual
        guard let first = choices.first, choices.allSatisfy({ $0.entry.id == first.entry.id }) else { return nil }
        return first
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

struct TermProposal: Decodable, Identifiable {
    struct Source: Decodable, Identifiable {
        let meetingId: Int
        let quote: String

        var id: Int { meetingId }
    }

    enum Status: String, Decodable {
        case proposed, approved, merged, rejected

        var title: String {
            switch self {
            case .proposed: "На проверке"
            case .approved: "Подтверждён"
            case .merged: "Добавлен как вариант"
            case .rejected: "Отклонён"
            }
        }
    }

    let id: String
    let text: String
    let status: Status
    let sources: [Source]
    let termId: Int?
}

struct CompanyTermDraft: Identifiable {
    let id = UUID()
    var existing: CompanyTerm?
    var proposal: TermProposal?
    var merging = false
    var term = ""
    var language = ""
    var section = ""
    var definition = ""
    var variants = [CompanyTerm.Variant(text: "", language: "")]

    init(existing: CompanyTerm? = nil, term: String = "", variants: [CompanyTerm.Variant] = []) {
        self.existing = existing
        self.term = existing?.term ?? term
        language = existing?.language ?? ""
        section = existing?.section ?? ""
        definition = existing?.definition ?? ""
        if let existing { self.variants = existing.variants }
        else if !variants.isEmpty { self.variants = variants }
    }

    var valid: Bool {
        !CompanyGlossary.words(term).isEmpty
    }

    func save(using model: WorkspaceModel) async -> Bool {
        var request: [String: Any] = [
            "op": "save_company_term",
            "data": [
                "term": term,
                "language": language,
                "section": section,
                "definition": definition,
                "variants": variants.filter { !CompanyGlossary.words($0.text).isEmpty }
                    .map { ["text": $0.text, "language": $0.language, "context": $0.context ?? ""] }
            ]
        ]
        if let proposal {
            request["op"] = "review_term_proposal"
            request["proposal_id"] = proposal.id
            request["status"] = merging ? "merged" : "approved"
        }
        if let existing {
            request["id"] = existing.id
            request["revision"] = existing.revision
        }
        return await model.command(request)
    }
}

struct TermMergePicker: View {
    let item: TermProposal
    let terms: [CompanyTerm]
    let select: (CompanyTerm) -> Void
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Добавить «\(item.text)» как вариант").font(.headline)
            PanelSearchField(placeholder: "Найти основной термин", query: $query)
            List {
                ForEach(terms.filter { query.isEmpty || $0.term.localizedStandardContains(query) }
                    .sorted { $0.term.localizedStandardCompare($1.term) == .orderedAscending }) { term in
                    Button {
                        select(term)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(term.term)
                            if let definition = term.definition, !definition.isEmpty {
                                Text(definition).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.buttonStyle(.plain)
                        .disabled(term.id > 0 && term.variants.count >= 30)
                }
            }
        }
        .padding(20)
        .frame(width: 480, height: 360)
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
                    TextField("Определение", text: $draft.definition, prompt: Text("Необязательно"), axis: .vertical)
                        .lineLimit(1...3)
                    TextField("Язык", text: $draft.language, prompt: Text("Например, ru или en"))
                    TextField("Раздел", text: $draft.section, prompt: Text("Необязательно"))
                }
                Section("Как ещё говорят") {
                    ForEach(draft.variants.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 6) {
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
                            TextField("Фраза рядом (необязательно)", text: Binding(
                                get: { draft.variants[index].context ?? "" },
                                set: { draft.variants[index].context = $0 }
                            ), prompt: Text("Например, плиту"))
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
