import SwiftUI

struct TaskWorkspace: View {
    @ObservedObject var model: WorkspaceModel
    let tasks: [TaskItem]
    let projects: [Project]
    let people: [Person]
    @Binding var selection: Int?
    @State private var dropColumn: BoardColumn?
    @Environment(\.colorScheme) private var colorScheme

    private struct BoardColumn: Equatable {
        let projectID: Int?
        let stageID: String
    }

    private let stickerColors: [Color] = [
        Color(red: 0.98, green: 0.78, blue: 0.35),
        Color(red: 0.40, green: 0.70, blue: 0.98),
        Color(red: 0.76, green: 0.57, blue: 0.97),
        Color(red: 0.39, green: 0.82, blue: 0.65),
        Color(red: 0.98, green: 0.58, blue: 0.66)
    ]

    private var palette: PanelPalette { PanelPalette(dark: colorScheme == .dark) }

    private func stages(for project: Int?) -> [Stage] {
        projects.first { $0.id == project }?.stages ?? model.workspace?.defaultStages ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            if tasks.isEmpty {
                Label("Задач нет", systemImage: "checklist")
                    .foregroundStyle(.secondary)
                    .panelCard()
            } else {
                boardView
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(tasks.count, format: .number)
                .font(.caption.weight(.medium).monospacedDigit())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Задач: \(tasks.count)")
            Spacer(minLength: 0)
            if model.lastBatchID != nil {
                Button {
                    Task { await model.undoBatch() }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .help("Отменить последнее действие")
                .accessibilityLabel("Отменить последнее действие")
                .disabled(model.saving || model.loading)
            }
        }
    }

    private var boardView: some View {
        let groups = Dictionary(grouping: tasks, by: \.projectId)
        let projectIDs = groups.keys.sorted { ($0 ?? 0) < ($1 ?? 0) }
        return ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(projectIDs, id: \.self) { projectID in
                    Label(projects.first { $0.id == projectID }?.title ?? "Без проекта", systemImage: "folder")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(stages(for: projectID).enumerated()), id: \.element.id) { index, stage in
                            let column = BoardColumn(projectID: projectID, stageID: stage.id)
                            let targeted = dropColumn == column
                            let color = stickerColors[index % stickerColors.count]
                            VStack(alignment: .leading, spacing: 8) {
                                let cards = (groups[projectID] ?? []).filter { $0.stageId == stage.id }
                                HStack(spacing: 6) {
                                    Text(stage.title).font(.callout.weight(.semibold))
                                    Spacer(minLength: 4)
                                    Text(cards.count, format: .number).font(.caption.monospacedDigit())
                                        .foregroundStyle(palette.muted)
                                }
                                ForEach(cards) { task in
                                    Button { selection = task.id } label: {
                                        let assignee = people.first { $0.id == task.assigneeId }?.name
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(task.title).font(.callout.weight(.semibold))
                                                .fixedSize(horizontal: false, vertical: true)
                                            Label(assignee ?? "Без исполнителя", systemImage: "person")
                                                .font(.system(.caption, design: .serif).italic())
                                                .foregroundStyle(palette.muted)
                                                .fixedSize(horizontal: false, vertical: true)
                                            if let due = task.dueDate {
                                                Label([due, task.dueTime].compactMap { $0 }.joined(separator: " "),
                                                      systemImage: task.overdue ? "exclamationmark.clock" : "calendar")
                                                    .font(.caption)
                                                    .foregroundStyle(task.overdue ? Color.red : Color.secondary)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(11)
                                        .padding(.bottom, 5)
                                        .background {
                                            let dark = colorScheme == .dark
                                            let paper = StickerPaper()
                                            paper
                                                .fill(.background)
                                                .shadow(color: .black.opacity(dark ? 0.42 : 0.22), radius: 4, x: 1, y: 3)
                                            paper.fill(.linearGradient(
                                                colors: [color.opacity(dark ? 0.38 : 0.58),
                                                         color.opacity(dark ? 0.20 : 0.34)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing
                                            ))
                                            StickerPaper(foldOnly: true).fill(.linearGradient(
                                                colors: [.white.opacity(dark ? 0.25 : 0.72), color.opacity(0.48)],
                                                startPoint: .bottomTrailing, endPoint: .center
                                            ))
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .draggable("vtask-task:\(task.id)")
                                }
                            }
                            .padding(10)
                            .frame(width: 170, alignment: .leading)
                            .frame(minHeight: 132, alignment: .topLeading)
                            .background {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(targeted ? palette.selected : palette.surface)
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(targeted ? palette.accent : palette.border, lineWidth: targeted ? 2 : 1)
                            }
                            .contentShape(Rectangle())
                            .dropDestination(for: String.self) { items, _ in
                                let prefix = "vtask-task:"
                                guard items.count == 1, let item = items.first, item.hasPrefix(prefix),
                                      let id = Int(item.dropFirst(prefix.count)),
                                      let task = groups[projectID]?.first(where: { $0.id == id }),
                                      task.stageId != stage.id, !model.loading, !model.saving else { return false }
                                Task { await model.updateTask(task, changes: ["stage_id": stage.id]) }
                                return true
                            } isTargeted: { entered in
                                if entered { dropColumn = column }
                                else if dropColumn == column { dropColumn = nil }
                            }
                        }
                    }
                }
            }.padding(.vertical, 10)
        }
    }
}

private struct StickerPaper: Shape {
    var foldOnly = false

