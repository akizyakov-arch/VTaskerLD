import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import Darwin

// One continuous engine; a bounded queue keeps disk IO out of the audio callback.
// Compilation, microphone permissions and hardware behavior require macOS validation.
@main
struct Capture {
    static func main() async {
        do { try await run() }
        catch {
            print("ERROR\t\(String(describing: error).replacingOccurrences(of: "\n", with: " "))")
            fflush(stdout)
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
    static func run() async throws {
        let args = CommandLine.arguments
        if args.count == 2 && args[1] == "--devices" {
            let data = try JSONEncoder().encode(InputDevice.list())
            print(String(decoding: data, as: UTF8.self))
            return
        }
        let testing = args.count > 1 && args[1] == "--test"
        guard (args.count == 3 || args.count == 4), let seconds = Double(args[2]), seconds.isFinite,
              seconds > 0, seconds <= 7200 else {
            throw CaptureError.message("Usage: vtracker-capture OUTPUT_DIRECTORY SECONDS [DEVICE_UID] | --devices | --test SECONDS [DEVICE_UID]")
        }
        let selected = try InputDevice.select(args.count == 4 ? args[3] : nil)
        let directory = URL(fileURLWithPath: args[1], isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        if !testing {
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue, try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else {
                throw CaptureError.message("Output must be an existing empty directory")
            }
        }
        let state = CaptureState()
        DispatchQueue.global(qos: .utility).async {
            while let command = readLine() {
                if command == "pause" { state.setPaused(true) }
                else if command == "resume" { state.setPaused(false) }
                else if command == "stop" { state.requestStop(); return }
            }
            if !testing { state.requestStop() }
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw CaptureError.message("Microphone permission denied; enable access in macOS Privacy & Security")
        }
        guard !state.stopped else { throw CaptureError.message("Capture cancelled") }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        guard let unit = input.audioUnit else { throw CaptureError.message("Microphone audio unit unavailable") }
        var deviceID = selected.id
        let deviceStatus = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard deviceStatus == noErr else { throw CaptureError.message("Cannot select microphone: \(deviceStatus)") }
        let sourceData = try JSONEncoder().encode(selected)
        if !testing { try sourceData.write(to: directory.appendingPathComponent("source.json"), options: .atomic) }
        print("DEVICE\t\(String(decoding: sourceData, as: UTF8.self))")
        fflush(stdout)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            throw CaptureError.message("Unsupported microphone PCM format")
        }
        let writer = testing ? nil : FragmentWriter(directory: directory, format: format)
        let queue = DispatchQueue(label: "vtracker.audio.writer", qos: .userInitiated)
        let slots = DispatchSemaphore(value: 32)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard !state.stopped && !state.paused else { return }
            guard slots.wait(timeout: .now()) == .success else {
                state.fail("Audio writer queue overflow; completed fragments retained")
                return
            }
            guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
                  let source = buffer.floatChannelData, let destination = copy.floatChannelData else {
                slots.signal()
                state.fail("Cannot allocate capture buffer")
                return
            }
            copy.frameLength = buffer.frameLength
            var square: Double = 0
            for frame in 0..<Int(buffer.frameLength) { let value = Double(source[0][frame]); if value.isFinite { square += value * value } }
            state.setLevel(Float(sqrt(square / Double(max(1,buffer.frameLength)))))
            for channel in 0..<Int(format.channelCount) {
                memcpy(destination[channel], source[channel], Int(buffer.frameLength) * MemoryLayout<Float>.size)
            }
            queue.async {
                defer { slots.signal() }
                do { try writer?.append(copy) }
                catch { state.fail("Audio writer failed: \(error)") }
            }
        }
        engine.prepare()
        do { try engine.start() }
        catch { input.removeTap(onBus: 0); throw error }
        let observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                               object: engine, queue: nil) { _ in
            state.requestConfigurationCheck()
        }
        print("CAPABILITIES\tpause,level")
        print("READY")
        fflush(stdout)
        let deadline = Date().addingTimeInterval(seconds)
        var wasPaused = false
        while Date() < deadline && !state.stopped {
            if state.takeConfigurationCheck() {
            // Selecting an input can enqueue a notification even though the stream is healthy.
            // A disconnected device, changed routing/format or stopped engine remains fatal.
            var actualID: AudioDeviceID = 0
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actualID, &size)
            let current = input.outputFormat(forBus: 0)
            let connected = (try? InputDevice.list().contains { $0.uid == selected.uid }) == true
            if status != noErr || actualID != selected.id || !connected || !engine.isRunning ||
               current.sampleRate != format.sampleRate || current.channelCount != format.channelCount {
                state.fail("Audio configuration changed; restart recording after checking the microphone")
            }
            }
            let paused = state.paused
            if paused && !wasPaused { queue.sync { do { try writer?.finish() } catch { state.fail("Audio writer failed: \(error)") } } }
            wasPaused = paused
            print("LEVEL\t\(paused ? 0 : state.level)")
            fflush(stdout)
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        engine.stop()
        input.removeTap(onBus: 0)
        NotificationCenter.default.removeObserver(observer)
        // Finish all accepted buffers, including the short final fragment.
        var writerError: Error?
        queue.sync {
            do { try writer?.finish() } catch { writerError = error }
        }
        if let error = state.error { throw CaptureError.message(error) }
        if let error = writerError { throw error }
    }
}

