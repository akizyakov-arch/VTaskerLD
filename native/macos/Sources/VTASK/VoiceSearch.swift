import AVFoundation
import Speech
import SwiftUI

enum AssistantRecognitionEngine: String, CaseIterable, Identifiable {
    case macOS, whisper, speechAnalyzer

    var id: Self { self }

    var title: String {
        switch self {
        case .macOS: return "macOS"
        case .whisper: return "Whisper"
        case .speechAnalyzer: return "SpeechAnalyzer"
        }
    }
}

private final class AssistantAudioBuffer: @unchecked Sendable {
    let sampleRate: Int
    private let lock = NSLock()
    private var pcm = Data()
    static let limitSeconds = 30

    init(sampleRate: Int) { self.sampleRate = sampleRate }

    func append(_ samples: UnsafePointer<Float>, count: Int, stride: Int) {
        lock.lock()
        defer { lock.unlock() }
        let available = sampleRate * Self.limitSeconds - pcm.count / 2
        let length = min(available, count)
        guard length > 0 else { return }
        let frame = (0..<length).map { index -> Int16 in
            let value = samples[index * stride]
            guard value.isFinite else { return 0 }
            return Int16(min(1, max(-1, value)) * Float(Int16.max)).littleEndian
        }
        frame.withUnsafeBytes { pcm.append(contentsOf: $0) }
    }

    func data() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return pcm
    }
}

enum AssistantVoicePreferences {
    static let speakRepliesKey = "assistantSpeakReplies"
    static let engineKey = "assistantRecognitionEngine"
    static let silenceKey = "assistantVoiceSilenceMilliseconds"
    static let defaultSilence = 1400
    static let silenceRange = 500...5000
}

@MainActor
final class VoiceSearch: ObservableObject {
    @Published private(set) var listening = false
    @Published private(set) var preparing = false
    @Published private(set) var transcribing = false
    @Published private(set) var needsRepeat = false
    @Published private(set) var text = ""
    @Published private(set) var completedText: String?
    @Published private(set) var error: String?

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var generation = UUID()
    private var inputTapInstalled = false
    private var silenceMonitor: Task<Void, Never>?
    private var heardSpeech = false
    private var lastSpeech = ContinuousClock.now

    func start(silenceMilliseconds: Int, recognitionEngine: AssistantRecognitionEngine,
               transcribe: @escaping (Data, Int) async throws -> String) async {
        guard !preparing && !listening else { return }
        clearFeedback()
        let apple = recognitionEngine == .macOS ? recognizer : nil
        if recognitionEngine == .macOS && (apple?.isAvailable != true || apple?.supportsOnDeviceRecognition != true) {
            error = "Локальное распознавание русского языка недоступно."
            return
        }
        preparing = true
        let session = UUID()
        generation = session
        defer { if generation == session { preparing = false } }

        if apple != nil {
            let speechAccess = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard generation == session else { return }
            guard speechAccess == .authorized else {
                error = "Разрешите распознавание речи в настройках macOS."
                return
            }
        }
        let recognizeAudio: (Data, Int) async throws -> String
        if recognitionEngine == .speechAnalyzer {
            guard #available(macOS 26.0, *) else {
                error = "Для SpeechAnalyzer требуется macOS 26."
                return
            }
            do {
                let module = try await AppleSpeechAnalyzer.installedModule()
                recognizeAudio = { data, rate in
                    try await AppleSpeechAnalyzer.transcribe(data, sampleRate: rate, module: module)
                }
            } catch {
                if generation == session { self.error = error.localizedDescription }
                return
            }
            guard generation == session else { return }
        } else {
            recognizeAudio = transcribe
        }
        let microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard generation == session else { return }
        guard microphoneAllowed else {
            error = "Разрешите VTASK доступ к микрофону в настройках macOS."
            return
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 && format.channelCount > 0 else {
            error = "Микрофон недоступен."
            return
        }
        let request = apple.map { _ in SFSpeechAudioBufferRecognitionRequest() }
        request?.requiresOnDeviceRecognition = true
        request?.shouldReportPartialResults = true
        self.request = request
        let audio = recognitionEngine != .macOS ? AssistantAudioBuffer(sampleRate: Int(format.sampleRate)) : nil
        let started = ContinuousClock.now
        heardSpeech = false
        text = ""
        completedText = nil
        lastSpeech = .now
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request?.append(buffer)
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            let count = Int(buffer.frameLength)
            audio?.append(samples, count: count, stride: buffer.stride)
            var energy: Float = 0
            for index in 0..<count {
                let sample = samples[index * buffer.stride]
                energy += sample * sample
            }
            guard energy / Float(count) > 0.0001 else { return }
            let timestamp = ContinuousClock.now
            Task { @MainActor [weak self] in
                guard let self, generation == session else { return }
                heardSpeech = true
                lastSpeech = max(lastSpeech, timestamp)
            }
        }
        inputTapInstalled = true
        do {
            try engine.start()
        } catch {
            self.error = error.localizedDescription
            stop()
            return
        }
        listening = true
        if let apple, let request {
            recognition = apple.recognitionTask(with: request) { [weak self] result, failure in
                Task { @MainActor [weak self] in
                    guard let self, generation == session else { return }
                    if let result {
                        let recognized = result.bestTranscription.formattedString
                        if recognized != text {
                            text = recognized
                            lastSpeech = .now
                        }
                    }
                    if result?.isFinal == true {
                        finish()
                    } else if let failure {
                        needsRepeat = text.isEmpty
                        error = failure.localizedDescription
                        stop()
                    }
                }
            }
        }
        let range = AssistantVoicePreferences.silenceRange
        let silenceDelay = Duration.milliseconds(min(max(silenceMilliseconds, range.lowerBound), range.upperBound))
        silenceMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, generation == session else { return }
                if let audio {
                    let elapsed = started.duration(to: .now)
                    let reachedLimit = elapsed >= .seconds(AssistantAudioBuffer.limitSeconds)
                    guard reachedLimit || (heardSpeech && lastSpeech.duration(to: .now) >= silenceDelay) else { continue }
                    endInput()
                    if heardSpeech {
                        transcribing = true
                        do {
                            let recognized = try await recognizeAudio(audio.data(), audio.sampleRate)
                            guard generation == session, !Task.isCancelled else { return }
                            text = recognized
                            if text.isEmpty {
                                needsRepeat = true
                                error = "\(recognitionEngine.title) не распознал голосовую команду."
                            }
                        } catch {
                            guard generation == session, !Task.isCancelled else { return }
                            self.error = error.localizedDescription
                        }
                    } else {
                        needsRepeat = true
                        error = "Голос не обнаружен."
                    }
                    finish()
                    return
                }
                if !text.isEmpty && lastSpeech.duration(to: .now) >= silenceDelay {
                    endInput()
                    transcribing = true
                    recognition?.finish()
                    // The recognizer can still revise words after the microphone stops.
                    do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
                    guard generation == session else { return }
                    error = "Распознавание не завершилось. Проверьте текст в поле и отправьте его вручную."
                    stop()
                    return
                }
            }
        }
    }

    private func finish() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        recognition = nil
        stop()
        if !message.isEmpty { completedText = message }
    }

    func clearFeedback() {
        needsRepeat = false
        error = nil
    }

    func stop() {
        silenceMonitor?.cancel()
        silenceMonitor = nil
        generation = UUID()
        preparing = false
        listening = false
        transcribing = false
        endInput()
        recognition?.cancel()
        recognition = nil
    }

    private func endInput() {
        if inputTapInstalled {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        request?.endAudio()
        request = nil
    }
}
