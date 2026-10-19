import Foundation
import AVFoundation
import AudioToolbox

/// Bounded, sequential audio-file transcoding. Call on a worker, not the UI thread.
/// AAC/M4A keeps the existing AVAssetExportSession route (including video inputs).
/// MP3, Ogg, Opus and WMA encoding belongs to the optional media enhancer.
enum NativeAudio {
    private static let formats: Set<String> = ["wav", "aiff", "caf", "flac"]

    /// FLAC is conditional on a real encoder, not just Apple's FLAC decoder/format ID.
    private static let encoderIDs: Set<AudioFormatID> = {
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(kAudioFormatProperty_EncodeFormatIDs, 0, nil, &size) == noErr,
              size > 0, size <= 65536,
              Int(size) % MemoryLayout<AudioFormatID>.size == 0 else { return [] }
        var ids = [AudioFormatID](repeating: 0, count: Int(size) / MemoryLayout<AudioFormatID>.size)
        let status = ids.withUnsafeMutableBytes { bytes in
            AudioFormatGetProperty(kAudioFormatProperty_EncodeFormatIDs, 0, nil, &size, bytes.baseAddress!)
        }
        guard status == noErr else { return [] }
        return Set(ids.prefix(Int(size) / MemoryLayout<AudioFormatID>.size))
    }()

    /// Format-level encoder availability only. Does not promise a particular input
    /// is decodable, or that its rate/channel layout is accepted by this encoder.
    /// Use supports(input:format:) for real selected files.
    static func supportsFormat(_ format: String) -> Bool {
        let target = format.lowercased()
        guard formats.contains(target) else { return false }
        return target != "flac" || encoderIDs.contains(kAudioFormatFLAC)
    }

    /// Compatibility-table candidate, not a content/decode guarantee. Only audio
    /// containers with a normal Core Audio decode route are listed; movies belong
    /// to NativeMovieAudio and optional codecs belong to ExtendedMedia.
    static func supportsFormat(sourceExtension: String, target: String) -> Bool {
        let source = sourceExtension.lowercased()
        let nativeAudioInputs: Set<String> = ["mp3", "m4a", "wav", "aif", "aiff", "caf", "flac"]
        return nativeAudioInputs.contains(source) && supportsFormat(target)
    }

    static func supports(input: URL, format: String) -> Bool {
        let target = format.lowercased()
        guard supportsFormat(target), input.isFileURL,
              (try? input.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let reader = try? AVAudioFile(forReading: input, commonFormat: .pcmFormatFloat32, interleaved: false)
        else { return false }
        return valid(reader, target: target)
    }

    private static func valid(_ reader: AVAudioFile, target: String) -> Bool {
        let source = reader.processingFormat
        // Explicit safety limits, not silent truncation, downmixing or resampling.
        return reader.length > 0 && reader.length <= Int64.max / 128
            && source.sampleRate.isFinite && source.sampleRate >= 8000 && source.sampleRate <= 384000
            && source.channelCount > 0 && source.channelCount <= (target == "flac" ? 8 : 32)
    }

    static func convert(input: URL, to output: URL, format: String) throws {
        try ConversionCancellation.checkCurrent()
        let target = format.lowercased()
        guard supports(input: input, format: target), output.isFileURL,
              output.pathExtension.lowercased() == target else {
            throw MargheritaError.message("This audio input or output is not supported by the native encoder. Try the optional media enhancer.")
        }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: output.path) else {
            throw MargheritaError.message("The destination already exists. Choose a new filename.")
        }
        let directory = output.deletingLastPathComponent()
            .appendingPathComponent(".margherita-audio-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: directory) }
        let temporary = directory.appendingPathComponent("audio." + target)
        // Separate scope releases AVAudioFile, finalizing compressed headers before installation.
        try write(input: input, output: temporary, target: target)
        try ConversionCancellation.checkCurrent()
        let verification = try AVAudioFile(forReading: temporary)
        guard verification.length > 0 else {
            throw MargheritaError.message("The native audio encoder produced an empty file.")
        }
        try fm.moveItem(at: temporary, to: output)
        do { try ConversionCancellation.checkCurrent() } catch {
            try? fm.removeItem(at: output)
            throw error
        }
    }

    private static func write(input: URL, output: URL, target: String) throws {
        let reader = try AVAudioFile(forReading: input, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard valid(reader, target: target) else {
            throw MargheritaError.message("Audio has an invalid length, sample rate or channel count.")
        }
        let pcm = reader.processingFormat
        var settings: [String: Any] = [
            AVFormatIDKey: target == "flac" ? kAudioFormatFLAC : kAudioFormatLinearPCM,
            AVSampleRateKey: pcm.sampleRate,
            AVNumberOfChannelsKey: Int(pcm.channelCount)
        ]
        if target == "flac" {
            settings[AVEncoderBitDepthHintKey] = 24
        } else {
            settings[AVLinearPCMBitDepthKey] = 24
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = target == "aiff"
            settings[AVLinearPCMIsNonInterleaved] = false
        }
        // Both processing sides deliberately use identical Float32 PCM, rate and channels.
        // AVAudioFile performs codec conversion internally; no AVAudioConverter/resampler is
        // needed here, and a mismatched processing format is rejected rather than passed on.
        let writer = try AVAudioFile(forWriting: output, settings: settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        guard writer.processingFormat == pcm,
              let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 32768) else {
            throw MargheritaError.message("Cannot prepare matching bounded audio buffers.")
        }
        let expected = reader.length
        var written: AVAudioFramePosition = 0
        while written < expected {
            try ConversionCancellation.checkCurrent()
            let count = AVAudioFrameCount(min(Int64(buffer.frameCapacity), expected - written))
            buffer.frameLength = 0
            try reader.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0, buffer.frameLength <= count else {
                throw MargheritaError.message("Audio ended before its declared frame length.")
            }
            try writer.write(from: buffer)
            written += AVAudioFramePosition(buffer.frameLength)
        }
        try ConversionCancellation.checkCurrent()
    }
}
