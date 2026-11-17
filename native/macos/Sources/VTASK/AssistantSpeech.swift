import AVFoundation
import SwiftUI

enum AssistantReplyVoice: String, CaseIterable, Identifiable {
    case irina, dmitri, system

    static let preferenceKey = "assistantReplyVoice"
    var id: Self { self }

    var title: String {
        switch self {
        case .irina: return "Ирина · женский"
        case .dmitri: return "Дмитрий · мужской"
        case .system: return "Системный голос macOS"
        }
    }

    var modelName: String? {
        self == .system ? nil : "ru_RU-\(rawValue)-medium"
    }
}

@MainActor
final class AssistantSpeech: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    @Published private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()
    private var current: AVSpeechUtterance?
    private var synthesis: Process?
    private var player: AVAudioPlayer?
    private var timeout: Task<Void, Never>?

    private let piperDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/vtracker/tts/piper-irina", isDirectory: true)

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, voice: AssistantReplyVoice? = nil) {
        let selected = voice ?? UserDefaults.standard.string(forKey: AssistantReplyVoice.preferenceKey)
            .flatMap(AssistantReplyVoice.init(rawValue:)) ?? .irina
        stop()
        if let model = selected.modelName, startPiper(text, modelName: model, voice: selected) { return }
        speakWithSystemVoice(text, voice: selected)
    }

    private func startPiper(_ text: String, modelName: String, voice: AssistantReplyVoice) -> Bool {
        let files = FileManager.default
        let directoryName = "vits-piper-\(modelName)"
        let local = (piperDirectory.appendingPathComponent("runtime/bin/python"),
                     piperDirectory.appendingPathComponent(directoryName, isDirectory: true))
        let bundled = Bundle.main.resourceURL.map { resources in
            let runtime = resources.appendingPathComponent("runtime", isDirectory: true)
            return (runtime.appendingPathComponent("python/bin/python3"),
                    runtime.appendingPathComponent("voices/\(directoryName)", isDirectory: true))
        }
        let locations = [local] + (bundled.map { [$0] } ?? [])
        guard let (executable, model) = locations.first(where: { executable, model in
            files.isExecutableFile(atPath: executable.path) &&
                files.fileExists(atPath: model.appendingPathComponent("\(modelName).onnx").path)
        }), let script = Bundle.main.url(forResource: "piper-irina", withExtension: "py", subdirectory: "scripts") else {
            return false
        }

        let scratch = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let input = scratch.appendingPathComponent("reply.txt")
        let output = scratch.appendingPathComponent("reply.wav")
        let process = Process()
        process.executableURL = executable
        process.arguments = [script.path, model.path, input.path, output.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            let id = ObjectIdentifier(finished)
            let succeeded = finished.terminationStatus == 0
            Task { @MainActor in
                defer { try? FileManager.default.removeItem(at: scratch) }
                guard let self, let synthesis = self.synthesis, ObjectIdentifier(synthesis) == id else { return }
                self.synthesis = nil
                self.timeout?.cancel()
                self.timeout = nil
                if succeeded, let audio = try? Data(contentsOf: output),
                   let player = try? AVAudioPlayer(data: audio) {
                    player.delegate = self
                    self.player = player
                    if player.play() { return }
                    self.player = nil
                }
                self.speakWithSystemVoice(text, voice: voice)
            }
        }
        do {
            try files.createDirectory(at: scratch, withIntermediateDirectories: false,
                                      attributes: [.posixPermissions: 0o700])
            try Data(text.utf8).write(to: input)
            try process.run()
            synthesis = process
            isSpeaking = true
            timeout = Task { [weak self, weak process] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let self, let process, synthesis === process else { return }
                stop()
                speakWithSystemVoice(text, voice: voice)
            }
            return true
        } catch {
            try? files.removeItem(at: scratch)
            return false
        }
    }

    private func speakWithSystemVoice(_ text: String, voice: AssistantReplyVoice) {
        let utterance = AVSpeechUtterance(string: text)
        let russianVoices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("ru") }
        let candidates = voice == .dmitri ? russianVoices.filter { $0.gender == .male } : russianVoices
        let best = candidates.max { $0.quality.rawValue < $1.quality.rawValue }
        if voice == .dmitri && best == nil {
            isSpeaking = false
            return
        }
        utterance.voice = best ?? AVSpeechSynthesisVoice(language: "ru-RU")
        current = utterance
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        timeout?.cancel()
        timeout = nil
        let process = synthesis
        synthesis = nil
        if let process, process.isRunning { process.terminate() }
        player?.stop()
        player = nil
        current = nil
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        playbackEnded(ObjectIdentifier(utterance))
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        playbackEnded(ObjectIdentifier(utterance))
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        audioEnded(ObjectIdentifier(player))
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        audioEnded(ObjectIdentifier(player))
    }

    private nonisolated func audioEnded(_ id: ObjectIdentifier) {
        Task { @MainActor in
            guard let player, ObjectIdentifier(player) == id else { return }
            self.player = nil
            isSpeaking = false
        }
    }

    private nonisolated func playbackEnded(_ id: ObjectIdentifier) {
        Task { @MainActor in
            guard let current, ObjectIdentifier(current) == id else { return }
            self.current = nil
            isSpeaking = false
        }
    }
}
