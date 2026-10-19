import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageIO

enum FileKind: String {
    case image, video, audio, pdf, document, spreadsheet, subtitle, archive, other
    static func of(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        if ["rtfd", "pages", "numbers", "key"].contains(ext) { return ext == "numbers" ? .spreadsheet : .document }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return .other }
        if ["zip", "tar", "tgz", "gz", "gzip", "rar", "7z", "bz2", "xz"].contains(ext) { return .archive }
        if ["csv", "tsv", "xls", "xlsx", "ods", "numbers"].contains(ext) { return .spreadsheet }
        if ["srt", "vtt"].contains(ext) { return .subtitle }
        if ["doc", "docx", "pages", "key", "ppt", "pptx", "md", "txt", "rtf", "rtfd", "html", "htm", "odt", "epub", "webarchive", "textclipping"].contains(ext) { return .document }
        let format = ConversionRoutes.canonical(ext)
        if format == "pdf" { return .pdf }
        if ConversionRoutes.images.contains(format) { return .image } // GIF is an image even when animated.
        if ConversionRoutes.videos.contains(format) { return .video }
        if ConversionRoutes.audio.contains(format) { return .audio }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return .other
    }
}

enum Action: String, CaseIterable, Identifiable {
    case jpeg, png, heic, tiff, gif, webp, avif, bmp, mp4, mov, m4v, mkv, webm, avi, wmv, mp3, m4a, wav, aiff, caf, flac, ogg, opus, wma, pdf, searchablePDF, ocrText, pages, pptx, xls, textClipping, doc, docx, rtf, rtfd, odt, html, txt, md, epub, webarchive, xlsx, ods, csv, tsv, srt, vtt, zip, tar, gzip, extract, compress, resize, strip, rotate, mergePDF, splitPDF, pdfPNG, pdfJPEG, snapshot, mute, copyPath, reveal
    var id: String { rawValue }
    var title: String {
        switch self {
        case .jpeg: return "JPG"
        case .png: return "PNG"
        case .heic: return "HEIC"
        case .tiff: return "TIFF"
        case .gif: return "GIF"
        case .webp: return "WebP"
        case .avif: return "AVIF"
        case .bmp: return "BMP"
        case .mp4: return "MP4"
        case .mov: return "MOV"
        case .m4v: return "M4V"
        case .mkv: return "MKV"
        case .webm: return "WebM"
        case .avi: return "AVI"
        case .wmv: return "WMV"
        case .mp3: return "MP3"
        case .m4a: return "M4A"
        case .wav: return "WAV"
        case .aiff: return "AIFF"
        case .caf: return "CAF"
        case .flac: return "FLAC"
        case .ogg: return "OGG"
        case .opus: return "Opus"
        case .wma: return "WMA"
        case .searchablePDF: return "Searchable PDF"
        case .ocrText: return "OCR Text"
        case .pages: return "Pages"
        case .pptx: return "PPTX"
        case .xls: return "XLS (XML)"
        case .textClipping: return "Text Clipping"
        case .pdf: return "PDF"
        case .doc: return "DOC"
        case .docx: return "DOCX"
        case .rtf: return "RTF"
        case .rtfd: return "RTFD"
        case .odt: return "ODT"
        case .html: return "HTML"
        case .txt: return "TXT"
        case .md: return "Markdown"
        case .epub: return "EPUB"
        case .webarchive: return "Webarchive"
        case .xlsx: return "XLSX"
        case .ods: return "ODS"
        case .csv: return "CSV"
        case .tsv: return "TSV"
        case .srt: return "SRT"
        case .vtt: return "VTT"
        case .zip: return "ZIP"
        case .tar: return "TAR"
        case .gzip: return "GZIP"
        case .extract: return "Extract"
        case .compress: return "Compress"
        case .resize: return "Resize"
        case .strip: return "No metadata"
        case .rotate: return "Rotate 90°"
        case .mergePDF: return "Merge PDFs"
        case .splitPDF: return "Split PDF"
        case .pdfPNG: return "Pages to PNG"
        case .pdfJPEG: return "Pages to JPG"
        case .snapshot: return "Snapshot"
        case .mute: return "Remove audio"
        case .copyPath: return "Copy path"
        case .reveal: return "Show in Finder"
        }
    }
    var format: String {
        switch self { case .searchablePDF: return "pdf"; case .ocrText: return "txt"; case .textClipping: return "textClipping"; case .jpeg: return "jpg"; case .gzip: return "gz"; default: return rawValue }
    }
    var suffixSlug: String {
        switch self {
        case .searchablePDF: return "searchable"
        case .ocrText: return "ocr"
        case .compress: return "compressed"
        case .resize: return "resized"
        case .strip: return "nometadata"
        case .rotate: return "rotated"
        case .mergePDF: return "merged"
        case .extract: return "extracted"
        case .splitPDF: return "split"
        case .pdfPNG: return "pngconvert"
        case .pdfJPEG: return "jpgconvert"
        case .snapshot: return "snapshot"
        case .mute: return "muted"
        default: return format + "convert"
        }
    }
    var symbol: String {
        switch self {
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .resize: return "arrow.up.left.and.arrow.down.right"
        case .strip: return "sparkles"
        case .rotate: return "rotate.right"
        case .mergePDF: return "doc.on.doc"
        case .splitPDF: return "rectangle.split.2x1"
        case .searchablePDF, .ocrText: return "text.viewfinder"
        case .pages, .textClipping: return "doc.text"
        case .pptx: return "rectangle.on.rectangle"
        case .xls: return "tablecells"
        case .pdf, .pdfPNG, .pdfJPEG: return "doc.richtext"
        case .zip, .tar, .gzip, .extract: return "archivebox"
        case .mp4, .mov, .m4v, .mkv, .webm, .avi, .wmv: return "film"
        case .m4a, .wav, .aiff, .caf, .mp3, .flac, .ogg, .opus, .wma: return "waveform"
        case .copyPath: return "link"
        case .reveal: return "folder"
        case .snapshot: return "camera"
        case .mute: return "speaker.slash"
        case .doc, .docx, .rtf, .rtfd, .odt, .html, .txt, .md, .epub, .webarchive, .srt, .vtt: return "doc.text"
        case .xlsx, .ods, .csv, .tsv: return "tablecells"
        default: return "photo"
        }
    }
    private static let imageTypes: [Action: String] = [.jpeg: "public.jpeg", .png: "public.png", .heic: "public.heic", .tiff: "public.tiff", .gif: "com.compuserve.gif", .webp: "org.webmproject.webp", .avif: "public.avif", .bmp: "com.microsoft.bmp"]
    private static let writableImageTypes = Set(CGImageDestinationCopyTypeIdentifiers() as! [String])
    static func nativeImageWritable(_ action: Action) -> Bool {
        guard let type = imageTypes[action] else { return false }
        return writableImageTypes.contains(type)
    }
    static func available(_ urls: [URL], advanced: Bool = false) -> [Action] {
        guard !urls.isEmpty else { return [] }
        let kinds = Set(urls.map { FileKind.of($0).rawValue })
        guard kinds.count == 1, let kind = FileKind(rawValue: kinds.first!) else {
            return advanced ? [.zip, .tar, .gzip, .copyPath, .reveal] : [.zip, .tar, .gzip]
        }
        var result: [Action]
        if advanced {
            switch kind {
            case .image: result = [.compress, .resize, .rotate, .strip, .pdf, .ocrText, .searchablePDF]
            case .pdf: result = [.compress, .strip, .rotate, .splitPDF, .ocrText, .searchablePDF] + (urls.count > 1 ? [.mergePDF] : [])
            case .video: result = [.compress, .strip, .mute, .snapshot]
            case .audio: result = [.compress, .strip]
            case .archive: result = [.extract]
            default: result = [.zip, .tar, .gzip]
            }
            return result.filter { action in
                ![Action.ocrText, .searchablePDF].contains(action) ||
                    urls.allSatisfy { NativeOCR.supports(input: $0, format: action.format) }
            } + [.copyPath, .reveal]
        }
        let facts = ConversionRoutes.current
        result = Action.allCases.filter { action in
            ConversionRoutes.isNormal(action) &&
                urls.allSatisfy { ConversionRoutes.allows($0, action: action, facts: facts) }
        }
        // PDF page exports use their dedicated multi-page engine actions, not
        // the single-image branch. OCR actions remain explicitly named tools.
        if kind == .pdf { result.removeAll { [.png, .jpeg].contains($0) } }
        else { result.removeAll { [.pdfPNG, .pdfJPEG].contains($0) } }
        return result

    }
}

