import SwiftUI

struct LiveTranscript: Decodable {
    struct Chunk: Decodable, Identifiable {
        struct Segment: Decodable {
            let text: String
            let speakerId: String?
            let startMs: Int?
            let endMs: Int?

            var line: String {
                guard let speakerId, let index = Int(speakerId.replacingOccurrences(of: "speaker_", with: "")) else { return text }
                return "Голос \(index + 1) · \(text)"
            }
        }
        let id: Int
        let sequence: Int
        let lastSequence: Int?
        let startMs: Int?
        let endMs: Int?
        let state: String
        let error: String?
        let segments: [Segment]
    }

    struct AIPreview: Decodable {
        let running: Bool
        let error: String?
        let result: MeetingAnalysis.Result?
    }

    let aiPreview: AIPreview?
    let sessionId: String?
    let state: String
    let reason: String?
    let chunks: [Chunk]
}

struct LiveCommandClip: Equatable {
    let sessionID: String
    let start: Int
    var end: Int?

    enum Result: Equatable {
        case waiting, unavailable, ready(String)
    }

    func read(_ transcript: LiveTranscript?) -> Result {
        guard let end, let transcript, transcript.sessionId == sessionID else { return .waiting }
        let covering = transcript.chunks.filter { ($0.startMs ?? end) < end && ($0.endMs ?? start) > start }
            .sorted { ($0.startMs ?? 0) < ($1.startMs ?? 0) }
        if covering.contains(where: { ["deferred", "failed"].contains($0.state) }) { return .unavailable }
        guard covering.last?.endMs ?? 0 >= end, covering.allSatisfy({ $0.state == "completed" }) else {
            return .waiting
        }
        var through = start
        for chunk in covering {
            guard let from = chunk.startMs, let to = chunk.endMs, from <= through + 50 else { return .unavailable }
            through = max(through, to)
        }
        let fragments = covering.flatMap(\.segments).filter {
            guard let from = $0.startMs, let to = $0.endMs else { return false }
            return min(to, end) - max(from, start) >= min(250, max(1, to - from))
        }
        return .ready(fragments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

struct LiveTranscriptView: View {
    @ObservedObject var model: WorkspaceModel
    let meetingID: Int
    @State private var preview: LiveTranscript?
    @State private var error: String?
    @State private var confirmingRecovery = false
    @State private var refresh = 0

    private var recording: Bool { model.capture?.active?.meetingId == meetingID }

    var body: some View {
        Group {
            if let preview {
                let chunks = preview.chunks.filter { $0.state == "completed" }
                let count = chunks.reduce(0) { $0 + $1.segments.count }
                Section {
                    DisclosureGroup("Предварительный протокол · \(count) фрагментов", isExpanded: $expanded) {
                        Text(preview.reason ?? (preview.state == "active"
                             ? "Ожидаем новые фрагменты записи."
                             : "Live завершён. Аудио доступно для полной обработки."))
                            .foregroundStyle(.secondary)
                        if let failure = preview.chunks.compactMap(\.error).first {
                            Text(failure).foregroundStyle(.red)
                        }
                        if model.capture != nil && model.capture?.active == nil
                            && ["active", "interrupted"].contains(preview.state) {
                            Button("Восстановить очередь Live") { confirmingRecovery = true }
                                .disabled(model.saving)
                        }
                        ForEach(chunks) { chunk in
                            Text(chunk.segments.map(\.line).joined(separator: "\n")).textSelection(.enabled)
                        }
                    }
                }
            } else if recording && error == nil {
                Text("Предварительный протокол доступен при записи в режиме Live.").foregroundStyle(.secondary)
            }
            if let error {
                Text(error).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Прежний процесс Live остановлен?", isPresented: $confirmingRecovery) {
            Button("Подтвердить и восстановить") {
                Task {
                    if await model.command(["meeting_id": meetingID, "confirmed_stopped": true], path: "api/live/recover") {
                        refresh += 1
                    }
                }
            }
        }
        .task(id: [recording ? 1 : 0, refresh]) {
            if recording { expanded = true }
            repeat {
                do {
                    let latest = try await model.liveTranscript(for: meetingID)
                    guard !Task.isCancelled else { return }
                    preview = latest
                    error = nil
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    self.error = error.localizedDescription
                }
                guard recording || preview?.state == "active" || preview?.chunks.contains(where: { ["pending", "running"].contains($0.state) }) == true else { return }
                try? await Task.sleep(for: .seconds(3))
            } while !Task.isCancelled
        }
    }

    @State private var expanded = false
}
