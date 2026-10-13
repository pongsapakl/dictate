import AVFoundation
import CoreAudio
import Foundation
import Speech

func now() -> Double { CFAbsoluteTimeGetCurrent() }
func ms(_ a: Double, _ b: Double) -> String { String(format: "%.0fms", (b - a) * 1000) }

func loadSamples(_ path: String, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let src = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: src)
    let converter = AVAudioConverter(from: file.processingFormat, to: format)!
    let ratio = format.sampleRate / file.processingFormat.sampleRate
    let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(src.frameLength) * ratio) + 1024)!
    var consumed = false
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
        if consumed { status.pointee = .endOfStream; return nil }
        consumed = true
        status.pointee = .haveData
        return src
    }
    if let error { throw error }
    return out
}

func slice(_ buf: AVAudioPCMBuffer, from: AVAudioFrameCount, count: AVAudioFrameCount) -> AVAudioPCMBuffer {
    let out = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: count)!
    out.frameLength = count
    let channels = Int(buf.format.channelCount)
    for ch in 0..<channels {
        if let s = buf.floatChannelData, let d = out.floatChannelData {
            d[ch].update(from: s[ch] + Int(from), count: Int(count))
        } else if let s = buf.int16ChannelData, let d = out.int16ChannelData {
            d[ch].update(from: s[ch] + Int(from), count: Int(count))
        }
    }
    return out
}

@main
struct Spike {
    static func main() async throws {
        let args = CommandLine.arguments
        let mode = args.count > 1 ? args[1] : "assets"
        switch mode {
        case "assets": try await assets()
        case "file": try await run(path: args[2], module: args.count > 3 ? args[3] : "transcriber", realtime: false, context: Array(args.dropFirst(4)))
        case "stream": try await run(path: args[2], module: args.count > 3 ? args[3] : "transcriber", realtime: true, context: Array(args.dropFirst(4)))
        case "mic": try await mic(seconds: Double(args[2]) ?? 5, deviceName: args.count > 3 ? args[3] : nil, module: args.count > 4 ? args[4] : "transcriber")
        default: print("modes: assets | file <path> [transcriber|dictation] [ctx...] | stream <path> [module] [ctx...] | mic <sec> [deviceName] [module]")
        }
    }

