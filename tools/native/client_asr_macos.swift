@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech

@available(macOS 26.0, *)
func recognize(_ path: String, _ tag: String) async throws -> [[String: Any]]? {
    guard SpeechTranscriber.isAvailable,
          let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: tag)),
          await SpeechTranscriber.installedLocales.contains(locale) else { return nil }
    let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? file.close() }
    let limit = 16_000 * 2 * 40
    guard let pcm = try file.read(upToCount: limit + 1),
          pcm.count >= 3200, pcm.count <= limit, pcm.count.isMultiple(of: 2),
          let inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: 16_000, channels: 1, interleaved: true),
          let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: UInt32(pcm.count / 2)),
          let destination = input.int16ChannelData?[0] else { return nil }
    input.frameLength = input.frameCapacity
    pcm.copyBytes(to: UnsafeMutableRawBufferPointer(start: destination, count: pcm.count))
    let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                       reportingOptions: [],
                                       attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    guard await AssetInventory.status(forModules: [transcriber]) == .installed,
          let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
          let converter = AVAudioConverter(from: inputFormat, to: format),
          let buffer = AVAudioPCMBuffer(pcmFormat: format,
              frameCapacity: UInt32(ceil(Double(input.frameLength) * format.sampleRate / 16_000)) + 512)
    else { return nil }
    var fed = false
    var error: NSError?
    let converted = converter.convert(to: buffer, error: &error) { _, status in
        if fed { status.pointee = .endOfStream; return nil }
        fed = true
        status.pointee = .haveData
        return input
    }
    guard converted != .error, buffer.frameLength > 0 else { return nil }
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let duration = Double(input.frameLength) / 16_000
    async let results: [[String: Any]] = {
        var words = [[String: Any]]()
        for try await result in transcriber.results where result.isFinal {
            for run in result.text.runs {
                let word = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let time = run.audioTimeRange, let confidence = run.transcriptionConfidence,
                      !word.isEmpty, word.count <= 200,
                      time.start.seconds.isFinite, time.end.seconds.isFinite,
                      (0...duration).contains(time.start.seconds),
                      time.end.seconds >= time.start.seconds,
                      (0...1).contains(confidence) else { continue }
                if words.count < 512 {
                    words.append(["word": word, "start": time.start.seconds,
                                  "end": min(duration, time.end.seconds), "probability": confidence])
                }
            }
        }
        return words
    }()
    let stream = AsyncStream<AnalyzerInput> { continuation in
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()
    }
    do {
        if let end = try await analyzer.analyzeSequence(stream) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let words = try await results
        return words.isEmpty ? nil : words
    } catch {
        await analyzer.cancelAndFinishNow()
        throw error
    }
}

@main struct BobTVMacSpeech {
    static func main() async {
        guard CommandLine.arguments.count == 3, #available(macOS 26.0, *) else { return }
        do {
            guard let words = try await recognize(CommandLine.arguments[1], CommandLine.arguments[2]) else { return }
            let output = try JSONSerialization.data(withJSONObject: ["words": words])
            FileHandle.standardOutput.write(output)
        } catch {
            // The caller falls back without logging audio or transcript text.
        }
    }
}