struct ConversionOptions: Sendable {
    var formatProfiles: [String: FormatProfile] = [:]
    var formatProfile: FormatProfile? = nil
    var colorMode = "original"
    var gifFPS = 15
    var gifWidth = 480
    var gifLoop = true
    var gifDither = true
    var videoCodec = "auto"
    var videoFPS = 0
    var audioBitrate = 256
    var audioSampleRate = 0
    var audioChannels = 0
    var ocrLanguage = "auto"
    var imageQuality = 0.82
    var compressionMode = "balanced"
    var documentLayout = "auto"
    var videoHeight = 0
    var archiveCompression = "balanced"
    var videoQuality = "balanced"
    var audioQuality = 0.8
    var maxDimension = 0
    var stripMetadata = true
    var suffix = "-{action}"
    var collision = "unique"
    var destination: URL?

    /// Only the Compress tool calls this. Normal conversions retain chosen quality.
    func compressionOptions() -> ConversionOptions {
        var result = self
        let strong = compressionMode == "strong"
        result.imageQuality = min(imageQuality.isFinite ? imageQuality : 0.82, strong ? 0.45 : 0.72)
        result.audioQuality = min(audioQuality.isFinite ? audioQuality : 0.8, strong ? 0.25 : 0.55)
        result.videoQuality = strong || videoQuality == "small" ? "small" : "balanced"
        result.audioBitrate = min(audioBitrate, strong ? 128 : 192)
        result.archiveCompression = strong ? "small" : "balanced"
        result.gifWidth = min(gifWidth, strong ? 320 : 480)
        result.gifFPS = min(gifFPS, strong ? 10 : 15)
        return result
    }
}

struct HistoryEntry: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    var operation: String
    var inputs: [URL]
    var outputs: [URL]
    var backups: [String: URL]
    var modified: [String: Date]
    var message: String
    var manifests: [String: [String: FileStamp]]? = nil
    var trashedPaths: [String]? = nil
    var undonePaths: [String]? = nil
    var undone = false
}

struct EngineResult: Sendable {
    var engines: [String] = []
    var outputs: [URL] = []
    var backups: [String: URL] = [:]
    var notes: [String] = []
}

enum MargheritaError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

extension URL {
    var fileExists: Bool { FileManager.default.fileExists(atPath: path) }
}

extension Color {
    static let margherita = Color(red: 0.84, green: 0.20, blue: 0.18)
    static let basil = Color(red: 0.27, green: 0.43, blue: 0.30)
    static let mozzarella = Color(red: 0.97, green: 0.93, blue: 0.84)
    static let woodFired = Color(red: 0.12, green: 0.095, blue: 0.08)
}
