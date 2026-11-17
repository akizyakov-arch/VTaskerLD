import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct PersonDetailsEditor: View {
    @ObservedObject var model: WorkspaceModel
    let person: Person
    @State private var name: String
    @State private var lastName: String
    @State private var patronymic: String
    @State private var department: String
    @State private var nickname: String
    @State private var pickingPhoto = false
    @State private var photoError: String?
    @State private var role: String
    @State private var organization: String
    @State private var email: String
    @State private var phone: String
    @State private var notes: String
    @State private var saved = false

    init(model: WorkspaceModel, person: Person) {
        self.model = model
        self.person = person
        _name = State(initialValue: person.name)
        _lastName = State(initialValue: person.lastName ?? "")
        _patronymic = State(initialValue: person.patronymic ?? "")
        _department = State(initialValue: person.department ?? "")
        _nickname = State(initialValue: person.nickname ?? "")
        _role = State(initialValue: person.role ?? "")
        _organization = State(initialValue: person.organization ?? "")
        _email = State(initialValue: person.email ?? "")
        _phone = State(initialValue: person.phone ?? "")
        _notes = State(initialValue: person.notes ?? "")
    }

    private var fields: [String: String] {
        ["name": name, "last_name": lastName, "patronymic": patronymic, "role": role, "organization": organization,
         "department": department, "nickname": nickname, "email": email, "phone": phone, "notes": notes]
            .mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func edit(_ field: Binding<String>) -> Binding<String> {
        Binding(get: { field.wrappedValue }, set: { text in
            field.wrappedValue = text
            if saved { saved = false }
        })
    }

    var body: some View {
        let current = model.workspace?.people.first { $0.id == person.id } ?? person
        Group {
            Section("Данные участника") {
                profile(current)
                TextField("Имя", text: edit($name))
                TextField("Фамилия", text: edit($lastName))
                TextField("Отчество", text: edit($patronymic))
                TextField("Псевдоним", text: edit($nickname))
            }
            Section("Работа") {
                TextField("Должность или роль", text: edit($role))
                TextField("Организация", text: edit($organization))
                TextField("Подразделение", text: edit($department))
            }
            Section("Контакты и заметки") {
                TextField("Электронная почта", text: edit($email))
                TextField("Телефон", text: edit($phone))
                TextField("Заметки", text: edit($notes), axis: .vertical)
                    .lineLimit(3...6)
                saveButton
            }
        }
    }

    private func profile(_ current: Person) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                PersonAvatar(person: current, url: model.personPhotoURL(current), size: 50)
                VStack(alignment: .leading, spacing: 4) {
                    Text(current.speakerPickerName).font(.headline)
                    if let role = current.role, !role.isEmpty {
                        Text(role).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                Menu {
                    Button(current.photoRevision == nil ? "Добавить фото" : "Заменить фото") { pickingPhoto = true }
                    if current.photoRevision != nil {
                        Button("Удалить фото", role: .destructive) {
                            Task {
                                photoError = nil
                                if !(await model.savePersonPhoto(nil, personID: person.id)) {
                                    photoError = model.error ?? "Не удалось удалить фото."
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "camera")
                }
                .accessibilityLabel("Фото участника")
                .disabled(model.saving || model.loading)
            }
            if let photoError { Text(photoError).foregroundStyle(.red) }
        }
        .fileImporter(isPresented: $pickingPhoto, allowedContentTypes: [.image]) { result in
            Task {
                do {
                    photoError = nil
                    let url = try result.get()
                    let photo = try await Task.detached(priority: .userInitiated) { try Self.thumbnailJPEG(url) }.value
                    if !(await model.savePersonPhoto(photo, personID: person.id)) {
                        photoError = model.error ?? "Не удалось сохранить фото."
                    }
                } catch {
                    photoError = error.localizedDescription
                }
            }
        }
    }

    private var saveButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Сохранить данные участника") {
                Task {
                    saved = await model.command([
                        "op": "save_person", "id": person.id, "data": fields
                    ])
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.saving || model.loading || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if saved {
                Label("Данные сохранены", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    nonisolated private static func thumbnailJPEG(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: 512] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let data = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(encoder, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(encoder) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

}


struct PersonAvatar: View {
    let person: Person
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Text(String(person.name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.accentColor.opacity(0.12))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}
