import SwiftUI
import UniformTypeIdentifiers

struct DictionaryImportPreview: Decodable, Identifiable {
    struct Row: Decodable, Identifiable {
        enum Status: String, Decodable {
            case new, updated, duplicate, conflict, invalid

            var title: String {
                switch self {
                case .new: "Добавится"
                case .updated: "Обновится"
                case .duplicate: "Дубль"
                case .conflict: "Конфликт"
                case .invalid: "Ошибка"
                }
            }
        }

        let id: Int
        let term: String
        let status: Status
        let detail: String?
    }

    let token: String
    let title: String
    let added: Int
    let updated: Int
    let duplicate: Int
    let conflict: Int
    let invalid: Int
    let rows: [Row]

    var id: String { token }
    var changes: Int { added + updated }
}

struct DictionaryTransferMenu: View {
    @ObservedObject var model: WorkspaceModel
    @State private var choosingImport = false
    @State private var choosingExport = false
    @State private var working = false
    @State private var preview: DictionaryImportPreview?
    @State private var input: [String: Any] = [:]
    @State private var output: JSONDictionaryDocument?
    @State private var exportName = ""
    @State private var failure: String?

    var body: some View {
        Menu {
            Button("Импортировать JSON…") { choosingImport = true }
            Divider()
            Button("Экспортировать словарь компании…") {
                Task { await export(scope: "company", name: "Словарь компании") }
            }
            Button("Экспортировать выбранный отраслевой пакет…") {
                Task { await export(scope: "industry", name: model.workspace?.industryTitle ?? "Отраслевой словарь") }
            }
        } label: {
            Label("Импорт и экспорт", systemImage: "arrow.up.arrow.down")
        }
        .fixedSize()
        .disabled(working || model.saving)
        .fileImporter(isPresented: $choosingImport, allowedContentTypes: [.json]) { result in
            Task { await previewImport(result) }
        }
        .fileExporter(isPresented: $choosingExport, document: output, contentType: .json,
                      defaultFilename: exportName) { result in
            if case .failure(let error) = result { failure = error.localizedDescription }
            output = nil
        }
        .sheet(item: $preview, onDismiss: { input = [:] }) { report in
            DictionaryPreviewSheet(model: model, report: report, document: input)
                .sheetCloseButton(disabled: model.saving)
        }
        .alert("Не удалось обработать словарь",
               isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("ОК", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func previewImport(_ selection: Result<URL, Error>) async {
        working = true
        defer { working = false }
        do {
            let url = try selection.get()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let limit = 512 * 1024
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            guard data.count <= limit else {
                failure = "Выберите JSON-файл размером до 512 КБ."
                return
            }
            guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                failure = "Выберите JSON одного отраслевого пакета или словаря компании."
                return
            }
            let report = try await model.previewDictionaryImport(document)
            input = document
            preview = report
        } catch {
            failure = error.localizedDescription
        }
    }

    private func export(scope: String, name: String) async {
        working = true
        defer { working = false }
        do {
            output = JSONDictionaryDocument(data: try await model.exportDictionary(scope: scope))
            exportName = name
            choosingExport = true
        } catch {
            failure = error.localizedDescription
        }
    }
}

private struct DictionaryPreviewSheet: View {
    @ObservedObject var model: WorkspaceModel
    let report: DictionaryImportPreview
    let document: [String: Any]
    @Environment(\.dismiss) private var dismiss
    @State private var onlyIssues = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Импорт · \(report.title)").font(.title3.bold())
            Text("Новые — \(report.added) · Обновления — \(report.updated) · Дубли — \(report.duplicate)")
            Text("Конфликты — \(report.conflict) · Ошибки — \(report.invalid)")
                .foregroundStyle(.secondary)
            Toggle("Только конфликты и ошибки", isOn: $onlyIssues)
            List {
                ForEach(report.rows.filter { !onlyIssues || $0.status == .invalid || $0.status == .conflict }) { row in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(row.term)
                            if let detail = row.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(row.status.title).foregroundStyle(.secondary)
                    }
                }
            }
            if failed, let error = model.error {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Закрыть", role: .cancel) { dismiss() }
                Button("Импортировать \(report.changes)") {
                    Task {
                        if await model.command(["op": "apply_dictionary_import",
                                                "document": document, "token": report.token]) {
                            dismiss()
                        } else {
                            failed = true
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(report.changes == 0)
            }
        }
        .padding(20)
        .frame(width: 600, height: 510)
        .disabled(model.saving)
        .interactiveDismissDisabled(model.saving)
    }
}

private struct JSONDictionaryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
