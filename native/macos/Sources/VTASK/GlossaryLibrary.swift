import SwiftUI

struct GlossaryLibrary: Decodable {
    struct Industry: Decodable, Identifiable {
        let id: String
        let title: String
        let count: Int

        var icon: String {
            switch id {
            case "universal": "square.3.layers.3d"
            case "it": "chevron.left.forwardslash.chevron.right"
            case "construction": "building.2"
            case "events": "calendar"
            case "architecture_design", "creative_studios": "pencil.and.outline"
            case "marketing": "megaphone"
            case "sales", "project_management": "chart.bar"
            case "finance": "creditcard"
            case "legal": "scalemass"
            case "hr": "person.2"
            case "logistics": "truck.box"
            default: "folder"
            }
        }
    }

    let industries: [Industry]
    let terms: [CompanyTerm]
}

struct CompanyGlossaryView: View {
    @ObservedObject var model: WorkspaceModel
    let entries: [CompanyTerm]
    let proposals: [TermProposal]
    let meetings: [Meeting]
    let openMeeting: (Int) -> Void
    let openDictionarySettings: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var library: GlossaryLibrary?
    @State private var loadError: String?
    @State private var retry = 0
    @State private var query = ""
    @State private var source = Source.all
    @State private var kind = Kind.all
    @State private var language = ""
    @State private var descending = false
    @State private var page = 0
    @State private var pageSize = 15
    @State private var selectedID: String?
    @State private var compactInspector = false
    @State private var viewingSources = false
    @State private var editing: CompanyTermDraft?
    @State private var deleting: CompanyTerm?
    @State private var mergeProposal: TermProposal?
    @State private var mergeDraft: CompanyTermDraft?
    @State private var showAllIndustries = false

    private enum Source: Hashable {
        case all, industry(String), company, proposed, reviewed
    }

    private enum Kind: String, CaseIterable, Identifiable {
        case all = "Все типы"
        case term = "Термин"
        case slang = "Сленг"
        case abbreviation = "Аббревиатура"
        var id: Self { self }

        init(_ term: CompanyTerm) {
            switch term.category {
            case "slang": self = .slang
            case "abbreviation": self = .abbreviation
            default: self = .term
            }
        }
    }

    private enum Row: Identifiable {
        case term(CompanyTerm)
        case proposal(TermProposal)

        var id: String {
            switch self {
            case .term(let term): "term:\(term.id)"
            case .proposal(let item): "proposal:\(item.id)"
            }
        }

        var title: String {
            switch self {
            case .term(let term): term.term
            case .proposal(let item): item.text
            }
        }

        var detail: String {
            switch self {
            case .term(let term):
                return term.definition ?? term.variants.map(\.text).joined(separator: ", ")
            case .proposal(let item): return item.sources.first?.quote ?? ""
            }
        }
    }

    private var palette: PanelPalette { PanelPalette(dark: scheme == .dark) }
    private var industries: [GlossaryLibrary.Industry] { library?.industries ?? [] }
    private var pending: Int { proposals.filter { $0.status == .proposed }.count }
    private var reviewed: Int { proposals.count - pending }
    private var terms: [CompanyTerm] { (library?.terms ?? []) + entries }
    private var industryNames: [String: String] {
        Dictionary(uniqueKeysWithValues: industries.map { ($0.id, $0.title) })
    }

    private func industryName(_ term: CompanyTerm) -> String {
        if let id = term.industryId { return industryNames[id] ?? id }
        return "Компания"
    }

    private var languages: [String] {
        Set(terms.map(\.language).filter { !$0.isEmpty }).sorted()
    }

