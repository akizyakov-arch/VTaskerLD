import SwiftUI

struct WorkPeriodListEditor: View {
    struct Scope: Identifiable {
        let industry: String
        let projectType: String?
        let title: String
        let entries: [WorkPeriodTemplate]
        let hidesBuiltIn: Bool
        var id: String { projectType ?? industry }

        var visibleEntries: [WorkPeriodTemplate] {
            entries.filter { !hidesBuiltIn || !$0.id.hasPrefix("builtin:") }
        }

        func request(items: [[String: String]]) -> [String: Any] {
            let base = Self.fields(entries)
            let hidden = hidesBuiltIn ? base.filter { $0["id"]?.hasPrefix("builtin:") == true } : []
            var data: [String: Any] = ["industry_id": industry, "base": base, "items": items + hidden]
            if let projectType { data["project_type"] = projectType }
            return ["op": "save_work_period_list", "data": data]
        }

        static func fields(_ entries: [WorkPeriodTemplate]) -> [[String: String]] {
            entries.map { ["id": $0.id, "title": $0.title] }
        }
    }

    private struct Row: Identifiable {
        let id: String
        var title: String

        var payload: [String: String] {
            ["id": id, "title": title.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
    }

    @ObservedObject var model: WorkspaceModel
    let scope: Scope
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row]
    @State private var newTitle = ""
    @State private var error: String?

    init(model: WorkspaceModel, scope: Scope) {
        self.model = model
        self.scope = scope
        _rows = State(initialValue: scope.visibleEntries
            .map { Row(id: $0.id, title: $0.title) })
    }

    private var busy: Bool { model.loading || model.saving }
    private var trimmedNewTitle: String { newTitle.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var initialRows: [[String: String]] { Scope.fields(scope.visibleEntries) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Этапы работ").font(.title3.weight(.semibold))
                    Text(scope.title).foregroundStyle(.secondary)
                }
                Spacer()
                WindowCloseButton(label: "Закрыть редактор этапов") { dismiss() }
                    .disabled(busy)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach($rows) { $row in
                        HStack(spacing: 10) {
                            TextField("Название этапа", text: $row.title)
                                .textFieldStyle(.roundedBorder)
                            Button { move(row.id, by: -1) } label: { Image(systemName: "arrow.up") }
                                .accessibilityLabel("Поднять этап").help("Поднять этап")
                                .disabled(rows.first?.id == row.id)
                            Button { move(row.id, by: 1) } label: { Image(systemName: "arrow.down") }
                                .accessibilityLabel("Опустить этап").help("Опустить этап")
                                .disabled(rows.last?.id == row.id)
                            Button(role: .destructive) {
                                let id = row.id
                                rows.removeAll { $0.id == id }
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .accessibilityLabel("Удалить этап").help("Удалить этап")
                        }
                        .buttonStyle(.borderless)
                        .padding(.vertical, 7)
                        Divider()
                    }
                    HStack {
                        TextField("Название нового этапа", text: $newTitle)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(add)
                        Button(action: add) { Label("Добавить", systemImage: "plus") }
                            .disabled(!canAdd)
                    }
                    .padding(.top, 10)
                }
                .padding(16)
            }
            .disabled(busy)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let error { Text(error).foregroundStyle(.red) }
                HStack {
                    Spacer()
                    Button("Отмена") { dismiss() }.disabled(busy)
                    Button("Сохранить", action: save)
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || rows.map(\.payload) == initialRows || rows.contains { $0.payload["title"] == "" })
                }
            }
            .padding(16)
        }
        .frame(width: 570, height: 545)
        .interactiveDismissDisabled(busy)
    }

    private var canAdd: Bool { !busy && !trimmedNewTitle.isEmpty && rows.count < 250 }

    private func add() {
        guard canAdd else { return }
        rows.append(Row(id: Self.newID(), title: trimmedNewTitle))
        newTitle = ""
    }

    private func move(_ id: String, by offset: Int) {
        guard let index = rows.firstIndex(where: { $0.id == id }), rows.indices.contains(index + offset) else { return }
        rows.swapAt(index, index + offset)
    }

    static func newID() -> String {
        "custom:" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func save() {
        Task {
            error = nil
            if await model.command(scope.request(items: rows.map(\.payload))) {
                dismiss()
            } else {
                error = model.error
            }
        }
    }
}
