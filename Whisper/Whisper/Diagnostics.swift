import Foundation
import os

nonisolated let log = Logger(subsystem: "soli.whisper.Whisper", category: "dictation")

nonisolated final class MainThreadWatchdog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "soli.whisper.watchdog", qos: .utility)
    private let lock = NSLock()
    private let stallSeconds: Double = 10
    private var timer: DispatchSourceTimer?
    private var lastBeat = DispatchTime.now()
    private var stalled = false

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        DispatchQueue.main.async { [weak self] in self?.beat() }
        let silentFor = lock.withLock { Double(DispatchTime.now().uptimeNanoseconds - lastBeat.uptimeNanoseconds) / 1_000_000_000 }
        if silentFor > stallSeconds, !stalled {
            stalled = true
            log.fault("main thread unresponsive for \(Int(silentFor), privacy: .public)s, capturing sample")
            captureSample()
        } else if silentFor < 2, stalled {
            stalled = false
            log.notice("main thread responsive again")
        }
    }

    private func beat() {
        lock.withLock { lastBeat = DispatchTime.now() }
    }

    private func captureSample() {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Whisper", isDirectory: true)
        let file = directory.appendingPathComponent("hang-\(Date().formatted(.iso8601.dateSeparator(.dash).timeSeparator(.omitted))).txt")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), "3", "-file", file.path]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try process.run()
            log.fault("hang sample: \(file.path, privacy: .public)")
        } catch {
            log.error("hang sample failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