private final class FragmentWriter {
    private let directory: URL
    private let format: AVAudioFormat
    private let capacity: AVAudioFrameCount
    private var file: AVAudioFile?
    private var frames: AVAudioFrameCount = 0
    private var sequence = 0
    init(directory: URL, format: AVAudioFormat) {
        self.directory = directory
        self.format = format
        self.capacity = AVAudioFrameCount(format.sampleRate * 5) // five seconds
    }
    private var partial: URL { directory.appendingPathComponent(String(format: "%06d.partial.wav", sequence)) }
    private var completed: URL { directory.appendingPathComponent(String(format: "%06d.wav", sequence)) }
    func append(_ buffer: AVAudioPCMBuffer) throws {
        var offset: AVAudioFrameCount = 0
        while offset < buffer.frameLength {
            if file == nil {
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: format.channelCount,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsBigEndianKey: false
                ]
                file = try AVAudioFile(forWriting: partial, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            }
            let count = min(capacity - frames, buffer.frameLength - offset)
            guard let slice = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
                  let source = buffer.floatChannelData, let destination = slice.floatChannelData else {
                throw CaptureError.message("Cannot allocate writer buffer")
            }
            slice.frameLength = count
            for channel in 0..<Int(format.channelCount) {
                memcpy(destination[channel], source[channel].advanced(by: Int(offset)), Int(count) * MemoryLayout<Float>.size)
            }
            try file!.write(from: slice)
            offset += count
            frames += count
            if frames == capacity { try finish() }
        }
    }
    func finish() throws {
        guard file != nil, frames > 0 else { return }
        file = nil // close AVAudioFile and finalize WAV header before publication
        let handle = try FileHandle(forWritingTo: partial)
        try handle.synchronize()
        try handle.close()
        guard !FileManager.default.fileExists(atPath: completed.path) else {
            throw CaptureError.message("Fragment already exists")
        }
        try FileManager.default.moveItem(at: partial, to: completed)
        let fd = Darwin.open(directory.path, O_RDONLY)
        guard fd >= 0 else { throw CaptureError.message("Cannot open audio directory for sync") }
        defer { Darwin.close(fd) }
        guard Darwin.fsync(fd) == 0 else { throw CaptureError.message("Cannot sync audio directory") }
        sequence += 1
        frames = 0
    }
}
private final class CaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var stop = false
    private var failure: String?
    private var configurationChanged = false
    func requestConfigurationCheck() { lock.lock(); defer { lock.unlock() }; configurationChanged = true }
    func takeConfigurationCheck() -> Bool { lock.lock(); defer { lock.unlock() }; let changed = configurationChanged; configurationChanged = false; return changed }
    private var pause = false
    private var currentLevel: Float = 0
    var paused: Bool { lock.lock(); defer { lock.unlock() }; return pause }
    var level: Float { lock.lock(); defer { lock.unlock() }; return currentLevel }
    func setPaused(_ value: Bool) { lock.lock(); defer { lock.unlock() }; pause = value }
    func setLevel(_ value: Float) { lock.lock(); defer { lock.unlock() }; currentLevel = value }
    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return stop }
    var error: String? { lock.lock(); defer { lock.unlock() }; return failure }
    func requestStop() { lock.lock(); defer { lock.unlock() }; stop = true }
    func fail(_ message: String) { lock.lock(); defer { lock.unlock() }; failure = failure ?? message; stop = true }
}
private enum CaptureError: Error { case message(String) }
