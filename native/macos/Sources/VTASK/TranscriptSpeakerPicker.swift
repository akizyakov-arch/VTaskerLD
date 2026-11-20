import SwiftUI

extension Person {
    var speakerPickerName: String {
        [name, patronymic, lastName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

struct TranscriptSpeakerPicker: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: WorkspaceModel
    let meeting: Meeting
    let segment: Transcript.Segment
    let run: Int
    let canMatch: Bool
    let onAssign: (Int?, Bool, Bool) async -> Bool

    @State private var showEveryone = false
    @State private var query = ""
    @State private var organization = ""
    @State private var department = ""
    @State private var projectID: Int?
    @State private var selectedID: Int?
    @State private var wholeVoice = false
    @State private var enrollment: MeetingVoiceSource?

    private var people: [Person] { model.workspace?.people ?? [] }
    private var projects: [Project] { model.workspace?.projects ?? [] }

    private var filteredPeople: [Person] {
        let project = projects.first { $0.id == projectID }
        var projectPeople = Set(project?.members ?? [])
        if let owner = project?.ownerId { projectPeople.insert(owner) }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return people.filter { person in
            (showEveryone || meeting.participants.contains(person.id)) &&
            (organization.isEmpty || person.organization == organization) &&
            (department.isEmpty || person.department == department) &&
            (project == nil || projectPeople.contains(person.id)) &&
            (query.isEmpty || person.speakerPickerName.localizedCaseInsensitiveContains(query) ||
             person.nickname?.localizedCaseInsensitiveContains(query) == true)
        }
    }

    var body: some View {
        let results = filteredPeople
        VStack(alignment: .leading, spacing: 12) {
            Text("Назначить говорящего").font(.title3.bold())
            Text(segment.text).foregroundStyle(.secondary).lineLimit(2)
            Picker("Список", selection: $showEveryone) {
                Text("Участники встречи").tag(false)
                Text("Все участники").tag(true)
            }
            .pickerStyle(.segmented)
            TextField("Имя, фамилия или псевдоним", text: $query)
                .textFieldStyle(.roundedBorder)
            if showEveryone {
                HStack {
                    Picker("Организация", selection: $organization) {
                        Text("Все организации").tag("")
                        ForEach(Set(people.compactMap(\.organization).filter { !$0.isEmpty }).sorted(), id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    Picker("Проект", selection: $projectID) {
                        Text("Все проекты").tag(nil as Int?)
                        ForEach(projects) { Text($0.title).tag(Optional($0.id)) }
                    }
                }
                Picker("Подразделение", selection: $department) {
                    Text("Все подразделения").tag("")
                    ForEach(Set(people.compactMap(\.department).filter { !$0.isEmpty }).sorted(), id: \.self) {
                        Text($0).tag($0)
                    }
                }
            }
            List(results, selection: $selectedID) { person in
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.speakerPickerName)
                    let details = [person.nickname, person.role, person.department, person.organization].compactMap { $0 }.filter { !$0.isEmpty }
                    if !details.isEmpty {
                        Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(person.id)
            }
            .overlay {
                if results.isEmpty {
                    Text("Участники не найдены").foregroundStyle(.secondary).allowsHitTesting(false)
                }
            }
            if let speaker = segment.speakerId {
                Toggle("Применить ко всем репликам этого голоса", isOn: $wholeVoice)
                Button("Назначить и сохранить образец голоса") {
                    guard let selectedID else { return }
                    save(selectedID, enrollment: MeetingVoiceSource(run: run, speaker: speaker,
                                                                  personID: selectedID))
                }
                .disabled(!results.contains { $0.id == selectedID } || model.capture?.active != nil)
            }
            if canMatch {
                Button("Назначить и сопоставить остальные голоса") {
                    save(selectedID, rematch: true)
                }
                .disabled(!results.contains { $0.id == selectedID } || model.capture?.active != nil)
            }
            if let error = model.error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Оставить говорящего неизвестным") { save(nil) }
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Назначить") { save(selectedID) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!results.contains { $0.id == selectedID })
            }
        }
        .padding(18)
        .frame(width: 490, height: 465)
        .disabled(model.saving || model.loading)
        .interactiveDismissDisabled(model.saving)
        .sheet(item: $enrollment, onDismiss: { dismiss() }) { source in
            MeetingVoiceEnrollment(model: model, meeting: meeting, source: source)
                .sheetCloseButton(disabled: model.saving)
        }
        .onAppear {
            if let person = segment.resolvedSpeakerID {
                showEveryone = !meeting.participants.contains(person)
                selectedID = person
            }
        }
        .onChange(of: showEveryone) { _ in
            if !showEveryone, let selectedID, !meeting.participants.contains(selectedID) {
                self.selectedID = nil
            }
            organization = ""
            department = ""
            projectID = nil
        }
    }

    private func save(_ personID: Int?, rematch: Bool = false, enrollment: MeetingVoiceSource? = nil) {
        Task {
            guard await onAssign(personID, wholeVoice, rematch) else { return }
            if let enrollment {
                self.enrollment = enrollment
            } else {
                dismiss()
            }
        }
    }
}
