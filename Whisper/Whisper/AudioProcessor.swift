import Foundation
import AVFoundation
import CoreML
import WhisperKit

enum AudioResampler {
    static func resampleTo16kHz(samples: [Float], fromRate: Double) -> [Float] {
        guard fromRate != 16000 else { return samples }
        let ratio = 16000.0 / fromRate
        let newCount = Int(Double(samples.count) * ratio)
        guard newCount > 0, !samples.isEmpty else { return [] }
        return (0..<newCount).map { i in
            let srcIndex = Double(i) / ratio
            let lower = Int(srcIndex)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(srcIndex - Double(lower))
            return samples[lower] * (1 - fraction) + samples[upper] * fraction
        }
    }

    static func duration(sampleCount: Int, sampleRate: Double) -> Double {
        guard sampleRate > 0 else { return 0 }
        return Double(sampleCount) / sampleRate
    }
}

final class SelectableInputAudioProcessor: AudioProcessing {
    static func inputDevices() -> [AudioDevice] {
        AudioProcessor.getAudioDevices().filter { !$0.name.hasPrefix("CADefaultDeviceAggregate") }
    }

    private let inner = AudioProcessor()

    private var pinnedDeviceID: DeviceID? {
        guard let name = UserDefaults.standard.string(forKey: "selectedMicrophone") else { return nil }
        return AudioProcessor.getAudioDevices().first { $0.name == name }?.id
    }

    static func loadAudio(fromPath audioFilePath: String, channelMode: ChannelMode, startTime: Double?, endTime: Double?, maxReadFrameSize: AVAudioFrameCount?) throws -> AVAudioPCMBuffer {
        try AudioProcessor.loadAudio(fromPath: audioFilePath, channelMode: channelMode, startTime: startTime, endTime: endTime, maxReadFrameSize: maxReadFrameSize)
    }

    static func loadAudio(at audioPaths: [String], channelMode: ChannelMode) async -> [Result<[Float], Swift.Error>] {
        await AudioProcessor.loadAudio(at: audioPaths, channelMode: channelMode)
    }

    static func padOrTrimAudio(fromArray audioArray: [Float], startAt startIndex: Int, toLength frameLength: Int, saveSegment: Bool) -> MLMultiArray? {
        AudioProcessor.padOrTrimAudio(fromArray: audioArray, startAt: startIndex, toLength: frameLength, saveSegment: saveSegment)
    }

    var audioSamples: ContiguousArray<Float> { inner.audioSamples }

    func purgeAudioSamples(keepingLast keep: Int) { inner.purgeAudioSamples(keepingLast: keep) }

    var relativeEnergy: [Float] { inner.relativeEnergy }

    var relativeEnergyWindow: Int {
        get { inner.relativeEnergyWindow }
        set { inner.relativeEnergyWindow = newValue }
    }

    func startRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        try inner.startRecordingLive(inputDeviceID: inputDeviceID ?? pinnedDeviceID, callback: callback)
    }

    func startStreamingRecordingLive(inputDeviceID: DeviceID?) -> (AsyncThrowingStream<[Float], Error>, AsyncThrowingStream<[Float], Error>.Continuation) {
        inner.startStreamingRecordingLive(inputDeviceID: inputDeviceID ?? pinnedDeviceID)
    }

    func pauseRecording() { inner.pauseRecording() }

    func stopRecording() { inner.stopRecording() }

    func resumeRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        try inner.resumeRecordingLive(inputDeviceID: inputDeviceID ?? pinnedDeviceID, callback: callback)
    }

    func padOrTrim(fromArray audioArray: [Float], startAt startIndex: Int, toLength frameLength: Int) -> (any AudioProcessorOutputType)? {
        inner.padOrTrim(fromArray: audioArray, startAt: startIndex, toLength: frameLength)
    }
}
