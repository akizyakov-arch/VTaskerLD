import AVFoundation
import Speech

@available(macOS 26.0, *)
enum AppleSpeechAnalyzer {
    enum Module {
        case transcription(SpeechTranscriber)
        case dictation(DictationTranscriber)

        var speechModule: any SpeechModule {
            switch self {
            case .transcription(let transcriber): return transcriber
            case .dictation(let transcriber): return transcriber
            }
        }

        var usesDictation: Bool {
            if case .dictation = self { return true }
            return false
        }
    }

    private enum Failure: LocalizedError {
        case unsupported, modelMissing, invalidAudio

        var errorDescription: String? {
            switch self {
            case .unsupported: return "SpeechAnalyzer недоступен для русского языка на этом Mac."
            case .modelMissing: return "Загрузите модель SpeechAnalyzer в настройках ассистента."
            case .invalidAudio: return "Не удалось прочитать запись команды для SpeechAnalyzer."
            }
        }
    }

    static func russianModule() async throws -> Module {
        let russian = Locale(identifier: "ru-RU")
        // The general transcriber can return an equivalent locale that has no downloadable asset.
        if SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocales.first(where: { $0.language.languageCode == russian.language.languageCode }) {
            return .transcription(SpeechTranscriber(locale: locale, preset: .transcription))
        }
        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: russian),
           locale.language.languageCode == russian.language.languageCode {
            return .dictation(DictationTranscriber(locale: locale, preset: .shortDictation))
        }
        throw Failure.unsupported
    }

    static func isInstalled(_ module: Module) async -> Bool {
        if await AssetInventory.status(forModules: [module.speechModule]) == .installed { return true }
        // macOS may report the asset as supported even when the dictation locale is installed.
        guard case .dictation(let transcriber) = module else { return false }
        let available = await DictationTranscriber.installedLocales
        return transcriber.selectedLocales.allSatisfy { locale in
            available.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
        }
    }

    static func install(_ module: Module) async throws {
        if await isInstalled(module) { return }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module.speechModule]) {
            try await request.downloadAndInstall()
        }
        guard await isInstalled(module) else {
            throw Failure.modelMissing
        }
    }

    static func installedModule() async throws -> Module {
        let module = try await russianModule()
        guard await isInstalled(module) else {
            throw Failure.modelMissing
        }
        return module
    }

    static func transcribe(_ pcm: Data, sampleRate: Int, module: Module) async throws -> String {
        let frames = pcm.count / MemoryLayout<Int16>.size
        guard frames > 0, frames * MemoryLayout<Int16>.size == pcm.count,
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate),
                                         channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.int16ChannelData?[0] else {
            throw Failure.invalidAudio
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.copyBytes(to: UnsafeMutableRawBufferPointer(start: channel, count: pcm.count))

        guard let compatible = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module.speechModule],
                                                                            considering: format) else {
            throw Failure.invalidAudio
        }
        let input = try convert(buffer, to: compatible)
        switch module {
        case .dictation(let transcriber):
            return try await analyze(input, module: transcriber) { $0.text }
        case .transcription(let transcriber):
            return try await analyze(input, module: transcriber) { $0.text }
        }
    }

    private static func convert(_ input: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if input.format == format { return input }
        let capacity = ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate) + 256
        guard let converter = AVAudioConverter(from: input.format, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(capacity)) else {
            throw Failure.invalidAudio
        }
        var pending: AVAudioPCMBuffer? = input
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, status in
            guard let buffer = pending else {
                status.pointee = .endOfStream
                return nil
            }
            pending = nil
            status.pointee = .haveData
            return buffer
        }
        if let conversionError { throw conversionError }
        guard status != .error, output.frameLength > 0 else { throw Failure.invalidAudio }
        return output
    }

    private static func analyze<Module: SpeechModule>(_ audio: AVAudioPCMBuffer, module: Module,
                                                        text: @escaping @Sendable (Module.Result) -> AttributedString) async throws -> String {
        let analyzer = SpeechAnalyzer(modules: [module])
        let input = AsyncStream.makeStream(of: AnalyzerInput.self)
        input.continuation.yield(AnalyzerInput(buffer: audio))
        input.continuation.finish()
        let results = Task {
            var pieces: [String] = []
            // Both presets disable volatile results. Dictation can leave the last
            // result unmarked at the end of a finite input.
            for try await result in module.results {
                let phrase = String(text(result).characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !phrase.isEmpty { pieces.append(phrase) }
            }
            return pieces.joined(separator: " ")
        }
        defer { results.cancel() }
        return try await withTaskCancellationHandler {
            do {
                if try await analyzer.analyzeSequence(input.stream) != nil {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                } else {
                    await analyzer.cancelAndFinishNow()
                    return ""
                }
                return try await results.value
            } catch {
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            results.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}
