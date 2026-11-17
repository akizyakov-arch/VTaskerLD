import AVFoundation
import Speech
import SwiftUI

enum AssistantVoicePreferences {
    static let speakRepliesKey = "assistantSpeakReplies"
    static let silenceKey = "assistantVoiceSilenceMilliseconds"
    static let defaultSilence = 1400
    static let silenceRange = 500...5000
}

@MainActor
final class VoiceSearch: ObservableObject {
    @Published private(set) var listening = false
    @Published private(set) var preparing = false
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
    private var lastSpeech = ContinuousClock.now

    func start(silenceMilliseconds: Int) async {
        guard !preparing && !listening else { return }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            error = "Локальное распознавание русского языка недоступно."
            return
        }
        preparing = true
        error = nil
        let session = UUID()
        generation = session
        defer { if generation == session { preparing = false } }

        let speechAccess = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard generation == session else { return }
        guard speechAccess == .authorized else {
            error = "Разрешите распознавание речи в настройках macOS."
            return
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
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.request = request
        text = ""
        completedText = nil
        lastSpeech = .now
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            let count = Int(buffer.frameLength)
            var energy: Float = 0
            for index in 0..<count {
                let sample = samples[index * buffer.stride]
                energy += sample * sample
            }
            guard energy / Float(count) > 0.0001 else { return }
            let timestamp = ContinuousClock.now
            Task { @MainActor [weak self] in
                guard let self, generation == session else { return }
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
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, failure in
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
                    error = failure.localizedDescription
                    stop()
                }
            }
        }
        let range = AssistantVoicePreferences.silenceRange
        let silenceDelay = Duration.milliseconds(min(max(silenceMilliseconds, range.lowerBound), range.upperBound))
        silenceMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, generation == session else { return }
                if !text.isEmpty && lastSpeech.duration(to: .now) >= silenceDelay {
                    finish()
                    return
                }
            }
        }
    }

    private func finish() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        stop()
        if !message.isEmpty { completedText = message }
    }

    func stop() {
        silenceMonitor?.cancel()
        silenceMonitor = nil
        generation = UUID()
        preparing = false
        listening = false
        if inputTapInstalled {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        request?.endAudio()
        recognition?.cancel()
        request = nil
        recognition = nil
    }
}