    static func makeModule(_ name: String) -> any SpeechModule {
        let locale = Locale(identifier: "en_US")
        if name == "dictation-plain" {
            return DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation], reportingOptions: [.volatileResults], attributeOptions: [])
        }
        if name == "dictation-long" {
            return DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        }
        if name == "dictation" {
            return DictationTranscriber(locale: locale, contentHints: [.shortForm], transcriptionOptions: [.punctuation], reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
        }
        return SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
    }

    static func assets() async throws {
        print("SpeechTranscriber.isAvailable:", SpeechTranscriber.isAvailable)
        print("SpeechTranscriber supported:", await SpeechTranscriber.supportedLocales.map(\.identifier).sorted().joined(separator: " "))
        print("SpeechTranscriber installed:", await SpeechTranscriber.installedLocales.map(\.identifier))
        print("DictationTranscriber supported:", await DictationTranscriber.supportedLocales.map(\.identifier).sorted().joined(separator: " "))
        print("DictationTranscriber installed:", await DictationTranscriber.installedLocales.map(\.identifier))
        print("reserved locales:", await AssetInventory.reservedLocales.map(\.identifier), "max", AssetInventory.maximumReservedLocales)
        for name in ["transcriber", "dictation"] {
            let m = makeModule(name)
            print(name, "status:", await AssetInventory.status(forModules: [m]))
            let t0 = now()
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [m]) {
                print(name, "downloading...")
                try await req.downloadAndInstall()
                print(name, "installed in", ms(t0, now()))
            }
            print(name, "status after:", await AssetInventory.status(forModules: [m]))
            print(name, "format:", await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [m]).map { "\($0.sampleRate)Hz ch\($0.channelCount) \($0.commonFormat.rawValue)" } ?? "nil")
        }
    }

    static func run(path: String, module name: String, realtime: Bool, context: [String]) async throws {
        let module = makeModule(name)
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [module]) { try await req.downloadAndInstall() }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])!
        let audio = try loadSamples(path, to: format)
        let duration = Double(audio.frameLength) / format.sampleRate
        let ctx = AnalysisContext()
        if !context.isEmpty { ctx.contextualStrings = [.general: context] }
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        try await analyzer.setContext(ctx)
        let tPrep0 = now()
        try await analyzer.prepareToAnalyze(in: format)
        print("prepare:", ms(tPrep0, now()), "| audio: \(String(format: "%.2f", duration))s | module: \(name) | realtime: \(realtime) | ctx: \(context)")

        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        let tStart = now()
        var tLastBuffer = tStart
        var finalText = ""
        var volatileText = ""
        let printer = Task {
            var firstVolatile = true
            if let t = module as? SpeechTranscriber {
                for try await r in t.results {
                    let text = String(r.text.characters)
                    if r.isFinal { finalText += text; print("  FINAL  +\(ms(tStart, now())): \(text)") }
                    else { volatileText = text; if firstVolatile { print("  first volatile +\(ms(tStart, now()))"); firstVolatile = false } }
                }
            } else if let d = module as? DictationTranscriber {
                for try await r in d.results {
                    let text = String(r.text.characters)
                    if r.isFinal { finalText += text; print("  FINAL  +\(ms(tStart, now())): \(text)") }
                    else { volatileText = text; if firstVolatile { print("  first volatile +\(ms(tStart, now()))"); firstVolatile = false } }
                }
            }
        }
        try await analyzer.start(inputSequence: stream)
        let chunk = AVAudioFrameCount(format.sampleRate / 10)
        var pos: AVAudioFrameCount = 0
        while pos < audio.frameLength {
            let n = min(chunk, audio.frameLength - pos)
            cont.yield(AnalyzerInput(buffer: slice(audio, from: pos, count: n)))
            pos += n
            if realtime { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        tLastBuffer = now()
        cont.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let tFinal = now()
        _ = try? await printer.value
        print("last buffer -> finalize returned:", ms(tLastBuffer, tFinal), "| total wall:", ms(tStart, tFinal), "| RTF x\(String(format: "%.1f", duration / (tFinal - tStart)))")
        print("FINAL TEXT:", finalText.trimmingCharacters(in: .whitespaces))
        if !volatileText.isEmpty { print("leftover volatile:", volatileText) }
    }

    static func mic(seconds: Double, deviceName: String?, module name: String) async throws {
        let module = makeModule(name)
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [module]) { try await req.downloadAndInstall() }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])!
        let engine = AVAudioEngine()
        if let deviceName {
            let disc = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            guard let dev = disc.devices.first(where: { $0.localizedName.contains(deviceName) }) else { print("devices:", disc.devices.map(\.localizedName)); return }
            var id = AudioDeviceID(0)
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var uid = dev.uniqueID as CFString
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            withUnsafeMutablePointer(to: &uid) { p in
                _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<CFString>.size), p, &size, &id)
            }
            var unit = engine.inputNode.audioUnit!
            let err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            print("selected device:", dev.localizedName, "id", id, "err", err)
            _ = unit
        }
        let inFormat = engine.inputNode.outputFormat(forBus: 0)
        print("input format:", inFormat.sampleRate, "ch", inFormat.channelCount, "| analyzer format:", format.sampleRate, "ch", format.channelCount)
        let converter = AVAudioConverter(from: inFormat, to: format)!
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        let tStart = now()
        let printer = Task {
            if let t = module as? SpeechTranscriber {
                for try await r in t.results { print("  \(r.isFinal ? "FINAL" : "vol  ") +\(ms(tStart, now())): \(String(r.text.characters))") }
            } else if let d = module as? DictationTranscriber {
                for try await r in d.results { print("  \(r.isFinal ? "FINAL" : "vol  ") +\(ms(tStart, now())): \(String(r.text.characters))") }
            }
        }
        var peak: Float = 0
        engine.inputNode.installTap(onBus: 0, bufferSize: 1600, format: inFormat) { buf, _ in
            if let d = buf.floatChannelData { for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(d[0][i])) } }
            let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * format.sampleRate / inFormat.sampleRate) + 16)!
            var done = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, st in
                if done { st.pointee = .noDataNow; return nil }
                done = true; st.pointee = .haveData; return buf
            }
            cont.yield(AnalyzerInput(buffer: out))
        }
        try await analyzer.start(inputSequence: stream)
        try engine.start()
        print("recording \(seconds)s... speak now")
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        engine.stop()
        let tRelease = now()
        cont.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        print("release -> finalize returned:", ms(tRelease, now()), "| input peak:", peak)
        _ = try? await printer.value
    }
}
