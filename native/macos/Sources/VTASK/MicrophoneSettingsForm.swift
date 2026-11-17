import SwiftUI

struct MicrophoneDevices: Decodable {
    struct Selection: Decodable { let uid: String }
    struct Device: Decodable, Identifiable {
        let uid: String
        let name: String
        var id: String { uid }
    }

    let selected: Selection
    let devices: [Device]
}

struct MicrophoneStatus: Decodable {
    struct Test: Decodable {
        let state: String?
        let level: Double?
        let peak: Double?
        let error: String?

        var label: String {
            switch state {
            case "starting": return "Микрофон запускается"
            case "testing": return "Проверка уровня"
            case "completed": return (peak ?? 0) > 0.002 ? "Сигнал обнаружен" : "Сигнал очень тихий"
            case "failed": return "Ошибка проверки"
            default: return "Проверка ещё не запускалась"
            }
        }
    }

    let test: Test?
}

struct MicrophoneSettingsForm: View {
    @ObservedObject var model: WorkspaceModel
    @State private var devices: MicrophoneDevices?
    @State private var uid = ""
    @State private var error: String?
    @State private var test: MicrophoneStatus.Test?
    @State private var testRun: UUID?

    var body: some View {
        Section("Микрофон") {
            if let devices {
                Picker("Устройство ввода", selection: $uid) {
                    Text("Системный микрофон").tag("")
                    if !uid.isEmpty && !devices.devices.contains(where: { $0.uid == uid }) {
                        Text("Микрофон отключён").tag(uid)
                    }
                    ForEach(devices.devices) { Text($0.name).tag($0.uid) }
                }
                HStack {
                    Button("Сохранить") {
                        Task {
                            if await model.command(["uid": uid], path: "api/devices/select") { await loadDevices() }
                        }
                    }
                    .disabled(testRun != nil || model.capture?.active != nil)
                    Button("Проверить 5 секунд") {
                        Task {
                            if await model.command(["uid": uid, "seconds": 5], path: "api/devices/test") {
                                testRun = UUID()
                            }
                        }
                    }
                    .disabled(testRun != nil || model.capture?.active != nil)
                }
            }
            Button("Обновить список") { Task { await loadDevices() } }
            if let test {
                Text(test.label).foregroundStyle(.secondary)
                if test.state == "testing" {
                    ProgressView(value: min(1, max(0, (test.level ?? 0) * 2.5)))
                        .accessibilityLabel("Уровень микрофона")
                }
                if let message = test.error { Text(message).foregroundStyle(.red) }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .task { await loadDevices() }
        .task(id: testRun) {
            guard testRun != nil else { return }
            defer { if !Task.isCancelled { testRun = nil } }
            for _ in 0..<40 {
                guard !Task.isCancelled else { return }
                do {
                    test = try await model.engineSettings().microphone?.test
                    guard ["starting", "testing"].contains(test?.state ?? "") else { return }
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    if !Task.isCancelled { self.error = error.localizedDescription }
                    return
                }
            }
        }
    }

    private func loadDevices() async {
        do {
            let result = try await model.microphoneDevices()
            devices = result
            uid = result.selected.uid
            error = nil
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}
