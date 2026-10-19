import Foundation
import AVFoundation
import AudioToolbox

/// Decode an asset's audio track, not its movie container, into bounded PCM buffers.
/// AVAudioFile supplies the WAV/AIFF/CAF container writer and finalizes on scope exit.
enum NativeMovieAudio {
    static func convert(input: URL, output: URL,
                        progress: @escaping @Sendable (Double, String) -> Void) async throws {
        try Task.checkCancellation()
        try ConversionCancellation.current?.check()
        let fm = FileManager.default
        guard input.isFileURL, output.isFileURL,
              ["wav", "aiff", "caf"].contains(output.pathExtension.lowercased()),
              !fm.fileExists(atPath: output.path) else {
            throw MargheritaError.message("Choose a new local WAV, AIFF or CAF destination.")
        }
        let staging = output.deletingLastPathComponent()
            .appendingPathComponent(".margherita-movie-audio-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let temporary = staging.appendingPathComponent("audio." + output.pathExtension.lowercased())
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw MargheritaError.message("No audio track found.")
        }
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            throw MargheritaError.message("Cannot read the audio track format.")
        }
        let rate = basic.pointee.mSampleRate
        let channels = basic.pointee.mChannelsPerFrame
        guard rate.isFinite, rate >= 8000, rate <= 384000, channels > 0, channels <= 32,
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate,
                                         channels: channels, interleaved: true) else {
            throw MargheritaError.message("Unsupported audio track sample rate or channels.")
        }
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let decoder = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        decoder.alwaysCopiesSampleData = false
        guard reader.canAdd(decoder) else {
            throw MargheritaError.message("Cannot decode the audio track.")
        }
        reader.add(decoder)
        let cancellation = ConversionCancellation.current
        let registration = cancellation?.register { reader.cancelReading() }
        defer {
            if let registration { cancellation?.unregister(registration) }
            reader.cancelReading()
        }
        var settings = format.settings
        settings[AVLinearPCMIsBigEndianKey] = output.pathExtension.lowercased() == "aiff"
        // This lexical scope closes/finalizes the container before verification.
        try write(reader: reader, decoder: decoder, output: temporary, settings: settings,
                  format: format, duration: duration, progress: progress)
        try Task.checkCancellation()
        try ConversionCancellation.current?.check()
        let check = try AVAudioFile(forReading: temporary)
        guard check.length > 0, check.processingFormat.channelCount == channels,
              abs(check.processingFormat.sampleRate - rate) < 1 else {
            throw MargheritaError.message("Audio extraction produced invalid PCM output.")
        }
        try Task.checkCancellation()
        try ConversionCancellation.current?.check()
        try fm.moveItem(at: temporary, to: output)
        do {
            try Task.checkCancellation()
            try ConversionCancellation.current?.check()
        } catch {
            try? fm.removeItem(at: output)
            throw error
        }
        progress(1, "Audio extracted")
    }

    private static func write(reader: AVAssetReader, decoder: AVAssetReaderTrackOutput,
                              output: URL, settings: [String: Any], format: AVAudioFormat,
                              duration: Double,
                              progress: @escaping @Sendable (Double, String) -> Void) throws {
        let writer = try AVAudioFile(forWriting: output, settings: settings,
                                    commonFormat: .pcmFormatInt16, interleaved: true)
        guard reader.startReading() else {
            throw reader.error ?? MargheritaError.message("Cannot start audio decoding.")
        }
        var frames: Int64 = 0
        while true {
            try Task.checkCancellation()
            try ConversionCancellation.current?.check()
            guard let sample = decoder.copyNextSampleBuffer() else { break }
            try autoreleasepool {
                let count = CMSampleBufferGetNumSamples(sample)
                guard count > 0, count <= 1_048_576,
                      let block = CMSampleBufferGetDataBuffer(sample),
                      let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(count)),
                      let destination = pcm.int16ChannelData?[0] else {
                    throw MargheritaError.message("Invalid decoded audio buffer.")
                }
                let bytes = count * Int(format.channelCount) * MemoryLayout<Int16>.size
                guard CMBlockBufferGetDataLength(block) == bytes,
                      CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes,
                                                destination: destination) == kCMBlockBufferNoErr else {
                    throw MargheritaError.message("Cannot copy decoded audio samples.")
                }
                pcm.frameLength = AVAudioFrameCount(count)
                try writer.write(from: pcm)
                frames += Int64(count)
                if duration.isFinite && duration > 0 {
                    progress(min(0.99, Double(frames) / format.sampleRate / duration), "Extracting audio")
                }
            }
        }
        try Task.checkCancellation()
        try ConversionCancellation.current?.check()
        guard reader.status == .completed, frames > 0 else {
            throw reader.error ?? MargheritaError.message("Audio decoding did not finish.")
        }
    }
}
