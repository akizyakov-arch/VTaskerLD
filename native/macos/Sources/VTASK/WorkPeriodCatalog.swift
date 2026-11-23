import SwiftUI

struct WorkPeriodTemplate: Decodable, Identifiable {
    let id: String
    let title: String
    let industryId: String
    let builtIn: Bool
    let phase: String?
}

struct WorkPeriodCatalogView: View {
    @ObservedObject var model: WorkspaceModel
    let addToProject: ((String) -> Void)?
    let embedded: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var industry: String
    @State private var query = ""
    @State private var editor: Editor
    @State private var editing: Bool
    @State private var editingList: WorkPeriodListEditor.Scope?
    @State private var renamingScope: WorkPeriodListEditor.Scope?
    @State private var removal: Removal?
    @State private var hoveredID: String?
    @State private var dropTarget: String?
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var actionError: String?
    @FocusState private var titleFocused: Bool
    @FocusState private var searchFocused: Bool

    private struct Editor {
        var id: String? = nil
        var title: String
        var industry: String
    }

    private struct CatalogOption: Identifiable {
        let industry: String
        let projectType: String?
        let title: String
        var id: String { projectType.map { industry + "/" + $0 } ?? industry }
    }

    private struct Removal {
        let item: WorkPeriodTemplate
        let scope: WorkPeriodListEditor.Scope
    }