    private var filtered: [Row] {
        let words = CompanyGlossary.words(query)
        let ordered: [Row]
        switch source {
        case .proposed, .reviewed:
            ordered = proposals.filter { item in
                (source == .proposed ? item.status == .proposed : item.status != .proposed)
                    && words.allSatisfy { word in
                        item.text.localizedStandardContains(word) ||
                            item.sources.contains { $0.quote.localizedStandardContains(word) }
                    }
            }.map(Row.proposal)
        default:
            let candidates: [CompanyTerm]
            switch source {
            case .company:
                candidates = entries
            case .industry(let id):
                candidates = library?.terms.filter { $0.industryId == id } ?? []
            default:
                candidates = terms
            }
            ordered = candidates.filter { term in
                guard (kind == .all || Kind(term) == kind), (language.isEmpty || term.language == language) else { return false }
                guard !words.isEmpty else { return true }
                let fields = [term.term, term.definition ?? "", term.section] +
                    term.variants.flatMap { [$0.text, $0.context ?? ""] }
                let normalized = CompanyGlossary.words(fields.joined(separator: " ")).joined(separator: " ")
                return words.allSatisfy { normalized.localizedStandardContains($0) }
            }.map(Row.term)
        }
        return ordered.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : (descending ? order == .orderedDescending : order == .orderedAscending)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 970
            let hasSidebar = geometry.size.width >= 690
            let visible = filtered
            let current = visible.first { $0.id == selectedID }
            VStack(spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack { metrics; toolbar }
                    VStack(alignment: .trailing, spacing: 8) { toolbar; metrics }
                }
                activeDictionary
                if !wide, compactInspector, let current {
                    inspector(current) { compactInspector = false }
                } else {
                    HStack(spacing: 10) {
                        if hasSidebar { sidebar.frame(width: wide ? 196 : 172) }
                        table(visible, hasSidebar: hasSidebar, wide: wide)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if wide, let current { inspector(current) { selectedID = nil }.frame(width: 285) }
                    }
                }
            }
            .padding(12)
        }
        .task(id: "\(model.dictionaryGeneration):\(retry)") {
            do {
                let result = try await model.browseGlossary()
                guard !Task.isCancelled else { return }
                library = result
                loadError = nil
                if selectedID == nil { selectedID = filtered.first?.id }
            } catch {
                if !Task.isCancelled { loadError = error.localizedDescription }
            }
        }
        .onChange(of: query) { _ in page = 0 }
        .onChange(of: kind) { _ in page = 0 }
        .onChange(of: language) { _ in page = 0 }
        .onChange(of: proposals.count) { _ in page = 0 }
        .sheet(item: $editing) { draft in
            CompanyTermEditor(model: model, draft: draft)
                .sheetCloseButton(disabled: model.saving)
        }
        .sheet(item: $mergeProposal, onDismiss: {
            editing = mergeDraft
            mergeDraft = nil
        }) { item in
            let saved = Set(entries.map { CompanyGlossary.words($0.term) })
            let originals = (library?.terms ?? []).filter { !saved.contains(CompanyGlossary.words($0.term)) }
            TermMergePicker(item: item, terms: entries + originals) { target in
                var draft = draftForVariant(target)
                draft.variants.removeAll { $0.text.isEmpty }
                draft.variants.append(.init(text: item.text, language: ""))
                draft.proposal = item
                draft.merging = true
                mergeDraft = draft
                mergeProposal = nil
            }
            .sheetCloseButton(disabled: false)
        }
        .alert("Удалить термин?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
               presenting: deleting) { term in
            Button("Отмена", role: .cancel) {}
            Button("Удалить", role: .destructive) {
                Task { await model.command(["op": "delete_company_term", "id": term.id, "revision": term.revision]) }
            }
        } message: { term in Text(term.term) }
    }

    private var activeDictionary: some View {
        let title = model.workspace?.industryTitle ?? "Мероприятия и декор"
        return Button(action: openDictionarySettings) {
            HStack(spacing: 8) {
                Image(systemName: "book.closed")
                    .foregroundStyle(palette.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Словарь Валли по умолчанию").font(.caption).foregroundStyle(palette.muted)
                    Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(palette.muted)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .panelCard(inset: 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Словарь Валли по умолчанию")
        .accessibilityValue(title)
        .accessibilityHint("Открывает настройки терминологии")
        .help("Открыть настройки терминологии")
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { editing = CompanyTermDraft() } label: {
                Label("Добавить термин", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.saving)
            DictionaryTransferMenu(model: model)
        }
        .fixedSize()
    }

    private var metrics: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                metric(terms.count, "Терминов", "book", .all)
                metric(industries.count, "Словарей", "square.3.layers.3d", nil)
                metric(pending, "На проверке", "sparkles", .proposed)
                metric(entries.count, "У компании", "checkmark.circle", .company)
            }
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    metric(terms.count, "Терминов", "book", .all)
                    metric(industries.count, "Словарей", "square.3.layers.3d", nil)
                }
                HStack(spacing: 6) {
                    metric(pending, "На проверке", "sparkles", .proposed)
                    metric(entries.count, "У компании", "checkmark.circle", .company)
                }
            }
        }
    }

    @ViewBuilder
    private func metric(_ count: Int, _ title: String, _ icon: String, _ target: Source?) -> some View {
        let content = HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.headline).foregroundStyle(target == .company ? Color.green : palette.accent)
                .frame(width: 32, height: 32)
                .background(palette.selected.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(count.formatted()).font(.title3.weight(.bold)).monospacedDigit()
                Text(title).font(.caption).foregroundStyle(palette.muted).lineLimit(1)
            }
        }.fixedSize(horizontal: true, vertical: false)
        if let target {
            Button { changeSource(target) } label: { content.panelCard(inset: 9) }.buttonStyle(.plain)
        } else {
            content.panelCard(inset: 9)
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(spacing: 3) {
                directoryRow("Все отрасли", "tray.2", terms.count, .all)
                directoryRow("Компания", "building", entries.count, .company)
                directoryRow("Предложенные", "sparkles", pending, .proposed)
                if reviewed > 0 { directoryRow("Обработанные", "clock", reviewed, .reviewed) }
                Divider().padding(.vertical, 5)
                ForEach(showAllIndustries ? industries : Array(industries.prefix(14))) { entry in
                    directoryRow(entry.title, entry.icon, entry.count, .industry(entry.id))
                }
                if industries.count > 14 {
                    Button(showAllIndustries ? "Свернуть" : "Показать ещё \(industries.count - 14)") {
                        showAllIndustries.toggle()
                    }.buttonStyle(.link).font(.caption).padding(.vertical, 7)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .panelCard(inset: 7)
    }

    private func directoryRow(_ title: String, _ icon: String, _ count: Int, _ value: Source) -> some View {
        Button { changeSource(value) } label: {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.caption.weight(.semibold)).frame(width: 16)
                    .foregroundStyle(palette.accent).accessibilityHidden(true)
                Text(title).font(.caption.weight(source == value ? .semibold : .medium)).lineLimit(1)
                Spacer(minLength: 2)
                Text(count.formatted()).font(.caption2.monospacedDigit()).padding(.horizontal, 4).padding(.vertical, 2)
                    .background(palette.background, in: Capsule())
            }
            .padding(.horizontal, 7).frame(height: 30)
            .contentShape(Rectangle())
            .background(source == value ? palette.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityAddTraits(source == value ? .isSelected : [])
    }

    private func changeSource(_ value: Source) {
        source = value
        compactInspector = false
        page = 0
        selectedID = nil
        viewingSources = false
    }

    private var sourceTitle: String {
        switch source {
        case .all: "Все отрасли"
        case .company: "Компания"
        case .proposed: "Предложенные"
        case .reviewed: "Обработанные"
        case .industry(let id): industryNames[id] ?? id
        }
    }

    private func table(_ rows: [Row], hasSidebar: Bool, wide: Bool) -> some View {
        let last = max(0, (rows.count - 1) / pageSize)
        let actualPage = min(page, last)
        let first = actualPage * pageSize
        let end = min(first + pageSize, rows.count)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                if !hasSidebar {
                    Menu {
                        Button("Все отрасли") { changeSource(.all) }
                        Button("Компания") { changeSource(.company) }
                        Button("Предложенные") { changeSource(.proposed) }
                        Button("Обработанные") { changeSource(.reviewed) }
                        Divider()
                        ForEach(industries) { entry in Button(entry.title) { changeSource(.industry(entry.id)) } }
                    } label: { Image(systemName: "square.3.layers.3d") }
                        .fixedSize().accessibilityLabel("Отрасли, \(sourceTitle)")
                }
                PanelSearchField(placeholder: "Поиск по терминам, значениям и синонимам", query: $query)
                Menu {
                    Picker("Тип", selection: $kind) { ForEach(Kind.allCases) { Text($0.rawValue).tag($0) } }
                        .disabled(source == .proposed || source == .reviewed)
                    Picker("Язык", selection: $language) {
                        Text("Все языки").tag("")
                        ForEach(languages, id: \.self) { Text($0).tag($0) }
                    }.disabled(source == .proposed || source == .reviewed)
                    Divider()
                    Button("Предложенные") { changeSource(.proposed) }
                    Button("Обработанные") { changeSource(.reviewed) }
                    Button("Сбросить фильтры") { kind = .all; language = ""; changeSource(.all) }
                } label: {
                    Label("Фильтры", systemImage: "line.3.horizontal.decrease")
                }.fixedSize()
            }
            HStack(spacing: 5) {
                chip(sourceTitle)
                if kind != .all && source != .proposed && source != .reviewed { chip(kind.rawValue) }
                if !language.isEmpty && source != .proposed && source != .reviewed { chip(language) }
            }
            tableColumns(wide: wide) {
                Button { descending.toggle(); page = 0 } label: {
                    Label("Термин", systemImage: descending ? "arrow.down" : "arrow.up")
                        .labelStyle(.titleAndIcon)
                }.buttonStyle(.plain)
            } detail: {
                Text("Значение")
            } industry: {
                Text("Отрасль")
            } kind: {
                Text("Тип")
            }
            .font(.caption.weight(.semibold)).foregroundStyle(palette.muted)
            .padding(.horizontal, 8).frame(height: 28)
            .background(palette.background, in: RoundedRectangle(cornerRadius: 6))

            if rows.isEmpty {
                VStack(spacing: 7) {
                    if let loadError, library == nil {
                        Text(loadError).font(.callout).foregroundStyle(.secondary)
                        Button("Повторить") { retry += 1 }
                    } else if library == nil && source == .all {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(source == .proposed ? "Нет терминов на проверке" : "Термины не найдены",
                              systemImage: "magnifyingglass").foregroundStyle(palette.muted)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows[first..<end]) { row in tableRow(row, wide: wide) }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 7) {
                Text(rows.isEmpty ? "0 записей" : "\(first + 1)–\(end) из \(rows.count.formatted())")
                    .font(.caption).foregroundStyle(palette.muted).lineLimit(1)
                Spacer(minLength: 2)
                Button { page = actualPage - 1 } label: { Image(systemName: "chevron.left") }
                    .disabled(actualPage == 0).accessibilityLabel("Предыдущая страница")
                Text("\(actualPage + 1) / \(last + 1)").font(.caption.monospacedDigit()).lineLimit(1)
                Button { page = actualPage + 1 } label: { Image(systemName: "chevron.right") }
                    .disabled(actualPage == last).accessibilityLabel("Следующая страница")
                Picker("На странице", selection: $pageSize) {
                    ForEach([10, 15, 25, 50], id: \.self) { Text(String($0)).tag($0) }
                }.labelsHidden().fixedSize()
                    .onChange(of: pageSize) { _ in page = 0 }
            }.controlSize(.small)
        }
        .panelCard(inset: 10)
    }

    private func tableColumns<Title: View, Detail: View, Industry: View, Category: View>(
        wide: Bool, @ViewBuilder title: () -> Title, @ViewBuilder detail: () -> Detail,
        @ViewBuilder industry: () -> Industry, @ViewBuilder kind: () -> Category
    ) -> some View {
        HStack(spacing: 8) {
            title().frame(width: wide ? 108 : 98, alignment: .leading)
            detail().frame(maxWidth: .infinity, alignment: .leading)
            if wide {
                industry().frame(width: 89, alignment: .leading)
                kind().frame(width: 73, alignment: .leading)
            }
        }
    }

    private func tableRow(_ row: Row, wide: Bool) -> some View {
        VStack(spacing: 0) {
            Button {
                selectedID = row.id
                viewingSources = false
                if !wide { compactInspector = true }
            } label: {
                tableColumns(wide: wide) {
                    Text(row.title).fontWeight(.semibold).lineLimit(2)
                } detail: {
                    Text(row.detail.isEmpty ? "—" : row.detail).lineLimit(2)
                } industry: {
                    if case .term(let term) = row { chip(industryName(term)) }
                } kind: {
                    switch row {
                    case .term(let term): chip(Kind(term).rawValue, tinted: true)
                    case .proposal(let item): chip(item.status.title, tinted: true)
                    }
                }
                .font(.callout).padding(.horizontal, 8).padding(.vertical, 5)
                .frame(minHeight: 37)
                .contentShape(Rectangle())
                .background(selectedID == row.id ? palette.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain)
                .accessibilityLabel(row.title)
                .accessibilityValue(row.detail)
                .accessibilityAddTraits(selectedID == row.id ? .isSelected : [])
            Divider()
        }
    }

    private func chip(_ title: String, tinted: Bool = false) -> some View {
        Text(title).font(.caption2.weight(.medium)).lineLimit(1)
            .foregroundStyle(tinted ? palette.accent : palette.text)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(tinted ? palette.selected.opacity(0.75) : palette.sidebar, in: RoundedRectangle(cornerRadius: 5))
            .help(title)
    }

    private func inspector(_ row: Row, close: @escaping () -> Void) -> some View {
        let citations = citations(for: row)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(row.title).font(.title3.weight(.bold)).textSelection(.enabled)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Закрыть карточку термина")
            }
            if !citations.isEmpty {
                Picker("Раздел карточки", selection: $viewingSources) {
                    Text("Основное").tag(false)
                    Text("Источники").tag(true)
                }.pickerStyle(.segmented).labelsHidden()
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    if !viewingSources {
                        switch row {
                        case .term(let term): termDetails(term)
                        case .proposal(let item): proposalDetails(item)
                        }
                    }
                    if !citations.isEmpty && (viewingSources || row.detail.isEmpty) { citationList(citations) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
        }
        .panelCard(inset: 14)
    }

    @ViewBuilder
    private func termDetails(_ term: CompanyTerm) -> some View {
        detailSection("Значение") {
            Text(term.definition ?? "Определение пока не задано").textSelection(.enabled)
        }
        detailSection("Отрасль и тип") {
            HStack(spacing: 4) { chip(industryName(term)); chip(Kind(term).rawValue, tinted: true) }
        }
        if !term.variants.isEmpty {
            detailSection("Варианты и синонимы") {
                ForEach(term.variants.indices, id: \.self) { index in
                    let variant = term.variants[index]
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        chip(variant.text)
                        if let context = variant.context { Text(context).font(.caption).foregroundStyle(palette.muted) }
                    }
                }
            }
        }
        Divider()
        detailSection("Источник") { Text(term.id < 0 ? "Отраслевой словарь" : "Словарь компании") }
        if term.id > 0 {
            HStack {
                Button("Редактировать") { editing = CompanyTermDraft(existing: term) }
                Menu {
                    Button("Удалить термин…", role: .destructive) {
                        compactInspector = false
                        deleting = term
                    }
                } label: { Image(systemName: "ellipsis.circle") }.fixedSize().accessibilityLabel("Действия термина")
            }.disabled(model.saving)
        } else {
            Button("Добавить вариант…") { editing = draftForVariant(term) }.disabled(model.saving)
        }
    }

    @ViewBuilder
    private func proposalDetails(_ item: TermProposal) -> some View {
        chip(item.status.title, tinted: true)
        if let quote = item.sources.first?.quote {
            detailSection("Контекст") { Text(quote).textSelection(.enabled) }
        }
        if item.status == .proposed {
            VStack(alignment: .leading, spacing: 7) {
                Button("Подтвердить…") {
                    var draft = CompanyTermDraft(term: item.text)
                    draft.proposal = item
                    editing = draft
                }.buttonStyle(.borderedProminent)
                Button("Добавить как вариант…") { mergeProposal = item }
                Button("Отклонить") {
                    Task {
                        if await model.command(["op": "review_term_proposal", "proposal_id": item.id, "status": "rejected"]) {
                            compactInspector = false
                        }
                    }
                }.foregroundStyle(Color.red)
            }.disabled(model.saving)
        }
    }

    private func citations(for row: Row) -> [TermProposal.Source] {
        switch row {
        case .proposal(let item): return item.sources
        case .term(let term):
            var seen = Set<Int>()
            return proposals.filter { $0.termId == term.id }.flatMap(\.sources)
                .filter { seen.insert($0.meetingId).inserted }
        }
    }

    private func citationList(_ items: [TermProposal.Source]) -> some View {
        detailSection("Реплики из совещаний") {
            ForEach(items) { source in
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.quote).textSelection(.enabled)
                    Button(meetings.first { $0.id == source.meetingId }?.visibleTitle ?? "Совещание") {
                        compactInspector = false
                        openMeeting(source.meetingId)
                    }.buttonStyle(.link)
                }.panelCard(inset: 8)
            }
        }
    }

    private func detailSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout.weight(.semibold))
            content().font(.callout)
        }
    }

    private func draftForVariant(_ term: CompanyTerm) -> CompanyTermDraft {
        let saved = term.id > 0 ? term : entries.first {
            CompanyGlossary.words($0.term) == CompanyGlossary.words(term.term)
        }
        var draft = CompanyTermDraft(existing: saved, term: term.term)
        if saved == nil {
            draft.language = term.language
            draft.section = term.section
            draft.definition = term.definition ?? ""
        } else if draft.variants.count < 30 {
            draft.variants.append(.init(text: "", language: ""))
        }
        return draft
    }
}
