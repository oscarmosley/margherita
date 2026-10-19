import Foundation
import AppKit
import AVFoundation
import ImageIO
import CoreImage
import CoreGraphics
import PDFKit
import UniformTypeIdentifiers

// Isolated from the main actor. Each batch runs serially to bound memory use.
actor ConversionEngine {
    typealias Progress = @Sendable (Double, String) -> Void
    private let fm = FileManager.default
    private let context = CIContext(options: [.cacheIntermediates: false])

    func run(_ urls: [URL], action: Action, options: ConversionOptions,
             progress: @escaping Progress) async -> EngineResult {
        var result = EngineResult()
        var reserved = Set<String>()
        let grouped = action == .zip || action == .tar || action == .gzip || action == .mergePDF || (action == .pdf && urls.allSatisfy { FileKind.of($0) == .image })
        let groups = grouped ? [urls] : urls.map { [$0] }
        for (index, group) in groups.enumerated() {
            if Task.isCancelled || ConversionCancellation.current?.isCancelled == true { result.notes.append("Cancelled. Completed files were kept."); break }
            guard let first = group.first else { continue }
            do {
                if ConversionRoutes.isNormal(action) {
                    let facts = ConversionRoutes.current
                    guard group.allSatisfy({ ConversionRoutes.allows($0, action: action, facts: facts) }) else {
                        throw MargheritaError.message("This conversion route is not available on this Mac.")
                    }
                }
                let sourceSettings = [.compress, .strip, .resize, .rotate, .snapshot, .mute, .extract].contains(action)
                let settingsFormat = sourceSettings ? first.pathExtension : (action == .searchablePDF || action == .ocrText ? "pdf" : action.format)
                var options = options.resolved(for: settingsFormat)
                if first.pathExtension.lowercased() == "pdf", action == .docx {
                    options.documentLayout = options.formatProfiles["PDF"]?.documentLayout ?? options.documentLayout
                }
                if action == .ocrText || action == .searchablePDF {
                    options.ocrLanguage = options.formatProfiles[FormatSettingsStore.canonical(first.pathExtension)]?.ocrLanguage ?? options.ocrLanguage
                }
                if !["mp4", "mov"].contains(action.format) { options.videoCodec = "auto" }
                let destination = options.destination ?? first.deletingLastPathComponent()
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                let ext = outputExtension(action, first)
                let stem = action == .zip && group.count > 1 ? "Margherita batch" :
                    (action == .mergePDF ? "Merged" : first.deletingPathExtension().lastPathComponent)
                let safeSuffix = options.suffix.replacingOccurrences(of: "{action}", with: action.suffixSlug).replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                let candidate = destination.appendingPathComponent(stem + safeSuffix)
                    .appendingPathExtension(ext)
                var target = try outputURL(candidate, inputs: urls, collision: options.collision)
                if reserved.contains(target.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()) {
                    var number = 2
                    repeat {
                        target = candidate.deletingLastPathComponent()
                            .appendingPathComponent(candidate.deletingPathExtension().lastPathComponent + " " + String(number))
                            .appendingPathExtension(candidate.pathExtension)
                        number += 1
                    } while target.fileExists || reserved.contains(target.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased())
                }
                reserved.insert(target.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased())
                let stage = destination.appendingPathComponent(".margherita-" + UUID().uuidString)
                    .appendingPathExtension(ext)
                defer { try? fm.removeItem(at: stage) }
                let step: Progress = { amount, text in
                    progress((Double(index) + amount) / Double(max(1, groups.count)), text)
                }
                step(0, first.lastPathComponent)
                var usedEngine: String?
                switch action {
                case .searchablePDF, .ocrText:
                    try NativeOCR.convert(input: first, to: stage, format: action.format, language: options.ocrLanguage) { done, total in
                        step(Double(done) / Double(max(1, total)), "Recognizing text · page " + String(min(done + 1, total)) + " of " + String(total))
                    }
                case .zip, .tar, .gzip, .extract:
                    try NativeArchives.convert(input: group, to: stage, format: action.format, compression: options.archiveCompression)
                case .pages, .pptx, .xls, .textClipping, .doc, .docx, .rtf, .rtfd, .odt, .html, .txt, .md, .epub, .webarchive, .xlsx, .ods, .csv, .tsv, .srt, .vtt:
                    usedEngine = try NativeDocuments.convertReporting(input: first, to: stage, format: action.format, layout: options.documentLayout)
                case .pdf:
                    if FileKind.of(first) == .image { try imagesPDF(group, to: stage, options: options) }
                    else { usedEngine = try NativeDocuments.convertReporting(input: first, to: stage, format: "pdf") }
                case .jpeg, .png, .heic, .tiff, .webp, .avif, .bmp, .gif, .resize:
                    if [.document, .spreadsheet].contains(FileKind.of(first)) && [.jpeg, .png].contains(action) {
                        usedEngine = try NativeDocuments.convertReporting(input: first, to: stage, format: action.format)
                    } else if FileKind.of(first) == .video {
                        try await videoGIF(first, to: stage, options: options)
                    } else if action != .resize && !Action.nativeImageWritable(action) {
                        try ExtendedMedia.convert(input: first, to: stage, format: action.format, options: options)
                    } else {
                        do { try image(first, to: stage, action: action, options: options) }
                        catch {
                            if Task.isCancelled { throw error }
                            // Do not turn a failed resize into an unmodified conversion.
                            // SVG must stay inside the validated native vector path.
                            guard action != .resize, first.pathExtension.lowercased() != "svg",
                                  ExtendedMedia.supports(format: action.format) else { throw error }
                            try? fm.removeItem(at: stage)
                            try ExtendedMedia.convert(input: first, to: stage, format: action.format, options: options)
                        }
                    }
                case .splitPDF: try splitPDF(first, to: stage)
                case .mergePDF: try mergePDF(group, to: stage)
                case .pdfPNG, .pdfJPEG:
                    try renderPDF(first, to: stage, jpeg: action == .pdfJPEG, options: options, progress: step)
                case .rotate:
                    if FileKind.of(first) == .pdf { try rotatePDF(first, to: stage) }
                    else { try image(first, to: stage, action: action, options: options) }
                case .snapshot: try await snapshot(first, to: stage, options: options)
                case .mute: try await mute(first, to: stage, options: options, progress: step)
                case .compress, .strip:
                    var adjusted = action == .compress ? options.compressionOptions() : options
                    if action == .strip { adjusted.stripMetadata = true }
                    switch FileKind.of(first) {
                    case .image: try image(first, to: stage, action: action, options: adjusted)
                    case .pdf:
                        if action == .strip { try stripPDF(first, to: stage) }
                        else { try compressPDF(first, to: stage, options: adjusted, progress: step) }
                    case .video, .audio:
                        if ExtendedMedia.available {
                            try ExtendedMedia.convert(input: first, to: stage, format: ext, options: adjusted)
                        } else { try await exportMedia(first, to: stage, action: action, options: adjusted, progress: step) }
                    default: throw MargheritaError.message("This tool is not available for this file. Try ZIP instead.")
                    }
                case .mp4, .mov, .m4v, .mkv, .webm, .avi, .wmv, .mp3, .m4a, .wav, .aiff, .caf, .flac, .ogg, .opus, .wma:
                    if requiresMediaEnhancer(options, audioOnly: FileKind.of(first) == .audio || [.mp3, .m4a, .wav, .aiff, .caf, .flac, .ogg, .opus, .wma].contains(action)) {
                        guard ExtendedMedia.supports(format: action.format) else {
                            throw MargheritaError.message("These media settings require local FFmpeg.")
                        }
                        try ExtendedMedia.convert(input: first, to: stage, format: action.format, options: options)
                    } else if NativeAudio.supports(input: first, format: action.format) {
                        do { try NativeAudio.convert(input: first, to: stage, format: action.format) }
                        catch {
                            if Task.isCancelled { throw error }
                            guard ExtendedMedia.supports(format: action.format) else { throw error }
                            try? fm.removeItem(at: stage)
                            try ExtendedMedia.convert(input: first, to: stage, format: action.format, options: options)
                        }
                    } else {
                        let nativeInput = ["mp4", "mov", "m4v", "mp3", "m4a", "wav", "aif", "aiff", "caf", "flac"].contains(first.pathExtension.lowercased())
                        let nativeOutput = [Action.mp4, .mov, .m4v, .m4a, .wav, .aiff, .caf].contains(action)
                        if nativeInput && nativeOutput {
                            do {
                                if [.wav, .aiff, .caf].contains(action) {
                                    try await NativeMovieAudio.convert(input: first, output: stage, progress: step)
                                } else { try await exportMedia(first, to: stage, action: action, options: options, progress: step) }
                            } catch {
                                if Task.isCancelled { throw error }
                                guard ExtendedMedia.supports(format: action.format) else { throw error }
                                try? fm.removeItem(at: stage)
                                try ExtendedMedia.convert(input: first, to: stage, format: action.format, options: options)
                            }
                        } else {
                            try ExtendedMedia.convert(input: first, to: stage, format: action.format, options: options)
                        }
                    }
                case .copyPath, .reveal: throw MargheritaError.message("This is a file action, not a conversion.")
                }
                try Task.checkCancellation()
                try ConversionCancellation.current?.check()
                guard stage.fileExists else { throw MargheritaError.message("The converter did not create a file.") }
                try await validateArtifact(stage, input: first, action: action, options: options)
                try ConversionCancellation.current?.check()
                try Task.checkCancellation()
                let backup = try install(stage, at: target, collision: options.collision)
                result.outputs.append(target)
                if let usedEngine, !result.engines.contains(usedEngine) { result.engines.append(usedEngine) }
                if let backup { result.backups[target.path] = backup }
                step(1, target.lastPathComponent)
            } catch is CancellationError {
                result.notes.append("Cancelled. Completed files were kept."); break
            } catch {
                if Task.isCancelled || ConversionCancellation.current?.isCancelled == true {
                    result.notes.append("Cancelled. Completed files were kept."); break
                }
                result.notes.append(first.lastPathComponent + " · " + error.localizedDescription)
            }
        }
        return result
    }

    /// Validate native, decodable artifacts before installing a staged result.
    /// Optional formats outside Apple's decoders retain their converter's own validation.
    private func validateArtifact(_ output: URL, input: URL, action: Action,
                                  options: ConversionOptions) async throws {
        try Task.checkCancellation()
        try ConversionCancellation.current?.check()
        let ext = output.pathExtension.lowercased()
        if [.pdfPNG, .pdfJPEG, .splitPDF].contains(action) {
            let original = try readPDF(input)
            let pages = try fm.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
            guard pages.count == original.pageCount else {
                throw MargheritaError.message("Exported page count does not match the PDF.")
            }
            for page in pages {
            try ConversionCancellation.current?.check()
            try Task.checkCancellation()
                try Task.checkCancellation()
                try ConversionCancellation.current?.check()
                if action == .splitPDF {
                    guard try readPDF(page).pageCount == 1 else {
                        throw MargheritaError.message("Split PDF output contains an invalid page.")
                    }
                } else { try validateImage(page) }
            }
        } else if ext == "pdf" {
            _ = try readPDF(output)
        } else if ["jpg", "jpeg", "png", "heic", "tif", "tiff", "gif", "bmp"].contains(ext) {
            try validateImage(output)
            if FileKind.of(input) == .image {
                let before = try sourceImage(input)
                let after = try sourceImage(output)
                let imageLimit = ext == "gif" ? min(4096, max(16, options.gifWidth)) : (options.maxDimension > 0 ? min(options.maxDimension, 16384) : 0)
                let a = try pixels(before, index: 0, limit: imageLimit)
                let b = try pixels(after, index: 0, limit: 0)
                let expectedWidth = action == .rotate ? a.height : a.width
                let expectedHeight = action == .rotate ? a.width : a.height
                guard b.width == expectedWidth, b.height == expectedHeight else {
                    throw MargheritaError.message("Converted image dimensions do not match the original.")
                }
            }
        } else if ["wav", "aiff", "caf", "m4a"].contains(ext) {
            let audio = try AVAudioFile(forReading: output)
            guard audio.length > 0, audio.processingFormat.sampleRate > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096) else {
                throw MargheritaError.message("Audio output has no valid samples.")
            }
            try audio.read(into: buffer)
            guard buffer.frameLength > 0 else {
                throw MargheritaError.message("Audio output could not be decoded.")
            }
            try await validateDuration(output, input: input)
        } else if ["mp4", "mov", "m4v"].contains(ext) {
            let asset = AVURLAsset(url: output)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard !tracks.isEmpty else {
                throw MargheritaError.message("Video output contains no video track.")
            }
            try await validateDuration(output, input: input)
            let generator = AVAssetImageGenerator(asset: asset)
            _ = try generator.copyCGImage(at: .zero, actualTime: nil)
            if action == .mute {
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                guard audioTracks.isEmpty else {
                    throw MargheritaError.message("Muted video still contains audio.")
                }
            }
        } else if (try? output.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0 else { throw MargheritaError.message("The converter produced an empty file.") }
        }
        try Task.checkCancellation()
        try ConversionCancellation.current?.check()
    }

    private func validateImage(_ url: URL) throws {
        let source = try sourceImage(url)
        let count = CGImageSourceGetCount(source)
        guard count > 0, count <= 1200 else {
            throw MargheritaError.message("Image output contains an invalid frame count.")
        }
        for index in 0..<count {
            try Task.checkCancellation()
            try ConversionCancellation.current?.check()
            try autoreleasepool {
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
                let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.doubleValue ?? 0
                let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.doubleValue ?? 0
                guard width.isFinite, height.isFinite, width > 0, height > 0,
                      width * height <= 150_000_000 else {
                    throw MargheritaError.message("Image output exceeds the safe pixel limit.")
                }
                guard let image = CGImageSourceCreateImageAtIndex(source, index,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                      image.width > 0, image.height > 0 else {
                    throw MargheritaError.message("Image output frame could not be decoded.")
                }
            }
        }
    }

    private func validateDuration(_ output: URL, input: URL) async throws {
        let produced = try await AVURLAsset(url: output).load(.duration).seconds
        guard produced.isFinite, produced > 0 else {
            throw MargheritaError.message("Media output has an invalid duration.")
        }
        // Some enhancer-only input formats have no AVFoundation decoder. Do not
        // reject their valid output solely because Apple's input decoder is absent.
        if let original = try? await AVURLAsset(url: input).load(.duration).seconds,
           original.isFinite, original > 0 {
            guard abs(produced - original) <= max(0.25, original * 0.02) else {
                throw MargheritaError.message("Media output duration differs from the input.")
            }
        }
    }

    private func splitPDF(_ input: URL, to output: URL) throws {
        let document = try readPDF(input)
        guard document.pageCount <= 2000 else { throw MargheritaError.message("PDF exceeds 2000 pages.") }
        try fm.createDirectory(at: output, withIntermediateDirectories: false)
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            try ConversionCancellation.current?.check()
            guard let page = document.page(at: index) else { throw MargheritaError.message("Missing PDF page.") }
            let part = PDFDocument(); part.insert(page, at: 0)
            guard part.write(to: output.appendingPathComponent(String(format: "Page %04d.pdf", index + 1))) else {
                throw MargheritaError.message("Could not save split PDF page.")
            }
        }
    }
    private func rotatePDF(_ input: URL, to output: URL) throws {
        let pdf = try readPDF(input)
        for index in 0..<pdf.pageCount {
            try Task.checkCancellation()
            try ConversionCancellation.current?.check()
            if let page = pdf.page(at: index) { page.rotation = (page.rotation + 90) % 360 }
        }
        guard pdf.write(to: output) else { throw MargheritaError.message("Could not save rotated PDF.") }
    }
    private func stripPDF(_ input: URL, to output: URL) throws {
        let pdf = try readPDF(input)
        pdf.documentAttributes = [:]
        guard pdf.write(to: output) else { throw MargheritaError.message("Could not save PDF.") }
    }
    private func snapshot(_ input: URL, to output: URL, options: ConversionOptions) async throws {
        let asset = AVURLAsset(url: input)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 3840, height: 3840)
        let cancellation = ConversionCancellation.current
        let registration = cancellation?.register { generator.cancelAllCGImageGeneration() }
        defer {
            if let registration { cancellation?.unregister(registration) }
            generator.cancelAllCGImageGeneration()
        }
        let image = try generator.copyCGImage(at: .zero, actualTime: nil)
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw MargheritaError.message("Could not create snapshot.")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw MargheritaError.message("Could not finish snapshot.") }
    }
    private func videoGIF(_ input: URL, to output: URL, options: ConversionOptions) async throws {
        if ExtendedMedia.supports(format: "gif") {
            try ExtendedMedia.convert(input: input, to: output, format: "gif", options: options); return
        }
        try await NativeVideoGIF.convert(input: input, output: output, options: options)
    }

    private func mute(_ input: URL, to output: URL, options: ConversionOptions, progress: @escaping Progress) async throws {
        let asset = AVURLAsset(url: input)
        guard let source = try await asset.loadTracks(withMediaType: .video).first else {
            throw MargheritaError.message("No video track found.")
        }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MargheritaError.message("Could not prepare video.")
        }
        let duration = try await asset.load(.duration)
        try video.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
        video.preferredTransform = try await source.load(.preferredTransform)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality),
              exporter.supportedFileTypes.contains(.mp4) else { throw MargheritaError.message("Cannot export this video as MP4.") }
        exporter.outputURL = output; exporter.outputFileType = .mp4
        let lifecycle = ExportLifecycle(exporter)
        let cancellation = ConversionCancellation.current
        let registration = cancellation?.register { lifecycle.cancel() }
        defer { if let registration { cancellation?.unregister(registration) } }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lifecycle.start {
                    switch exporter.status {
                    case .completed: continuation.resume()
                    case .cancelled: continuation.resume(throwing: CancellationError())
                    default: continuation.resume(throwing: exporter.error ?? MargheritaError.message("Video export failed."))
                    }
                }
            }
        }, onCancel: { lifecycle.cancel() })
        progress(1, "Audio removed")
    }

    private func outputExtension(_ action: Action, _ input: URL) -> String {
        switch action {
        case .pdfPNG, .pdfJPEG, .splitPDF: return "pages"
        case .extract: return "extracted"
        case .mergePDF: return "pdf"
        case .snapshot: return "png"
        case .mute: return "mp4"
        case .compress, .strip:
            switch FileKind.of(input) {
            case .video: return "mp4"
            case .audio: return "m4a"
            case .pdf: return "pdf"
            case .image: return imageExtension(input)
            default: return input.pathExtension
            }
        case .resize, .rotate: return FileKind.of(input) == .pdf ? "pdf" : imageExtension(input)
        default: return action.format
        }
    }
    private func imageExtension(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": return "png"
        case "heic", "heif": return "heic"
        case "tif", "tiff": return "tiff"
        case "gif": return "gif"
        default: return "jpg"
        }
    }
    private func outputURL(_ desired: URL, inputs: [URL], collision: String) throws -> URL {
        let canonical = desired.resolvingSymlinksInPath().standardizedFileURL
        if inputs.contains(where: {
            $0.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(canonical.path + "/")
        }) {
            throw MargheritaError.message("The output would contain an original input. Choose a different folder or suffix.")
        }
        let isOriginal = inputs.contains { $0.resolvingSymlinksInPath().standardizedFileURL == canonical }
        if desired.fileExists && collision == "skip" {
            throw MargheritaError.message("Skipped because the output already exists.")
        }
        if !desired.fileExists && !isOriginal { return desired }
        if collision == "replace" && !isOriginal {
            let values = try desired.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw MargheritaError.message("Refusing to replace a symbolic link. Choose a unique filename.")
            }
            return desired
        }
        var n = 2
        while n < 100_000 {
            let stem = desired.deletingPathExtension().lastPathComponent
            let next = desired.deletingLastPathComponent()
                .appendingPathComponent(stem + " " + String(n))
                .appendingPathExtension(desired.pathExtension)
            if !next.fileExists { return next }
            n += 1
        }
        throw MargheritaError.message("Could not find an unused output filename.")
    }
    private func install(_ stage: URL, at target: URL, collision: String) throws -> URL? {
        var backup: URL?
        if target.fileExists {
            guard collision == "replace",
                  (try target.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                throw MargheritaError.message("An output appeared during conversion. Try again with a unique filename.")
            }
            let root = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                  appropriateFor: nil, create: true)
                .appendingPathComponent("Margherita/Recovery", isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let saved = root.appendingPathComponent(UUID().uuidString + "-" + target.lastPathComponent)
            let journal = saved.appendingPathExtension("recovery.json")
            let record = RecoveryRecord(target: target, backup: saved, stage: stage)
            try JSONEncoder().encode(record).write(to: journal, options: .atomic)
            try fm.moveItem(at: target, to: saved); backup = saved
        }
        do { try fm.moveItem(at: stage, to: target) }
        catch {
            if let backup {
                do { try fm.moveItem(at: backup, to: target) }
                catch {
                    throw MargheritaError.message("Installation and restoration failed. Your older output is safe at " + backup.path + ". Recovery details are beside it.")
                }
            }
            throw error
        }
        if let backup {
            let record = RecoveryRecord(target: target, backup: backup, stage: stage, installed: true)
            // The pre-move journal remains useful even if updating its state fails.
            try? JSONEncoder().encode(record).write(to: backup.appendingPathExtension("recovery.json"), options: .atomic)
        }
        return backup
    }

    /// Capability uses ImageIO's actual decoder list, not UTType.image conformance.
    /// AppKit/QuickLook previews are not evidence of a full SVG decoder.
    nonisolated static func supportsImageInput(extension ext: String) -> Bool {
        // SVG has its own bounded XML validation and native AppKit raster path.
        // It does not require an ImageIO SVG plug-in.
        if ext.lowercased() == "svg" { return true }
        guard let type = UTType(filenameExtension: ext.lowercased()) else { return false }
        let decoders = CGImageSourceCopyTypeIdentifiers() as! [String]
        return decoders.contains(type.identifier)
    }

    private func sourceImage(_ url: URL) throws -> CGImageSource {
        if url.pathExtension.lowercased() == "svg" {
            return try rasterSVG(url)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw MargheritaError.message(url.pathExtension.lowercased() == "svg"
                ? "This Mac's ImageIO decoder cannot rasterize SVG. Export a PNG or PDF from the vector editor first."
                : "macOS cannot decode this image.")
        }
        return source
    }
    /// Render vector content at its intrinsic dimensions, never a preview thumbnail.
    /// Conservative XML checks forbid active content and resource dependencies.
    private func rasterSVG(_ url: URL) throws -> CGImageSource {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 8 * 1024 * 1024 else {
            throw MargheritaError.message("SVG exceeds the 8 MB safety limit.")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 8 * 1024 * 1024,
              let xml = String(data: data, encoding: .utf8), !xml.contains("\0") else {
            throw MargheritaError.message("SVG must be bounded UTF-8 XML.")
        }
        // Reject all entities (including encoded attribute bypasses), CSS,
        // scripting, embedded documents and any href, not merely remote URLs.
        let lower = xml.lowercased()
        let forbidden = ["<!doctype", "<!entity", "&", "<script", "<style",
                         "<foreignobject", "<image", "href", "url", "filter",
                         "javascript:", "data:", "<?xml-stylesheet"]
        guard !forbidden.contains(where: lower.contains),
              lower.range(of: #"\son[a-z]+\s*="#, options: .regularExpression) == nil,
              lower.contains("<svg") else {
            throw MargheritaError.message("SVG contains unsafe active content or external resources.")
        }
        // Parse strictly before invoking AppKit; never resolve external XML.
        let document = try XMLDocument(data: data, options: [])
        guard let root = document.rootElement(), root.localName?.lowercased() == "svg" else {
            throw MargheritaError.message("Invalid SVG document.")
        }
        let allowedElements: Set<String> = ["svg", "g", "path", "rect", "circle", "ellipse",
            "line", "polyline", "polygon", "text", "tspan", "defs", "lineargradient",
            "radialgradient", "stop", "clippath", "mask", "title", "desc"]
        func inspect(_ element: XMLElement) throws {
            guard allowedElements.contains((element.localName ?? element.name ?? "").lowercased()) else {
                throw MargheritaError.message("SVG contains unsupported embedded content.")
            }
            for attribute in element.attributes ?? [] {
                let name = (attribute.localName ?? attribute.name ?? "").lowercased()
                guard !name.hasPrefix("on"), !["href", "src", "base", "style", "filter"].contains(name) else {
                    throw MargheritaError.message("SVG contains unsafe resource attributes.")
                }
            }
            for child in element.children ?? [] {
                if let nested = child as? XMLElement { try inspect(nested) }
                else if child.kind == .processingInstruction {
                    throw MargheritaError.message("SVG processing instructions are not allowed.")
                }
            }
        }
        try inspect(root)
        func length(_ name: String) -> Double? {
            guard let value = root.attribute(forName: name)?.stringValue else { return nil }
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return Double(text.hasSuffix("px") ? String(text.dropLast(2)) : text)
        }
        var width = length("width"), height = length("height")
        let viewBox = root.attribute(forName: "viewBox")?.stringValue?
            .split(whereSeparator: { $0.isWhitespace || $0 == "," }).compactMap { Double($0) }
        if let box = viewBox, box.count == 4, box[2] > 0, box[3] > 0 {
            if width == nil && height == nil { width = box[2]; height = box[3] }
            else if width == nil, let h = height { width = h * box[2] / box[3] }
            else if height == nil, let w = width { height = w * box[3] / box[2] }
        }
        guard let w = width, let h = height, w.isFinite, h.isFinite,
              w > 0, h > 0, w <= 150_000_000, h <= 150_000_000,
              ceil(w) * ceil(h) <= 150_000_000 else {
            throw MargheritaError.message("SVG needs valid intrinsic dimensions within 150 megapixels.")
        }
        guard let vector = NSImage(data: data), vector.isValid,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(w)),
                  pixelsHigh: Int(ceil(h)), bitsPerSample: 8, samplesPerPixel: 4,
                  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                  bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw MargheritaError.message("This Mac's AppKit cannot render SVG vector content.")
        }
        try Task.checkCancellation()
        try ConversionCancellation.current?.check()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        vector.draw(in: NSRect(x: 0, y: 0, width: ceil(w), height: ceil(h)),
                                from: .zero, operation: .copy, fraction: 1,
                                respectFlipped: false, hints: nil)
        graphics.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]),
              let source = CGImageSourceCreateWithData(png as CFData, nil) else {
            throw MargheritaError.message("AppKit could not rasterize SVG pixels.")
        }
        return source
    }

    private func pixels(_ source: CGImageSource, index: Int, limit: Int) throws -> CGImage {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
        let w = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.doubleValue ?? 0
        let h = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.doubleValue ?? 0
        guard w > 0 && h > 0 && w * h <= 150_000_000 else {
            throw MargheritaError.message("Image is too large or has invalid dimensions.")
        }
        let maxPixel = limit > 0 ? min(limit, Int(max(w, h))) : Int(max(w, h))
        let settings: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, settings as CFDictionary) else {
            throw MargheritaError.message("Could not read image pixels.")
        }
        return image
    }
    private func colorPixels(_ image: CGImage, mode: String) throws -> CGImage {
        guard mode != "original" else { return image }
        guard ["srgb", "grayscale"].contains(mode) else { throw MargheritaError.message("Unsupported color mode.") }
        var source = image
        if mode == "grayscale" {
            let gray = CIImage(cgImage: image).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            guard let rendered = context.createCGImage(gray, from: gray.extent) else { throw MargheritaError.message("Cannot render grayscale.") }
            source = rendered
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(data: nil, width: image.width, height: image.height,
                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MargheritaError.message("Cannot allocate color conversion.")
        }
        bitmap.draw(source, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let converted = bitmap.makeImage() else { throw MargheritaError.message("Cannot convert colors.") }
        return converted
    }

    private func pdfPixels(_ image: CGImage, options: ConversionOptions) throws -> CGImage {
        let colored = try colorPixels(image, mode: options.colorMode)
        let ci = CIImage(cgImage: colored)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: ci.extent)
        guard let pixels = context.createCGImage(ci.composited(over: white), from: ci.extent) else {
            throw MargheritaError.message("Cannot flatten PDF image.")
        }
        let quality = options.formatProfile?.pdfImageQuality ?? options.imageQuality
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw MargheritaError.message("Cannot encode PDF image.")
        }
        CGImageDestinationAddImage(dest, pixels, [kCGImageDestinationLossyCompressionQuality: max(0.05, min(1, quality))] as CFDictionary)
        guard CGImageDestinationFinalize(dest), let source = CGImageSourceCreateWithData(data, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw MargheritaError.message("Cannot finalize PDF image.")
        }
        return decoded
    }

    private func image(_ input: URL, to output: URL, action: Action, options: ConversionOptions) throws {
        let source = try sourceImage(input)
        let ext = output.pathExtension.lowercased()
        let type: UTType
        switch ext {
        case "png": type = .png
        case "heic": type = .heic
        case "tiff": type = .tiff
        case "gif": type = .gif
        case "webp": type = UTType("org.webmproject.webp") ?? .data
        case "avif": type = UTType("public.avif") ?? .data
        case "bmp": type = UTType("com.microsoft.bmp") ?? .data
        default: type = .jpeg
        }
        let supported = CGImageDestinationCopyTypeIdentifiers() as! [String]
        guard supported.contains(type.identifier) else {
            throw MargheritaError.message("This Mac cannot encode " + type.identifier + ".")
        }
        let count = ext == "gif" ? CGImageSourceGetCount(source) : 1
        guard count <= 1200 else { throw MargheritaError.message("GIF has too many frames (maximum 1,200).") }
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, count, nil) else {
            throw MargheritaError.message("Cannot create the image output.")
        }
        if ext == "gif" {
            CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary:
                [kCGImagePropertyGIFLoopCount: options.gifLoop ? 0 : 1]] as CFDictionary)
        }
        for index in 0..<count {
            try Task.checkCancellation()
            try ConversionCancellation.current?.check()
            try autoreleasepool {
                let limit = ext == "gif" ? min(4096, max(16, options.gifWidth)) : (options.maxDimension > 0 ? min(options.maxDimension, 16384) : 0)
                var cg = try colorPixels(pixels(source, index: index, limit: limit), mode: options.colorMode)
                if action == .rotate {
                    let rotated = CIImage(cgImage: cg).oriented(.right)
                    guard let rendered = context.createCGImage(rotated, from: rotated.extent) else {
                        throw MargheritaError.message("Could not rotate image.")
                    }
                    cg = rendered
                }
                // JPEG has no alpha. Deliberately composite onto white instead of silently making black.
                if type == .jpeg {
                    let ci = CIImage(cgImage: cg)
                    let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: ci.extent)
                    if let flattened = context.createCGImage(ci.composited(over: white), from: ci.extent) { cg = flattened }
                }
                var properties: [String: Any] = [:]
                if !options.stripMetadata && action != .strip {
                    properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
                    properties.removeValue(forKey: kCGImagePropertyOrientation as String)
                    properties[kCGImagePropertyOrientation as String] = 1
                    // Pixels are transformed above. Drop stale dimensions and embedded thumbnails.
                    properties.removeValue(forKey: kCGImagePropertyPixelWidth as String)
                    properties.removeValue(forKey: kCGImagePropertyPixelHeight as String)
                }
                if options.colorMode != "original" {
                    properties.removeValue(forKey: kCGImagePropertyProfileName as String)
                }
                properties[kCGImageDestinationLossyCompressionQuality as String] = max(0.05, min(1, options.imageQuality))
                if ext == "gif" {
                    let original = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
                    let gif = original[kCGImagePropertyGIFDictionary as String] as? [String: Any] ?? [:]
                    let delay = gif[kCGImagePropertyGIFUnclampedDelayTime as String] ??
                        gif[kCGImagePropertyGIFDelayTime as String] ?? 0.1
                    properties[kCGImagePropertyGIFDictionary as String] = [kCGImagePropertyGIFDelayTime as String: delay]
                }
                CGImageDestinationAddImage(dest, cg, properties as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(dest) else {
            throw MargheritaError.message("macOS could not finish encoding. Try PNG or JPEG.")
        }
    }

    private func imagesPDF(_ urls: [URL], to output: URL, options: ConversionOptions) throws {
        guard let consumer = CGDataConsumer(url: output as CFURL),
              let pdf = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw MargheritaError.message("Cannot create PDF.")
        }
        defer { pdf.closePDF() }
        for url in urls {
            try Task.checkCancellation()
            try ConversionCancellation.current?.check()
            try autoreleasepool {
                let cg = try pdfPixels(pixels(sourceImage(url), index: 0, limit: options.maxDimension > 0 ? min(options.maxDimension, 16384) : 0), options: options)
                let width = CGFloat(cg.width) * 0.75, height = CGFloat(cg.height) * 0.75
                let box = CGRect(x: 0, y: 0, width: width, height: height)
                var mediaBox = box
                let data = NSData(bytes: &mediaBox, length: MemoryLayout<CGRect>.size)
                pdf.beginPDFPage([kCGPDFContextMediaBox as String: data] as CFDictionary)
                pdf.setFillColor(CGColor(gray: 1, alpha: 1)); pdf.fill(box)
                pdf.draw(cg, in: box); pdf.endPDFPage()
            }
        }
    }
    private func readPDF(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else {
            throw MargheritaError.message("Cannot read this PDF. Unlock password-protected PDFs in Preview first.")
        }
        guard document.pageCount <= 2000 else {
            throw MargheritaError.message("PDF exceeds 2000 pages.")
        }
        return document
    }
    private func mergePDF(_ urls: [URL], to output: URL) throws {
        let merged = PDFDocument()
        for url in urls {
            try ConversionCancellation.current?.check()
            try Task.checkCancellation()
            let document = try readPDF(url)
            guard merged.pageCount + document.pageCount <= 2000 else {
                throw MargheritaError.message("Merged PDF exceeds 2000 pages.")
            }
            for index in 0..<document.pageCount {
            try ConversionCancellation.current?.check()
            try Task.checkCancellation()
                try Task.checkCancellation()
                try ConversionCancellation.current?.check()
                guard let page = document.page(at: index)?.copy() as? PDFPage else {
                    throw MargheritaError.message("Could not copy PDF page.")
                }
                merged.insert(page, at: merged.pageCount)
            }
        }
        guard merged.write(to: output) else { throw MargheritaError.message("Could not save merged PDF.") }
    }
    private func pageImage(_ page: PDFPage, dpi: Double) throws -> CGImage {
        let box = page.bounds(for: .mediaBox)
        let scale = dpi / 72
        let scaledWidth = box.width * scale, scaledHeight = box.height * scale
        guard scaledWidth.isFinite, scaledHeight.isFinite,
              scaledWidth > 0, scaledHeight > 0,
              scaledWidth <= 20000, scaledHeight <= 20000,
              scaledWidth * scaledHeight <= 80_000_000 else {
            throw MargheritaError.message("PDF page is too large to rasterize safely.")
        }
        let w = max(1, Int(scaledWidth)), h = max(1, Int(scaledHeight))
        guard let reference = page.pageRef else {
            throw MargheritaError.message("Missing PDF page drawing data.")
        }
        let rotated = abs(page.rotation) % 180 == 90
        let width = rotated ? h : w, height = rotated ? w : h
        guard let bitmap = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MargheritaError.message("Cannot allocate PDF raster.")
        }
        let destination = CGRect(x: 0, y: 0, width: width, height: height)
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(destination)
        bitmap.concatenate(reference.getDrawingTransform(.mediaBox, rect: destination,
            rotate: 0, preserveAspectRatio: true))
        bitmap.drawPDFPage(reference)
        guard let cg = bitmap.makeImage() else {
            throw MargheritaError.message("Could not render PDF page.")
        }
        return cg
    }
    private func renderPDF(_ input: URL, to output: URL, jpeg: Bool,
                           options: ConversionOptions, progress: Progress) throws {
        let document = try readPDF(input)
        try fm.createDirectory(at: output, withIntermediateDirectories: false)
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            try ConversionCancellation.current?.check()
            try autoreleasepool {
                guard let page = document.page(at: index) else { throw MargheritaError.message("Missing PDF page.") }
                let cg = try colorPixels(pageImage(page, dpi: 150), mode: options.colorMode)
                let name = String(format: "Page %04d", index + 1)
                let url = output.appendingPathComponent(name).appendingPathExtension(jpeg ? "jpg" : "png")
                let type = jpeg ? UTType.jpeg : UTType.png
                guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
                    throw MargheritaError.message("Cannot write PDF page image.")
                }
                CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: options.imageQuality] as CFDictionary)
                guard CGImageDestinationFinalize(dest) else { throw MargheritaError.message("Could not finish PDF page.") }
            }
            progress(Double(index + 1) / Double(document.pageCount), "Page " + String(index + 1))
        }
    }
    private func compressPDF(_ input: URL, to output: URL,
                             options: ConversionOptions, progress: Progress) throws {
        let source = try readPDF(input)
        let compressed = PDFDocument()
        for index in 0..<source.pageCount {
            try Task.checkCancellation()
            try ConversionCancellation.current?.check()
            try autoreleasepool {
                guard let page = source.page(at: index) else { throw MargheritaError.message("Missing PDF page.") }
                let quality = options.imageQuality
                let dpi = quality < 0.5 ? 96.0 : (quality < 0.85 ? 120.0 : 150.0)
                let cg = try colorPixels(pageImage(page, dpi: dpi), mode: options.colorMode)
                let data = NSMutableData()
                guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
                    throw MargheritaError.message("Cannot encode PDF image.")
                }
                CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: max(0.05, min(1, quality))] as CFDictionary)
                guard CGImageDestinationFinalize(dest), let image = NSImage(data: data as Data),
                      let newPage = PDFPage(image: image) else { throw MargheritaError.message("Cannot create compressed PDF page.") }
                // Keep physical page size and portrait/landscape orientation.
                let original = page.bounds(for: .mediaBox)
                let rotated = abs(page.rotation) % 180 == 90
                newPage.setBounds(CGRect(x: 0, y: 0, width: rotated ? original.height : original.width,
                                         height: rotated ? original.width : original.height), for: .mediaBox)
                compressed.insert(newPage, at: compressed.pageCount)
            }
            progress(Double(index + 1) / Double(source.pageCount), "Compressing page " + String(index + 1))
        }
        guard compressed.write(to: output) else { throw MargheritaError.message("Could not save compressed PDF.") }
    }

    private func requiresMediaEnhancer(_ options: ConversionOptions, audioOnly: Bool) -> Bool {
        options.audioSampleRate > 0 || options.audioChannels > 0 ||
            (!audioOnly && (options.videoHeight > 0 || options.videoFPS > 0 || options.videoCodec != "auto"))
    }

    private func exportMedia(_ input: URL, to output: URL, action: Action,
                             options: ConversionOptions, progress: @escaping Progress) async throws {
        let asset = AVURLAsset(url: input)
        let audioOnly = output.pathExtension == "m4a"
        if requiresMediaEnhancer(options, audioOnly: audioOnly) {
            guard ExtendedMedia.supports(format: output.pathExtension) else {
                throw MargheritaError.message("A maximum video height requires local FFmpeg. Select Original height for native export.")
            }
            try ExtendedMedia.convert(input: input, to: output, format: output.pathExtension, options: options)
            return
        }
        let tracks = try await asset.loadTracks(withMediaType: audioOnly ? .audio : .video)
        guard !tracks.isEmpty else { throw MargheritaError.message(audioOnly ? "No audio track found." : "No video track found.") }
        let preset: String
        if audioOnly { preset = AVAssetExportPresetAppleM4A }
        else {
            switch options.videoQuality {
            case "small": preset = AVAssetExportPresetLowQuality
            case "high": preset = AVAssetExportPresetHighestQuality
            default: preset = AVAssetExportPresetMediumQuality
            }
        }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw MargheritaError.message("macOS cannot export this media format.")
        }
        let fileType: AVFileType = audioOnly ? .m4a : (output.pathExtension == "mov" ? .mov : (output.pathExtension == "m4v" ? .m4v : .mp4))
        guard exporter.supportedFileTypes.contains(fileType) else {
            throw MargheritaError.message("This codec does not support the requested output container.")
        }
        exporter.outputURL = output; exporter.outputFileType = fileType
        exporter.shouldOptimizeForNetworkUse = true
        if options.stripMetadata { exporter.metadata = [] }
        else { exporter.metadata = try await asset.load(.metadata) }
        if audioOnly {
            // Apple's AAC preset controls encoder quality. The audio preference adjusts its output-size budget.
            let seconds = try await asset.load(.duration).seconds
            if seconds.isFinite && seconds > 0 {
                exporter.fileLengthLimit = Int64(seconds * Double(max(32, min(512, options.audioBitrate)) * 1000) / 8)
            }
        }
        let observer = Task {
            while !Task.isCancelled {
                progress(Double(exporter.progress), input.lastPathComponent)
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
        defer { observer.cancel() }
        try Task.checkCancellation()
        try ConversionCancellation.current?.check()
        let lifecycle = ExportLifecycle(exporter)
        let cancellation = ConversionCancellation.current
        let registration = cancellation?.register { lifecycle.cancel() }
        defer { if let registration { cancellation?.unregister(registration) } }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lifecycle.start {
                    switch exporter.status {
                    case .completed: continuation.resume()
                    case .cancelled: continuation.resume(throwing: CancellationError())
                    default: continuation.resume(throwing: exporter.error ?? MargheritaError.message("Media export failed. The codec may not be supported by macOS."))
                    }
                }
            }
        }, onCancel: { lifecycle.cancel() })
    }

    private func archive(_ urls: [URL], to output: URL) throws {
        let root = fm.temporaryDirectory.appendingPathComponent("Margherita-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let payload = root.appendingPathComponent("Files", isDirectory: true)
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        for url in urls {
            try Task.checkCancellation()
            try ConversionCancellation.current?.check()
            var target = payload.appendingPathComponent(url.lastPathComponent)
            var index = 2
            while target.fileExists {
                target = payload.appendingPathComponent(url.deletingPathExtension().lastPathComponent + " " + String(index))
                    .appendingPathExtension(url.pathExtension)
                index += 1
            }
            let directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if directory { try fm.copyItem(at: url, to: target) }
            else {
                do { try fm.linkItem(at: url, to: target) }
                catch { try fm.copyItem(at: url, to: target) }
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", "--norsrc", "--noextattr", payload.path, output.path]
        // No shell and no archive extraction. Filenames cannot become executable commands.
        let errorFile = root.appendingPathComponent("error.txt")
        fm.createFile(atPath: errorFile.path, contents: nil)
        let handle = try FileHandle(forWritingTo: errorFile)
        process.standardError = handle
        defer { try? handle.close() }
        try process.run()
        // waitUntilExit keeps this worker actor occupied, never the main thread.
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MargheritaError.message("ZIP creation failed. Check available disk space and file permissions.")
        }
        try Task.checkCancellation()
        try ConversionCancellation.current?.check()
    }
}
