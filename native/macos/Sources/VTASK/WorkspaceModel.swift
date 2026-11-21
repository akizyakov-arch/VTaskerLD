import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var workspace: Workspace?
    @Published private(set) var error: String?
    @Published private(set) var loading = false

    @Published private(set) var saving = false
    @Published private(set) var capture: CaptureStatus?
    private var savedViewPayloads: [[String: Any]] = []
    private var projectPayloads: [Int: [String: Any]] = [:]
    private var taskPayloads: [Int: [String: Any]] = [:]
    private let baseURL: URL
    private let launchesLocalCore: Bool
    private var coreProcess: Process?

    init(baseURL: URL = URL(string: "http://127.0.0.1:8765")!, launchesLocalCore: Bool = false) {
        self.baseURL = baseURL
        self.launchesLocalCore = launchesLocalCore
    }

    private func workspaceResponse() async throws -> Data {
        do {
            return try await request("api/workspace")
        } catch let error as URLError where launchesLocalCore && error.code == .cannotConnectToHost {
            if coreProcess?.isRunning != true {
                coreProcess = try LocalCore.start()
            }
            for _ in 0..<60 {
                try await Task.sleep(for: .milliseconds(250))
                do {
                    return try await request("api/workspace")
                } catch let retryError as URLError where retryError.code == .cannotConnectToHost {
                    if coreProcess?.isRunning == false { break }
                }
            }
            throw LocalCore.startupError
        }
    }

    private func request(_ path: String, payload: [String: Any]? = nil, query: [URLQueryItem] = []) async throws -> Data {
        var url = baseURL.appendingPathComponent(path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url, timeoutInterval: 10)
        if let payload {
            request.httpMethod = "POST"
            request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(data, response)
        return data
    }

    private func validateResponse(_ data: Data, _ response: URLResponse) throws {
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
            throw NSError(domain: "VTASK", code: 1, userInfo: [
                NSLocalizedDescriptionKey: body?["error"] ?? "Ядро VTASK отклонило запрос."
            ])
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }

    func reload() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }

        do {
            let data = try await workspaceResponse()
            let result = try decode(Workspace.self, from: data)
            let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let tasks = raw?["tasks"] as? [[String: Any]] ?? []
            taskPayloads = Dictionary(uniqueKeysWithValues: tasks.compactMap { task in
                (task["id"] as? Int).map { ($0, task) }
            })
            let projects = raw?["projects"] as? [[String: Any]] ?? []
            projectPayloads = Dictionary(uniqueKeysWithValues: projects.compactMap { project in
                (project["id"] as? Int).map { ($0, project) }
            })
            savedViewPayloads = (raw?["settings"] as? [String: Any])?["saved_views"] as? [[String: Any]] ?? []
            workspace = result
            error = nil
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    func importAudio(from url: URL, meetingID: Int) async {
        await uploadAudio(from: url, path: "api/import", query: URLQueryItem(name: "meeting_id", value: String(meetingID)))
    }

    func enrollVoice(from url: URL, personID: Int) async -> Bool {
        await uploadAudio(from: url, path: "api/voice/enroll", query: URLQueryItem(name: "person_id", value: String(personID)),
                          headers: ["X-Voice-Consent": "confirmed", "X-Voice-Single-Speaker": "confirmed"])
    }

    @discardableResult
    private func uploadAudio(from url: URL, path: String, query: URLQueryItem, headers: [String: String] = [:]) async -> Bool {
        guard !loading && !saving else { return false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        saving = true
        defer { saving = false }
        do {
            var endpoint = baseURL.appendingPathComponent(path)
            endpoint.append(queryItems: [query])
            var request = URLRequest(url: endpoint, timeoutInterval: 330)
            request.httpMethod = "POST"
            request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            let (data, response) = try await URLSession.shared.upload(for: request, fromFile: url)
            try validateResponse(data, response)
            await reload()
            return true
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
            return false
        }
    }

    func exportMeeting(_ meeting: Meeting, asText: Bool) async {
        do {
            let data = try await request("api/export/\(meeting.id)",
                                         query: asText ? [URLQueryItem(name: "format", value: "txt")] : [])
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "VTASK-meeting-\(meeting.id)." + (asText ? "txt" : "json")
            if await panel.begin() == .OK, let url = panel.url {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func transcript(for meeting: Meeting) async throws -> Transcript? {
        let data = try await request("api/transcript/\(meeting.id)")
        return try decode(Transcript?.self, from: data)
    }

    func liveTranscript(for meetingID: Int) async throws -> LiveTranscript? {
        let data = try await request("api/live/meeting/\(meetingID)")
        return try decode(LiveTranscript?.self, from: data)
    }

    func audioTimeline(for meetingID: Int) async throws -> [MeetingAudioOccurrence] {
        let data = try await request("api/audio-timeline/\(meetingID)")
        return try decode([MeetingAudioOccurrence].self, from: data)
    }

    func voiceSource(run: Int, speaker: String) async throws -> MeetingVoicePlan {
        let data = try await request("api/voice/source", payload: ["model_run_id": run, "speaker_id": speaker, "preview": true])
        return try decode(MeetingVoicePlan.self, from: data)
    }

    func pollCapture() async {
        var lastSpeechPoll = Date.distantPast
        while !Task.isCancelled {
            if let data = try? await request("api/recording/activity"),
               let result = try? decode(CaptureStatus.self, from: data) {
                if capture?.active != nil && result.active == nil { await reload() }
                if capture != result { capture = result }
            }
            if !saving, !loading, Date().timeIntervalSince(lastSpeechPoll) >= 2 {
                lastSpeechPoll = .now
                if let data = try? await request("api/jobs"),
                   let jobs = try? decode([ProcessingJob].self, from: data) {
                    let latest = Dictionary(jobs.map { ($0.meetingId, $0) }, uniquingKeysWith: { _, newer in newer })
                    let changed = workspace?.meetings.contains { meeting in
                        let current = latest[meeting.id]
                        return meeting.processing?.id != current?.id
                            || meeting.processing?.status != current?.status
                            || meeting.processing?.stage != current?.stage
                    } ?? false
                    if changed || workspace?.meetings.contains(where: { $0.analysis?.running == true }) == true {
                        await reload()
                    }
                }
            }
            try? await Task.sleep(for: capture?.active == nil ? .seconds(2) : .milliseconds(450))
        }
    }

    @discardableResult
    func setIndustryTemplate(_ template: IndustryTemplate) async -> Bool {
        await command(["op": "settings", "data": ["industry_template": template.rawValue]])
    }

    @discardableResult
    func command(_ payload: [String: Any], path: String = "api/workspace/action") async -> Bool {
        await commandResponse(payload, path: path) != nil
    }

    @discardableResult
    func setProjectArchived(_ archived: Bool, project: Project) async -> Bool {
        await command(["op": "archive_project", "id": project.id,
                       "revision": project.revision, "archived": archived])
    }

    func transcribeAssistant(_ audio: Data, sampleRate: Int) async throws -> String {
        struct Reply: Decodable { let text: String }
        var url = baseURL.appendingPathComponent("api/assistant/transcribe")
        url.append(queryItems: [URLQueryItem(name: "rate", value: String(sampleRate))])
        var request = URLRequest(url: url, timeoutInterval: 35)
        request.httpMethod = "POST"
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = audio
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(data, response)
        return try decode(Reply.self, from: data).text
    }

    func interpretAssistant(_ text: String, hasSearch: Bool, hasProject: Bool, hasTask: Bool,
                            followup: AssistantTaskUpdate?) async throws -> AssistantIntent {
        struct Reply: Decodable {
            let state: String
            let intent: AssistantIntent?
            let error: String?
        }
        let path = "api/assistant/interpret"
        let id = UUID().uuidString
        var payload: [String: Any] = ["id": id, "text": text, "has_search": hasSearch, "has_project": hasProject,
                                      "has_task": hasTask, "today": workspace?.today as Any? ?? NSNull()]
        if let followup {
            payload["task_update_followup"] = true
            payload["prior_due_date"] = followup.dueDate
        }
        struct Accepted: Decodable { let local: Bool? }
        let accepted = try decode(Accepted.self, from: await request(path, payload: payload))
        for _ in 0..<(accepted.local == true ? 150 : 80) {
            try await Task.sleep(for: .milliseconds(400))
            let data = try await request(path, query: [URLQueryItem(name: "id", value: id)])
            let reply = try decode(Reply.self, from: data)
            if let intent = reply.intent, reply.state == "ready" { return intent }
            if reply.state == "failed" {
                throw NSError(domain: "VTASK", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: reply.error ?? "Не удалось разобрать запрос."
                ])
            }
        }
        throw URLError(.timedOut)
    }

    func createEntity(_ payload: [String: Any]) async -> Int? {
        struct Created: Decodable { let id: Int }
        guard let data = await commandResponse(payload, path: "api/workspace/action") else { return nil }
        do {
            return try decode(Created.self, from: data).id
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    private func commandResponse(_ payload: [String: Any], path: String) async -> Data? {
        guard !saving && !loading else { return nil }
        saving = true
        defer { saving = false }
        do {
            let data = try await request(path, payload: payload)
            await reload()
            return data
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func saveView(name: String, filters: [String: Any], board: Bool) async -> Bool {
        guard savedViewPayloads.count < 50 else {
            error = "Можно сохранить не больше 50 выборок."
            return false
        }
        guard !savedViewPayloads.contains(where: { $0["name"] as? String == name }) else {
            error = "Выборка с таким названием уже есть."
            return false
        }
        let entry: [String: Any] = ["name": name, "filters": filters, "sort": "due", "group": "none", "view": board ? "board" : "list"]
        return await command(["op": "settings", "data": ["saved_views": savedViewPayloads + [entry]]])
    }

    func deleteView(named name: String) async -> Bool {
        let remaining = savedViewPayloads.filter { $0["name"] as? String != name }
        return await command(["op": "settings", "data": ["saved_views": remaining]])
    }

    func updateProject(_ project: Project, changes: [String: Any], migrations: [String: String] = [:]) async -> Bool {
        guard var data = projectPayloads[project.id] else { return false }
        for (key, value) in changes { data[key] = value }
        return await command(["op": "save_project", "id": project.id, "revision": project.revision, "data": data, "migrate_stages": migrations])
    }

    @Published private(set) var lastBatchID: String?

    func updateTasks(_ tasks: [TaskItem], changes: [String: Any]) async -> Bool {
        guard !saving && !loading && !tasks.isEmpty else { return false }
        saving = true
        defer { saving = false }
        do {
            let items: [[String: Any]] = try tasks.map { task in
                guard var data = taskPayloads[task.id] else {
                    throw CocoaError(.fileNoSuchFile)
                }
                for (key, value) in changes { data[key] = value }
                return ["id": task.id, "revision": task.revision, "data": data]
            }
            let data = try await request("api/workspace/action", payload: ["op": "batch_tasks", "items": items])
            struct Batch: Decodable { let batchId: String }
            lastBatchID = try decode(Batch.self, from: data).batchId
            await reload()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func undoBatch() async {
        guard let lastBatchID else { return }
        if await command(["op": "undo_batch", "batch_id": lastBatchID]) {
            self.lastBatchID = nil
        }
    }

    func taskHistory(_ id: Int) async throws -> [TaskHistoryEntry] {
        let data = try await request("api/workspace/action", payload: ["op": "history", "entity": "tasks", "id": id])
        return try decode([TaskHistoryEntry].self, from: data)
    }

    func updateTask(_ task: TaskItem, changes: [String: Any]) async -> Bool {
        guard var data = taskPayloads[task.id] else { return false }
        for (key, value) in changes { data[key] = value }
        return await command(["op": "save_task", "id": task.id, "revision": task.revision, "data": data])
    }

    func voiceStatus() async throws -> VoiceStatus {
        let data = try await request("api/voice/status")
        return try decode(VoiceStatus.self, from: data)
    }

    struct FragmentAssignment: Decodable {
        let assigned: Int
        let jobId: Int?
    }

    func assignTranscriptFragments(_ payload: [String: Any]) async -> FragmentAssignment? {
        guard let data = await commandResponse(payload, path: "api/speaker/assign-fragments") else { return nil }
        do {
            return try decode(FragmentAssignment.self, from: data)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    struct TranscriptVoiceMatchProgress: Decodable {
        let job: VoiceStatus.Data.MatchJob?
        let enrollmentPending: Bool?
    }

    func transcriptVoiceMatchProgress(_ run: Int) async throws -> TranscriptVoiceMatchProgress {
        let data = try await request("api/voice/match/progress", payload: ["model_run_id": run])
        return try decode(TranscriptVoiceMatchProgress.self, from: data)
    }

    func voiceSampleURL(_ id: String) -> URL {
        baseURL.appendingPathComponent("api/voice/capture/audio/" + id)
    }

    func microphoneDevices() async throws -> MicrophoneDevices {
        let data = try await request("api/devices")
        return try decode(MicrophoneDevices.self, from: data)
    }

    func engineSettings() async throws -> EngineSettings {
        let data = try await request("api/status")
        return try decode(EngineSettings.self, from: data)
    }

    func aiBudget() async throws -> AIBudget {
        let data = try await request("api/groq/budget")
        return try decode(AIBudget.self, from: data)
    }

    func personPhotoURL(_ person: Person) -> URL? {
        guard let revision = person.photoRevision else { return nil }
        var url = baseURL.appendingPathComponent("api/people/photo/\(person.id)")
        url.append(queryItems: [URLQueryItem(name: "v", value: String(revision))])
        return url
    }

    func savePersonPhoto(_ photo: Data?, personID: Int) async -> Bool {
        guard !loading && !saving else { return false }
        saving = true
        defer { saving = false }
        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("api/people/photo/\(personID)"), timeoutInterval: 10)
            request.httpMethod = "POST"
            request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
            request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
            request.httpBody = photo ?? Data()
            let (data, response) = try await URLSession.shared.data(for: request)
            try validateResponse(data, response)
            await reload()
            return true
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
            return false
        }
    }

    func recordingURL(_ recording: Recording) -> URL {
        baseURL.appendingPathComponent("api/audio/\(recording.id)")
    }

    func runSpeech(for meeting: Meeting) async {
        let payload = ["meeting_id": meeting.id]
        switch meeting.processing?.status {
        case "running": return
        case "pending": break
        case "failed":
            guard let job = meeting.processing,
                  await command(["id": job.id], path: "api/jobs/retry") else { return }
        default:
            guard await command(payload, path: "api/jobs") else { return }
        }
        await command(payload, path: "api/jobs/run")
    }

    func record(_ action: String, meeting: Meeting, mode: String? = nil) async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            try await updateRecording(action, meetingID: meeting.id, mode: mode)
            error = nil
            if action == "stop" { await reload() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func updateRecording(_ action: String, meetingID: Int, mode: String? = nil) async throws {
        var payload: [String: Any] = ["meeting_id": meetingID]
        if let mode { payload["processing_mode"] = mode }
        let data = try await request("api/recording/" + action, payload: payload)
        var result = try decode(CaptureStatus.self, from: data)
        result.liveDisplay = capture?.liveDisplay
        capture = result
    }

}
