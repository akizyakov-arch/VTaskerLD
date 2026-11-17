import Foundation

enum LocalCore {
    static var startupError: NSError {
        NSError(domain: "VTASK", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Ядро VTASK не запустилось. Подробности в core.log в папке Application Support/VTracker."
        ])
    }

    static func start(
        bundle: Bundle = .main,
        dataDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VTracker", isDirectory: true),
        port: Int = 8765
    ) throws -> Process {
        guard let resources = bundle.resourceURL, let executable = bundle.executableURL else {
            throw startupError
        }
        let binaries = executable.deletingLastPathComponent()
        let core = binaries.appendingPathComponent("vtracker")
        let capture = binaries.appendingPathComponent("vtracker-capture")
        let launcher = resources.appendingPathComponent("scripts/start-macos.sh")
        guard FileManager.default.isExecutableFile(atPath: core.path),
              FileManager.default.isExecutableFile(atPath: capture.path),
              FileManager.default.isReadableFile(atPath: launcher.path) else {
            throw startupError
        }

        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let logURL = dataDirectory.appendingPathComponent("core.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            try Data().write(to: logURL, options: .withoutOverwriting)
        }
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        try log.seekToEnd()

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["VTRACKER_PORT"] = String(port)
        environment["VTRACKER_CORE_BIN"] = core.path
        environment["VTRACKER_CAPTURE_BIN"] = capture.path
        environment["VTRACKER_GROQ_HELPER"] = resources.appendingPathComponent("scripts/groq-analyze.py").path
        for (name, key) in [("vtracker-diarize", "VTRACKER_DIARIZATION_BIN"), ("vtracker-embed", "VTRACKER_EMBED_BIN"), ("vtracker-whisper-worker", "VTRACKER_WHISPER_WORKER"), ("vtracker-speaker-worker", "VTRACKER_SPEAKER_WORKER")] {
            let helper = binaries.appendingPathComponent(name)
            if environment[key] == nil && FileManager.default.isExecutableFile(atPath: helper.path) {
                environment[key] = helper.path
                if name == "vtracker-diarize" && environment["VTRACKER_CLUSTER_THRESHOLD"] == nil {
                    environment["VTRACKER_CLUSTER_THRESHOLD"] = "0.8"
                }
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [launcher.path, "--db", dataDirectory.appendingPathComponent("data.sqlite3").path]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        try process.run()
        return process
    }
}
