import AVFoundation
import CoreAudio
import os
import Speech

enum SpeechModuleKind: String, CaseIterable {
    case transcriber
    case dictation

    var title: String {
        self == .transcriber ? "Apple Transcriber (best punctuation)" : "Apple Dictation (custom words)"
    }

    func makeModule(locale: Locale) -> any LocaleDependentSpeechModule {
        self == .transcriber
            ? SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
            : DictationTranscriber(locale: locale, contentHints: [.shortForm], transcriptionOptions: [.punctuation], reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
    }

    func supportedLocale(for code: String) async -> Locale? {
        self == .transcriber
            ? await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: code))
            : await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: code))
    }
}

struct SpeechResult {
    let text: String
    let isFinal: Bool
}

func speechResults(of module: any SpeechModule) -> AsyncStream<SpeechResult> {
    AsyncStream { continuation in
        let task = Task {
            do {
                if let transcriber = module as? SpeechTranscriber {
                    for try await result in transcriber.results {
                        continuation.yield(SpeechResult(text: String(result.text.characters), isFinal: result.isFinal))
                    }
                } else if let dictation = module as? DictationTranscriber {
                    for try await result in dictation.results {
                        continuation.yield(SpeechResult(text: String(result.text.characters), isFinal: result.isFinal))
                    }
                }
            } catch {
                log.error("speech results failed: \(error.localizedDescription, privacy: .public)")
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

final class Transcript {
    private var confirmed = ""
    private var volatile = ""

    var text: String { (confirmed + volatile).trimmingCharacters(in: .whitespacesAndNewlines) }

    func add(_ result: SpeechResult) {
        if result.isFinal {
            confirmed += result.text
            volatile = ""
        } else {
            volatile = result.text
        }
    }
}

struct Dictation {
    let analyzer: SpeechAnalyzer
    let input: AsyncStream<AnalyzerInput>.Continuation
    let results: Task<Void, Never>
    let transcript: Transcript
}

struct InputDevice {
    let id: AudioDeviceID
    let name: String
}

enum InputDevices {
    static func all() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
        return ids
            .filter { inputChannelCount($0) > 0 }
            .map { InputDevice(id: $0, name: name($0)) }
            .filter { !$0.name.hasPrefix("CADefaultDeviceAggregate") }
    }

    static func id(named name: String?) -> AudioDeviceID? {
        all().first { $0.name == name }?.id
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, list)
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func name(_ id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name)
        return name?.takeRetainedValue() as String? ?? "Unknown"
    }
}

struct MicrophoneUnavailable: Error {}

final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var frames: [Int16] = []
    private var configurationObserver: NSObjectProtocol?

    var capturedFrames: [Int16] { lock.withLock { frames } }

    func start(deviceID: AudioDeviceID?, format: AVAudioFormat, onFailure: @escaping @Sendable () -> Void, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        if var deviceID, let unit = engine.inputNode.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        try run(format: format, onBuffer: onBuffer)
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            log.notice("audio input changed mid-recording, restarting capture")
            self?.engine.inputNode.removeTap(onBus: 0)
            if (try? self?.run(format: format, onBuffer: onBuffer)) == nil { onFailure() }
        }
    }

    private func run(format: AVAudioFormat, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0, let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw MicrophoneUnavailable()
        }
        let ratio = format.sampleRate / inputFormat.sampleRate
        engine.inputNode.installTap(onBus: 0, bufferSize: 2400, format: inputFormat) { [weak self] buffer, _ in
            let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16)!
            var consumed = false
            converter.convert(to: converted, error: nil) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            self?.append(converted)
            onBuffer(converted)
        }
        try engine.start()
    }

    func stop() {
        configurationObserver.map(NotificationCenter.default.removeObserver)
        configurationObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        let count = Int(buffer.frameLength)
        let samples: [Int16]
        if let data = buffer.int16ChannelData {
            samples = Array(UnsafeBufferPointer(start: data[0], count: count))
        } else if let data = buffer.floatChannelData {
            samples = UnsafeBufferPointer(start: data[0], count: count).map { Int16(max(-1, min(1, $0)) * 32767) }
        } else {
            return
        }
        lock.withLock { frames.append(contentsOf: samples) }
    }
}

nonisolated struct CorpusEntry: Encodable, Sendable {
    let timestamp: String
    let module: String
    let locale: String
    let durationSeconds: Double
    let releaseToFinalMs: Int
    let rawText: String
    let text: String
    let targetApp: String
    let osVersion: String
}

nonisolated enum Corpus {
    static var directory: URL? {
        UserDefaults.standard.string(forKey: "corpusDirectory").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func save(frames: [Int16], sampleRate: Double, entry: CorpusEntry) {
        guard let root = directory, !frames.isEmpty else { return }
        guard FileManager.default.fileExists(atPath: root.path) else {
            log.notice("corpus directory not mounted, skipping")
            return
        }
        let monthDirectory = root.appendingPathComponent(String(entry.timestamp.prefix(7)), isDirectory: true)
        let base = monthDirectory.appendingPathComponent(entry.timestamp)
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames.count))!
        buffer.frameLength = AVAudioFrameCount(frames.count)
        frames.withUnsafeBufferPointer { buffer.int16ChannelData![0].update(from: $0.baseAddress!, count: frames.count) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: monthDirectory, withIntermediateDirectories: true)
            try AVAudioFile(forWriting: base.appendingPathExtension("wav"), settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: false).write(from: buffer)
            try encoder.encode(entry).write(to: base.appendingPathExtension("json"))
        } catch {
            log.error("corpus write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

nonisolated func readAudioFile(_ url: URL, as format: AVAudioFormat) throws -> AVAudioPCMBuffer {
    let file = try AVAudioFile(forReading: url)
    let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: source)
    let converter = AVAudioConverter(from: file.processingFormat, to: format)!
    let ratio = format.sampleRate / file.processingFormat.sampleRate
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(source.frameLength) * ratio) + 1024)!
    var consumed = false
    converter.convert(to: output, error: nil) { _, status in
        if consumed { status.pointee = .endOfStream; return nil }
        consumed = true
        status.pointee = .haveData
        return source
    }
    return output
}
