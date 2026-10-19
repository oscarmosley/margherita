import Foundation

/// Configurable sampling (15 fps by default), never requesting the end timestamp.
/// GIF stores delays in hundredths, so alternate 0.07/0.06/0.07 rather
/// than rounding every frame independently and slowing the entire clip.
struct GIFSamplingPlan {
    static let framesPerSecond = 15
    static let maximumDuration = 30.0
    static let maximumFrames = 450
    let samplingFPS: Int
    let duration: Double
    let frameCount: Int

    init(duration: Double, framesPerSecond: Int = 15) throws {
        guard duration.isFinite, duration > 0, duration <= Self.maximumDuration else {
            throw GIFExportError.invalidDuration
        }
        samplingFPS = min(50, max(1, framesPerSecond))
        self.duration = duration
        frameCount = min(Int(Self.maximumDuration) * samplingFPS, max(1, Int(ceil(duration * Double(samplingFPS)))))
    }

    func timestamp(for index: Int) -> Double {
        Double(index) / Double(samplingFPS)
    }

    func delay(for index: Int) -> Double {
        let start = timestamp(for: index)
        let end = min(duration, timestamp(for: index + 1))
        // Cumulative rounding prevents drift. A very short tail still needs
        // two ticks because many GIF players replace shorter delays with 0.1s.
        return max(0.02, ((end * 100).rounded() - (start * 100).rounded()) / 100)
    }
}

enum GIFExportError: LocalizedError {
    case invalidDuration, destination, finalize
    var errorDescription: String? {
        switch self {
        case .invalidDuration: return "Native GIF export supports clips up to 30 seconds. Trim the clip or install FFmpeg for longer clips."
        case .destination: return "Could not create GIF."
        case .finalize: return "Could not finish GIF."
        }
    }
}

#if canImport(AVFoundation) && canImport(ImageIO)
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum NativeVideoGIF {
    static func convert(input: URL, output: URL, options: ConversionOptions = ConversionOptions()) async throws {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: input)
        let seconds = try await asset.load(.duration).seconds
        let plan = try GIFSamplingPlan(duration: seconds, framesPerSecond: options.gifFPS)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let width = min(4096, max(16, options.gifWidth))
        generator.maximumSize = CGSize(width: CGFloat(width), height: CGFloat(width))
        // Default tolerances may snap every request to the same distant keyframe.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let cancellation = ConversionCancellation.current
        let registration = cancellation?.register { generator.cancelAllCGImageGeneration() }
        defer {
            if let registration { cancellation?.unregister(registration) }
            generator.cancelAllCGImageGeneration()
        }

        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: output) }
        }
        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, UTType.gif.identifier as CFString, plan.frameCount, nil
        ) else { throw GIFExportError.destination }
        if options.gifLoop {
            CGImageDestinationSetProperties(destination, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
            ] as CFDictionary)
        }
        for index in 0..<plan.frameCount {
            try Task.checkCancellation()
            // Release per-frame decoding objects promptly. Do not accumulate CGImages.
            try autoreleasepool {
                let time = CMTime(seconds: plan.timestamp(for: index), preferredTimescale: 60000)
                let image = try generator.copyCGImage(at: time, actualTime: nil)
                try Task.checkCancellation()
                let delay = plan.delay(for: index)
                CGImageDestinationAddImage(destination, image, [
                    kCGImagePropertyGIFDictionary: [
                        kCGImagePropertyGIFDelayTime: delay,
                        kCGImagePropertyGIFUnclampedDelayTime: delay
                    ]
                ] as CFDictionary)
            }
        }
        try Task.checkCancellation()
        guard CGImageDestinationFinalize(destination) else { throw GIFExportError.finalize }
        try Task.checkCancellation()
        completed = true
    }
}
#endif
