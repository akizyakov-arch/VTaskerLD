import SwiftUI

struct LiveTranscript: Decodable {
    struct Chunk: Decodable, Identifiable {
        struct Segment: Decodable {
            let text: String
            let speakerId: String?

            var line: String {
                guard let speakerId, let index = Int(speakerId.replacingOccurrences(of: "speaker_", with: "")) else { return text }
                return "Голос \(index + 1) · \(text)"
            }
        }
        let id: Int
        let sequence: Int
        let lastSequence: Int?
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

struct LiveAssistantCommands {
    private var seen: Set<Int> = []
    private var partial: String?
    private var lastSequence: Int?

    mutating func read(_ chunks: [LiveTranscript.Chunk]) -> [String] {
        var commands: [String] = []
        for chunk in chunks where chunk.state == "completed" && seen.insert(chunk.id).inserted {
            if lastSequence != chunk.sequence - 1 { partial = nil }
            lastSequence = chunk.lastSequence ?? chunk.sequence
            for segment in chunk.segments {
                for sentence in segment.text.split(whereSeparator: { ".!?…\n".contains($0) }) {
                    let phrase = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                    let candidate: String
                    if let wake = phrase.range(of: #"^[«“"]?валли\b[\s,–—:-]*"#,
                                               options: [.regularExpression, .caseInsensitive]) {
                        candidate = String(phrase[wake.upperBound...])
                    } else if let partial {
                        candidate = partial.isEmpty ? phrase : partial + " " + phrase
                    } else {
                        continue
                    }
                    partial = nil
                    if candidate.isEmpty {
                        partial = candidate
                    } else if candidate.range(of: #"^(?:найди|найдите|покажи|покажите|открой|откройте|выведи)\b"#,
                                              options: [.regularExpression, .caseInsensitive]) != nil {
                        if candidate.range(of: #"\bзадач(?:а|у|и|е|ей|ам|ами|ах)?\b"#,
                                           options: [.regularExpression, .caseInsensitive]) != nil {
                            commands.append(candidate)
                        } else if candidate.split(separator: " ").count <= 3 {
                            partial = candidate
                        }
                    }
                }
            }
        }
        return commands
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
