import Foundation
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
import Vision

/// Local-only OCR. Output is a raster facsimile with a searchable text layer, not editable layout.
enum NativeOCR {
    struct Line { let text: String; let box: CGRect }
    struct Raster { let image: CGImage; let size: CGSize }
    static let pageLimit = 200
    static let recognitionLongEdge = 2000
    static let recognitionTimeout: TimeInterval = 20
    static let textLimit = 8 * 1024 * 1024
    private static let images: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "bmp", "gif", "webp", "avif"]
    static func supports(input: URL, format: String) -> Bool {
        supportsFormat(source: input.pathExtension, target: format)
    }
    static func supportsFormat(source: String, target: String) -> Bool {
        let source = source.lowercased()
        // AVIF decoding depends on the macOS ImageIO plug-ins. SVG is deliberately
        // excluded: ImageIO does not provide a reliable bounded SVG raster route.
        if source == "avif" {
            let decoders = CGImageSourceCopyTypeIdentifiers() as? [String] ?? []
            guard decoders.contains(where: { $0.lowercased().contains("avif") }) else { return false }
        }
        return (source == "pdf" || images.contains(source)) &&
            ["txt", "pdf", "ocr", "ocr-txt", "searchable-pdf"].contains(target.lowercased())
    }
    static func document(_ input: URL) throws -> PDFDocument {
        try NativeProcess.checkFile(input)
        guard let pdf = PDFDocument(url: input), !pdf.isLocked, pdf.pageCount > 0, pdf.pageCount <= pageLimit else {
            throw NativeConversionError.message("Choose an unlocked PDF with 1–200 pages.")
        }
        return pdf
    }
    static func raster(_ page: PDFPage) throws -> Raster {
        try checkCancellation()
        guard let ref = page.pageRef else { throw NativeConversionError.message("Cannot read PDF page.") }
        let bounds = ref.getBoxRect(.mediaBox)
        var size = bounds.size
        if abs(Int(ref.rotationAngle)) % 180 == 90 { size = CGSize(width: size.height, height: size.width) }
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size.width <= 14400, size.height <= 14400 else {
            throw NativeConversionError.message("PDF page dimensions exceed the safe limit.")
        }
        let scale = min(2, CGFloat(recognitionLongEdge) / max(size.width, size.height))
        let width = max(1, Int(ceil(size.width * scale))), height = max(1, Int(ceil(size.height * scale)))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NativeConversionError.message("Could not allocate PDF page image.")
        }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(rect)
        ctx.concatenate(ref.getDrawingTransform(.mediaBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(ref)
        guard let image = ctx.makeImage() else { throw NativeConversionError.message("Could not render PDF page.") }
        return Raster(image: image, size: size)
    }
    private static func rasterImage(_ input: URL) throws -> Raster {
        try checkCancellation()
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              CGImageSourceGetCount(source) == 1 else {
            throw NativeConversionError.message("Choose a single-frame image. Convert multipage TIFFs to PDF first.")
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue <= 100000, height.doubleValue <= 100000,
              width.doubleValue * height.doubleValue <= 250_000_000 else {
            throw NativeConversionError.message("Image dimensions exceed the safe OCR limit.")
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: recognitionLongEdge,
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw NativeConversionError.message("Cannot decode image for OCR.")
        }
        return Raster(image: image, size: CGSize(width: image.width, height: image.height))
    }
    /// A lock serializes timer completion with request teardown. Vision cancellation is
    /// cooperative; the UI additionally abandons cancelled jobs without waiting on Vision.
    private final class RequestControl: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var expired = false
        let request: VNRecognizeTextRequest
        init(_ request: VNRecognizeTextRequest) { self.request = request }
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            if !finished { request.cancel() }
        }
        func expire() {
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return }
            expired = true
            request.cancel()
        }
        func complete() -> Bool {
            lock.lock(); defer { lock.unlock() }
            finished = true
            return expired
        }
    }
    private static func checkCancellation() throws {
        try Task.checkCancellation()
        try ConversionCancellation.current?.check()
    }
    static func recognize(_ image: CGImage, language: String = "auto") throws -> [Line] {
        try checkCancellation()
        let request = VNRecognizeTextRequest()
        // Bounded, local OCR prioritizes screenshot responsiveness over linguistic repair.
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let control = RequestControl(request)
        let token = ConversionCancellation.current
        let registration = token?.register { control.cancel() }
        let deadline = DispatchWorkItem { control.expire() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + recognitionTimeout, execute: deadline)
        defer {
            deadline.cancel()
            _ = control.complete()
            if let registration = registration { token?.unregister(registration) }
        }
        if language != "auto" {
            let supported = try request.supportedRecognitionLanguages()
            guard supported.contains(language) else { throw NativeConversionError.message("OCR language unsupported on this Mac.") }
            request.recognitionLanguages = [language]
        } else { request.automaticallyDetectsLanguage = true }
        try checkCancellation()
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            let timedOut = control.complete()
            try checkCancellation()
            if timedOut { throw NativeConversionError.message("OCR timed out on this page. Try a smaller or clearer image.") }
            throw error
        }
        let timedOut = control.complete()
        try checkCancellation()
        if timedOut { throw NativeConversionError.message("OCR timed out on this page. Try a smaller or clearer image.") }
        let lines = (request.results ?? []).compactMap { observation -> Line? in
            guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { return nil }
            return Line(text: candidate.string, box: observation.boundingBox)
        }
        // Vision coordinates and Quartz PDF coordinates both start at the bottom left.
        // A stable top-to-bottom ordering; multi-column reading order is not reconstructed.
        return lines.sorted {
            if $0.box.midY != $1.box.midY { return $0.box.midY > $1.box.midY }
            return $0.box.minX < $1.box.minX
        }
    }
    static func text(page: PDFPage, language: String = "auto") throws -> String {
        try checkCancellation()
        let native = page.string ?? ""
        if !native.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return native }
        return try recognize(raster(page).image, language: language).map { $0.text }.joined(separator: "\n")
    }
    private static func overlay(_ lines: [Line], size: CGSize, context: CGContext) throws {
        for item in lines {
            try checkCancellation()
            let box = CGRect(x: item.box.minX * size.width, y: item.box.minY * size.height,
                             width: item.box.width * size.width, height: item.box.height * size.height)
            guard box.width > 0, box.height > 0 else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
            let string = NSAttributedString(string: item.text,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let line = CTLineCreateWithAttributedString(string as CFAttributedString)
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            guard width > 0, ascent + descent > 0 else { continue }
            context.saveGState()
            context.translateBy(x: box.minX, y: box.minY)
            context.scaleBy(x: box.width / width, y: box.height / (ascent + descent))
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 0, y: descent)
            context.setTextDrawingMode(.invisible)
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }
    static func convert(input: URL, to output: URL, format: String, language: String = "auto",
                        progress: @Sendable (Int, Int) -> Void = { _, _ in }) throws {
        try checkCancellation()
        guard supports(input: input, format: format), !FileManager.default.fileExists(atPath: output.path) else {
            throw NativeConversionError.message("Unsupported OCR format or output already exists.")
        }
        try NativeProcess.checkFile(input)
        let pdf = input.pathExtension.lowercased() == "pdf" ? try document(input) : nil
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("Margherita-ocr-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let result = work.appendingPathComponent("result")
        let searchable = ["pdf", "searchable-pdf"].contains(format.lowercased())
        var context: CGContext?
        if searchable {
            guard let created = CGContext(result as CFURL, mediaBox: nil, nil) else {
                throw NativeConversionError.message("Cannot create searchable PDF.")
            }
            context = created
        }
        defer { context?.closePDF() }
        var texts: [String] = [], total = 0, foundText = false
        let pageCount = pdf?.pageCount ?? 1
        for index in 0..<pageCount {
            try checkCancellation()
            progress(index, pageCount)
            try autoreleasepool {
                try checkCancellation()
                // Preserve each page's native text when available. OCR only pages
                // without extractable text, and keep blank pages in the output sequence.
                if !searchable, let pdf = pdf {
                    guard let page = pdf.page(at: index) else { throw NativeConversionError.message("Missing PDF page.") }
                    let pageText = try text(page: page, language: language)
                    total += pageText.utf8.count
                    guard total <= textLimit else { throw NativeConversionError.message("Extracted text exceeds 8 MB.") }
                    foundText = foundText || !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    texts.append(pageText)
                    return
                }
                let image: Raster
                if let pdf = pdf {
                    guard let page = pdf.page(at: index) else { throw NativeConversionError.message("Missing PDF page.") }
                    image = try raster(page)
                } else { image = try rasterImage(input) }
                let lines = try recognize(image.image, language: language)
                let text = lines.map { $0.text }.joined(separator: "\n")
                foundText = foundText || !text.isEmpty
                total += text.utf8.count
                guard total <= textLimit else { throw NativeConversionError.message("Recognized text exceeds 8 MB.") }
                if let ctx = context {
                    var rect = CGRect(origin: .zero, size: image.size)
                    let box = NSData(bytes: &rect, length: MemoryLayout<CGRect>.size)
                    ctx.beginPDFPage([kCGPDFContextMediaBox as String: box] as CFDictionary)
                    ctx.draw(image.image, in: rect)
                    try overlay(lines, size: image.size, context: ctx)
                    ctx.endPDFPage()
                    let bytes = (try? result.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    guard bytes <= NativeProcess.fileLimit else { throw NativeConversionError.message("Searchable PDF exceeds 128 MB.") }
                } else { texts.append(text) }
            }
        }
        try checkCancellation()
        guard foundText else { throw NativeConversionError.message("No readable text was found. Try a clearer scan.") }
        context?.closePDF(); context = nil
        if !searchable { try texts.joined(separator: "\n\n\u{000C}\n\n").write(to: result, atomically: true, encoding: .utf8) }
        try NativeProcess.checkFile(result)
        try checkCancellation()
        try FileManager.default.moveItem(at: result, to: output)
        // Cancellation during the final move must not leave a published partial job.
        do { try checkCancellation() } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        progress(pageCount, pageCount)
    }
}