    func path(in rect: CGRect) -> Path {
        let fold = min(13, min(rect.width, rect.height) / 2)
        let inner = CGPoint(x: rect.maxX - fold, y: rect.maxY - fold)
        let right = CGPoint(x: rect.maxX, y: inner.y)
        let bottom = CGPoint(x: inner.x, y: rect.maxY)
        return Path { path in
            if foldOnly {
                path.move(to: inner)
                path.addLine(to: right)
                path.addLine(to: bottom)
            } else {
                path.move(to: rect.origin)
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                path.addLine(to: right)
                path.addLine(to: bottom)
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            }
            path.closeSubpath()
        }
    }
}

struct TaskBatchBar: View {
    enum Action: String, CaseIterable, Identifiable {
        case assignee = "Назначить исполнителя"
        case due = "Изменить срок"
        case stage = "Изменить статус"

        var id: Self { self }
    }

    @ObservedObject var model: WorkspaceModel
    let workspace: Workspace
    let tasks: [TaskItem]
    @Binding var selection: Set<Int>
    @State private var action: Action?

    private var selectedTasks: [TaskItem] { tasks.filter { selection.contains($0.id) } }

    private func stages(for task: TaskItem) -> [Stage] {
        workspace.projects.first { $0.id == task.projectId }?.stages ?? workspace.defaultStages
    }

    private var commonStages: [Stage] {
        guard let first = selectedTasks.first else { return [] }
        return stages(for: first).filter { stage in
            selectedTasks.allSatisfy { task in
                stages(for: task).contains { $0.id == stage.id && $0.title == stage.title && $0.kind == stage.kind }
            }
        }
    }

    var body: some View {
        if !selectedTasks.isEmpty || model.lastBatchID != nil {
            HStack(spacing: 10) {
                if !selectedTasks.isEmpty {
                    Text("Выбрано: \(selectedTasks.count)").font(.callout.weight(.medium)).monospacedDigit()
                    Menu {
                        ForEach(Action.allCases) { item in
                            Button(item.rawValue) { action = item }
                                .disabled(item == .stage && commonStages.isEmpty)
                        }
                    } label: {
                        Label("Действия", systemImage: "ellipsis.circle")
                    }
                    .disabled(model.saving || model.loading)
                    Button("Снять выбор") { selection.removeAll() }.buttonStyle(.link)
                }
                Spacer(minLength: 4)
                if model.lastBatchID != nil {
                    Button {
                        Task { await model.undoBatch() }
                    } label: {
                        Label("Отменить действие", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(model.saving || model.loading)
                }
            }
            .panelCard(inset: 10)
            .sheet(item: $action) { action in
                BatchEditor(model: model, action: action, tasks: selectedTasks, people: workspace.people,
                            stages: commonStages) {
                    selection.removeAll()
                    self.action = nil
                }
                .sheetCloseButton(disabled: model.saving)
            }
        }
    }
}

private struct BatchEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: WorkspaceModel
    let action: TaskBatchBar.Action
    let tasks: [TaskItem]
    let people: [Person]
    let stages: [Stage]
    let didSave: () -> Void
    @State private var assignee: Int?
    @State private var stage = ""
    @State private var date = ""
    @State private var time = ""

    var body: some View {
        Form {
            Text(action.rawValue).font(.headline)
            Text("Задач выбрано: \(tasks.count)").foregroundStyle(.secondary)
            switch action {
            case .assignee:
                Picker("Исполнитель", selection: $assignee) {
                    Text("Не назначен").tag(nil as Int?)
                    ForEach(people) { Text($0.name).tag(Optional($0.id)) }
                }
            case .due:
                TextField("Дата (ГГГГ-ММ-ДД)", text: $date)
                TextField("Время (ЧЧ:ММ)", text: $time)
                Text("Пустая дата снимет срок.").font(.caption)
            case .stage:
                Picker("Статус", selection: $stage) {
                    Text("Выберите статус").tag("")
                    ForEach(stages) { Text($0.title).tag($0.id) }
                }
            }
            if let error = model.error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Отмена") { dismiss() }
                Button("Применить") {
                    Task {
                        let changes: [String: Any]
                        switch action {
                        case .assignee: changes = ["assignee_id": assignee.map { $0 as Any } ?? NSNull()]
                        case .due: changes = ["due_date": date.isEmpty ? NSNull() as Any : date,
                                             "due_time": date.isEmpty || time.isEmpty ? NSNull() as Any : time]
                        case .stage: changes = ["stage_id": stage]
                        }
                        if await model.updateTasks(tasks, changes: changes) { didSave() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(action == .stage && stage.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 270)
        .disabled(model.saving || model.loading)
        .interactiveDismissDisabled(model.saving)
    }
}