    private struct RowFrames: PreferenceKey {
        static let defaultValue: [String: CGRect] = [:]
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { _, newer in newer })
        }
    }

    init(model: WorkspaceModel, industry: String = "", titleToSave: String? = nil,
         addToProject: ((String) -> Void)? = nil, embedded: Bool = false) {
        self.model = model
        self.addToProject = addToProject
        self.embedded = embedded
        _industry = State(initialValue: industry)
        _editor = State(initialValue: Editor(title: titleToSave ?? "", industry: industry.isEmpty ? "universal" : industry))
        _editing = State(initialValue: titleToSave != nil)
    }

    private var industries: [IndustryOption] { model.workspace?.industryOptions ?? IndustryOption.legacy }
    private var palette: PanelPalette { PanelPalette(dark: scheme == .dark) }
    private var busy: Bool { model.loading || model.saving }
    private var lists: [String: [WorkPeriodTemplate]]? { model.workspace?.eventWorkPeriodLists }
    private var options: [CatalogOption] {
        let raw = model.workspace?.workPeriodCatalog ?? []
        return industries.flatMap { item -> [CatalogOption] in
            let general = CatalogOption(industry: item.id, projectType: nil, title: item.title)
            guard item.id == "events", lists != nil else { return [general] }
            var separate = [
                CatalogOption(industry: item.id, projectType: "decor", title: "Декор"),
                CatalogOption(industry: item.id, projectType: "organization", title: "События")
            ]
            if raw.contains(where: { $0.industryId == item.id && !$0.id.hasPrefix("builtin:") }) {
                separate.append(CatalogOption(industry: item.id, projectType: nil, title: "Сохранённые этапы мероприятий"))
            }
            return separate
        }
    }

    private func entries(in option: CatalogOption) -> [WorkPeriodTemplate] {
        if let type = option.projectType { return lists?[type] ?? [] }
        return (model.workspace?.workPeriodCatalog ?? []).filter {
            $0.industryId == option.industry &&
                (option.industry != "events" || lists == nil || !$0.id.hasPrefix("builtin:"))
        }
    }

    private func matching(_ option: CatalogOption) -> [WorkPeriodTemplate] {
        let terms = query.split(whereSeparator: \.isWhitespace)
        return entries(in: option).filter { item in
            let searchable = [item.title, option.title, item.phase].compactMap { $0 }.joined(separator: " ")
            return terms.allSatisfy { searchable.localizedStandardContains(String($0)) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !embedded {
                HStack {
                    Label("Справочник этапов работ", systemImage: "calendar.badge.plus")
                        .font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Spacer()
                    WindowCloseButton(label: "Закрыть справочник") { dismiss() }
                        .disabled(busy)
                }
                .padding(16)
                Divider()
            }
            toolbar
                .padding(.horizontal, embedded ? 24 : 14)
                .padding(.vertical, 14)
            if let actionError {
                Label(actionError, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red).padding(.horizontal, 24)
            }
            if editing {
                editForm
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
            let sections = options.filter { industry.isEmpty || $0.id == industry }.map { ($0, matching($0)) }
            if model.workspace?.workPeriodCatalog == nil {
                Text("Справочник станет доступен после запуска обновлённого ядра VTASK.")
                    .foregroundStyle(.secondary).padding(.horizontal, 14)
            } else if sections.allSatisfy({ $0.1.isEmpty }) {
                Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "В этой отрасли пока нет этапов. Можно создать свой."
                     : "По этому запросу этапы не найдены.")
                    .foregroundStyle(.secondary).padding(.horizontal, 14)
            }
            catalogList(sections)
        }
        .frame(width: embedded ? nil : 555, height: embedded ? nil : 465)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if !industry.isEmpty && !options.contains(where: { $0.id == industry }) {
                industry = ""
            }
            if !options.contains(where: { $0.id == editor.industry }) {
                editor.industry = editor.industry == "events" && lists != nil ? "events/decor" : "universal"
            }
        }
        .onChange(of: options.map(\.id)) { ids in
            if !industry.isEmpty && !ids.contains(industry) { industry = "" }
        }
        .interactiveDismissDisabled(busy)
        .sheet(item: $editingList) { scope in
            WorkPeriodListEditor(model: model, scope: scope)
        }
        .alert("Удалить этап из справочника?", isPresented: Binding(
            get: { removal != nil }, set: { if !$0 { removal = nil } }
        ), presenting: removal) { entry in
            Button("Отмена", role: .cancel) {}
            Button("Удалить", role: .destructive) {
                let items = WorkPeriodListEditor.Scope.fields(entry.scope.visibleEntries.filter { $0.id != entry.item.id })
                saveRows(items, in: entry.scope)
            }
        } message: { entry in
            Text("«\(entry.item.title)». Этапы, добавленные в проекты, хранятся в карточках проектов.")
        }
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                browsePicker
                search
                Spacer(minLength: 8)
                actions
            }
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack { browsePicker; Spacer(minLength: 6); actions }
                    VStack(alignment: .leading, spacing: 8) { browsePicker; actions }
                }
                search
            }
        }
    }

    private var search: some View {
        HStack(spacing: 6) {
            PanelSearchField(placeholder: "Поиск по этапам…", query: $query, focus: $searchFocused)
            Button("⌘K") { searchFocused = true }
                .font(.caption.monospaced())
                .buttonStyle(.plain)
                .keyboardShortcut("k", modifiers: .command)
                .accessibilityLabel("Перейти к поиску этапов")
                .padding(.trailing, 8)
        }
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(palette.border).allowsHitTesting(false) }
        .frame(minWidth: 170, maxWidth: 310)
    }

    private var actions: some View {
        HStack {
            if lists != nil {
                if industry.isEmpty {
                    Menu {
                        ForEach(options) { item in
                            Button(item.title) { openEditor(item) }
                        }
                    } label: {
                        Label("Редактировать этапы", systemImage: "pencil")
                    }
                    .disabled(busy || editing)
                } else if let item = options.first(where: { $0.id == industry }) {
                    Button {
                        openEditor(item)
                    } label: {
                        Label("Редактировать этапы", systemImage: "pencil")
                    }
                    .disabled(busy || editing)
                }
            }
            newButton
        }
    }

    private func openEditor(_ option: CatalogOption) {
        editingList = scope(for: option)
    }

    private func scope(for option: CatalogOption) -> WorkPeriodListEditor.Scope {
        let current = option.industry == "events" && option.projectType == nil
            ? (model.workspace?.workPeriodCatalog ?? []).filter { $0.industryId == option.industry }
            : entries(in: option)
        return .init(industry: option.industry, projectType: option.projectType,
                     title: option.title, entries: current,
                     hidesBuiltIn: option.industry == "events" && option.projectType == nil && lists != nil)
    }

    private var browsePicker: some View {
        Picker("Отрасль", selection: $industry) {
            Text("Все отрасли").tag("")
            ForEach(options) { option in Text(option.title).tag(option.id) }
        }
        .disabled(busy)
    }

    private var newButton: some View {
        Button {
            renamingScope = nil
            editor = Editor(title: "", industry: industry.isEmpty ? "universal" : industry)
            editing = true
            titleFocused = true
        } label: {
            Label("Новый этап", systemImage: "plus")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color(red: 0.40, green: 0.24, blue: 0.83), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(busy || editing || model.workspace?.workPeriodCatalog == nil ? 0.55 : 1)
        .disabled(busy || editing || model.workspace?.workPeriodCatalog == nil)
    }

    private func catalogList(_ sections: [(CatalogOption, [WorkPeriodTemplate])]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 7) {
                ForEach(sections, id: \.0.id) { option, items in
                    if !items.isEmpty {
                        if industry.isEmpty {
                            Text(option.title).font(.headline)
                                .foregroundStyle(palette.muted).accessibilityAddTraits(.isHeader)
                                .padding(.top, 8)
                        }
                        let all = entries(in: option)
                        let positions = Dictionary(all.enumerated().map { ($0.element.id, $0.offset + 1) },
                                                   uniquingKeysWith: { first, _ in first })
                        ForEach(items) { item in
                            row(item, position: positions[item.id] ?? 1, in: option)
                        }
                    }
                }
            }
            .padding(.horizontal, embedded ? 24 : 14)
            .padding(.vertical, 8)
        }
        .coordinateSpace(name: "work-period-list")
        .onPreferenceChange(RowFrames.self) { rowFrames = $0 }
    }

    private func row(_ item: WorkPeriodTemplate, position: Int, in option: CatalogOption) -> some View {
        let canEdit = lists != nil && embedded
        let canMove = canEdit && !busy && !editing && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let emphasized = hoveredID == item.id || dropTarget == item.id
        let shape = RoundedRectangle(cornerRadius: 11)
        return HStack(spacing: 12) {
            if canMove {
                Image(systemName: "line.3.horizontal")
                    .font(.callout.weight(.semibold)).foregroundStyle(palette.muted)
                    .frame(width: 20, height: 30)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .named("work-period-list"))
                        .onChanged { drag in
                            dropTarget = target(at: drag.location, in: option, except: item.id)
                        }
                        .onEnded { drag in
                            dropTarget = nil
                            guard let target = target(at: drag.location, in: option, except: item.id) else { return }
                            moveRow(item.id, to: target, in: option)
                        })
                    .help("Перетащить этап")
                    .accessibilityHidden(true)
            }
            Text(String(format: "%02d", position))
                .font(.callout.weight(.medium).monospacedDigit())
                .foregroundStyle(palette.text)
                .frame(width: 37, height: 28)
                .background(palette.projectAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Этап \(position)")
            Image(systemName: icon(for: item))
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(palette.projectAccent)
                .frame(width: 38, height: 38)
                .background(palette.projectAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            Text(item.title).font(.callout.weight(.semibold))
                .foregroundStyle(palette.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if canEdit || (!item.builtIn && lists == nil) {
                Button {
                    renamingScope = canEdit ? scope(for: option) : nil
                    editor = Editor(id: item.id, title: item.title, industry: option.id)
                    editing = true
                    titleFocused = true
                } label: {
                    Image(systemName: "pencil").frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.projectAccent)
                .help("Переименовать этап")
                .accessibilityLabel("Изменить «\(item.title)»")
                .disabled(busy || editing)
            }
            if canEdit {
                Button(role: .destructive) {
                    removal = Removal(item: item, scope: scope(for: option))
                } label: {
                    Image(systemName: "trash").frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.muted)
                .help("Удалить этап")
                .accessibilityLabel("Удалить «\(item.title)»")
                .disabled(busy || editing)
            }
            if let addToProject {
                Button("В проект") {
                    addToProject(item.title)
                    dismiss()
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Добавить «\(item.title)» в проект")
                .disabled(busy || editing)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(emphasized ? palette.projectAccent.opacity(0.08) : palette.surface, in: shape)
        .overlay { shape.strokeBorder(emphasized ? palette.projectAccent : palette.border).allowsHitTesting(false) }
        .background {
            if canMove {
                GeometryReader { proxy in
                    Color.clear.preference(key: RowFrames.self, value: [
                        item.id: proxy.frame(in: .named("work-period-list"))
                    ])
                }
            }
        }
        .onHover { entered in
            if entered { hoveredID = item.id }
            else if hoveredID == item.id { hoveredID = nil }
        }
    }

    private func target(at location: CGPoint, in option: CatalogOption, except id: String) -> String? {
        entries(in: option).first { $0.id != id && rowFrames[$0.id]?.contains(location) == true }?.id
    }

    private func moveRow(_ id: String, to target: String, in option: CatalogOption) {
        guard !busy && !editing && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let scope = scope(for: option)
        var entries = scope.visibleEntries
        guard let from = entries.firstIndex(where: { $0.id == id }),
              let to = entries.firstIndex(where: { $0.id == target }), from != to else { return }
        let moved = entries.remove(at: from)
        entries.insert(moved, at: to)
        saveRows(WorkPeriodListEditor.Scope.fields(entries), in: scope)
    }

    private func icon(for item: WorkPeriodTemplate) -> String {
        switch item.id.split(separator: ":").last {
        case "brief": return "bubble.left"
        case "concept": return "lightbulb"
        case "design", "decor-design": return "photo"
        case "budget": return "list.number"
        case "procurement": return "cart"
        case "production": return "shippingbox"
        case "setup", "delivery": return "truck.box"
        case "teardown", "closure": return "checkmark.circle"
        case "venue": return "mappin.and.ellipse"
        case "guests": return "person.2"
        default: return item.builtIn ? "square.3.layers.3d" : "bookmark"
        }
    }

    private func saveRows(_ items: [[String: String]], in scope: WorkPeriodListEditor.Scope) {
        Task {
            actionError = nil
            if await model.command(scope.request(items: items)) == false {
                actionError = model.error
            }
        }
    }

    private func industryPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(options) { option in Text(option.title).tag(option.id) }
        }
        .disabled(busy)
    }

    private var editForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(editor.id == nil ? "Новый этап" : "Редактирование этапа").font(.headline)
            TextField("Название этапа", text: $editor.title)
                .textFieldStyle(.roundedBorder)
                .focused($titleFocused)
            if renamingScope == nil { industryPicker("Сохранить в раздел", selection: $editor.industry) }
            if let message = model.error {
                Text(message).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Отмена") { editing = false; renamingScope = nil }.disabled(busy)
                Button("Сохранить в справочник") {
                    saveEntry()
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || editor.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .panelCard(inset: 12)
        .disabled(busy || model.workspace?.workPeriodCatalog == nil)
    }

    private func saveEntry() {
        let draft = editor
        guard let option = options.first(where: { $0.id == draft.industry }) else { return }
        Task {
            let saved: Bool
            if let scope = renamingScope {
                let items = scope.visibleEntries.map {
                    ["id": $0.id, "title": $0.id == draft.id ? draft.title : $0.title]
                }
                saved = await model.command(scope.request(items: items))
            } else if let type = option.projectType, draft.id == nil {
                let base = entries(in: option).map { ["id": $0.id, "title": $0.title] }
                let item = ["id": WorkPeriodListEditor.newID(), "title": draft.title]
                saved = await model.command(["op": "save_work_period_list", "data": [
                    "industry_id": option.industry, "project_type": type, "base": base, "items": base + [item]
                ]])
            } else {
                var data: [String: Any] = ["title": draft.title, "industry_id": option.industry]
                if let id = draft.id { data["id"] = id }
                saved = await model.command(["op": "save_work_period_template", "data": data])
            }
            if saved {
                if !industry.isEmpty { industry = option.id }
                query = ""
                editing = false
                renamingScope = nil
            }
        }
    }
}
