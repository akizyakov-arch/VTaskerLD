import SwiftUI

struct BoardDraft {
    struct Column: Identifiable {
        let id: String
        var title: String
        let kind: String
    }

    var columns: [Column]
    var migrations: [String: String] = [:]

    init(stages: [Stage]) {
        columns = stages.map { Column(id: $0.id, title: $0.title, kind: $0.kind) }
    }

    func removedOccupiedStages(original: [Stage], occupied: Set<String>) -> [Stage] {
        let retained = Set(columns.map(\.id))
        return original.filter { occupied.contains($0.id) && !retained.contains($0.id) }
    }

    func canSave(removed: [Stage]) -> Bool {
        let ids = Set(columns.map(\.id))
        return columns.allSatisfy { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && removed.allSatisfy { stage in migrations[stage.id].map(ids.contains) == true }
    }

    var payload: [[String: String]] {
        columns.map {
            ["id": $0.id, "title": $0.title.trimmingCharacters(in: .whitespacesAndNewlines), "kind": $0.kind]
        }
    }

    mutating func move(_ id: String, by offset: Int) {
        guard let index = columns.firstIndex(where: { $0.id == id }),
              columns.indices.contains(index + offset) else { return }
        columns.swapAt(index, index + offset)
    }

    mutating func remove(_ id: String) {
        columns.removeAll { $0.id == id }
        migrations = migrations.filter { $0.value != id }
    }
}

struct BoardColumnFields: View {
    @Binding var draft: BoardDraft
    let removed: [Stage]

    var body: some View {
        Section("Колонки доски") {
            ForEach($draft.columns) { $column in
                HStack {
                    TextField("Название колонки", text: $column.title)
                    Button { draft.move(column.id, by: -1) } label: { Image(systemName: "chevron.up") }
                        .accessibilityLabel("Поднять колонку").help("Поднять колонку")
                        .disabled(draft.columns.first?.id == column.id)
                    Button { draft.move(column.id, by: 1) } label: { Image(systemName: "chevron.down") }
                        .accessibilityLabel("Опустить колонку").help("Опустить колонку")
                        .disabled(draft.columns.last?.id == column.id)
                    Button(role: .destructive) { draft.remove(column.id) } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Удалить колонку").help("Удалить колонку")
                        .disabled(draft.columns.filter { $0.kind == column.kind }.count <= 1)
                }
                .buttonStyle(.borderless)
            }
            Button {
                draft.columns.append(BoardDraft.Column(id: UUID().uuidString, title: "", kind: "active"))
            } label: {
                Label("Добавить колонку", systemImage: "plus")
            }
            .disabled(draft.columns.count >= 30)
        }
        if !removed.isEmpty {
            Section("Перенос задач") {
                ForEach(removed) { stage in
                    Picker("Из колонки «\(stage.title)»", selection: Binding(
                        get: { draft.migrations[stage.id] ?? "" },
                        set: { draft.migrations[stage.id] = $0 }
                    )) {
                        Text("Выберите колонку").tag("")
                        ForEach(draft.columns) { destination in
                            Text(destination.title.isEmpty ? "Новая колонка" : destination.title)
                                .tag(destination.id)
                        }
                    }
                }
            }
        }
    }
}

struct BoardEditor: View {
    @ObservedObject var model: WorkspaceModel
    let project: Project
    @Environment(\.dismiss) private var dismiss
    @State private var draft: BoardDraft
    @State private var error: String?

    init(model: WorkspaceModel, project: Project) {
        self.model = model
        self.project = project
        _draft = State(initialValue: BoardDraft(stages: project.stages))
    }

    var body: some View {
        let occupied = Set((model.workspace?.tasks ?? []).lazy
            .filter { $0.projectId == project.id }.map(\.stageId))
        let removed = draft.removedOccupiedStages(original: project.stages, occupied: occupied)
        let busy = model.saving || model.loading
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Редактировать доску", systemImage: "rectangle.split.3x1")
                        .font(.title3.weight(.semibold))
                    Text(project.title).foregroundStyle(.secondary)
                }
                Spacer()
                WindowCloseButton(label: "Закрыть редактор доски") { dismiss() }
                    .disabled(busy)
            }
            .padding(16)
            Divider()
            Form {
                BoardColumnFields(draft: $draft, removed: removed)
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)
            .disabled(busy)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let error { Text(error).foregroundStyle(.red) }
                HStack {
                    Spacer()
                    Button("Отмена") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(busy)
                    Button("Сохранить") {
                        Task {
                            error = nil
                            if await model.updateProject(project, changes: ["stages": draft.payload],
                                                         migrations: draft.migrations) {
                                dismiss()
                            } else {
                                error = model.error
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || !draft.canSave(removed: removed))
                }
            }
            .padding(16)
        }
        .frame(width: 520, height: 480)
        .interactiveDismissDisabled(busy)
    }
}
