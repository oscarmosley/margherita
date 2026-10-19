import Foundation

/// Normal conversions share this format-level contract in the wheel, engine and
/// compatibility table. Candidate routes are not a promise about damaged content.
enum ConversionRoutes {
    struct Facts: Sendable {
        // RAR/7z need a proven system-libarchive decoder, not a third-party
        // executable assumption. Inject them only when module discovery proves it.
        var archiveInputs: Set<String> = ["zip", "tar", "gz", "bz2", "xz"]
        var imageInputs: Set<String> = []
        var ocrInputs: Set<String> = []
        var imageOutputs: Set<String> = []
        var mediaOutputs: Set<String> = []
        var audioOutputs: Set<String> = []
        var documentRoutes: [String: Set<String>] = [:]
        var mediaAvailable = false
    }

    static func canonical(_ format: String) -> String {
        switch format.lowercased() {
        case "jpeg", "jpe": return "jpg"
        case "tif": return "tiff"
        case "heif": return "heic"
        case "aif": return "aiff"
        case "gzip", "tgz", "tar.gz": return "gz"
        case "clipping": return "textclipping"
        case "htm": return "html"
        default: return format.lowercased()
        }
    }
    static func display(_ format: String) -> String {
        switch canonical(format) {
        case "gz": return "GZIP"
        case "textclipping": return "CLIPPING"
        default: return canonical(format).uppercased()
        }
    }
    static let images: Set<String> = ["jpg", "png", "heic", "tiff", "gif", "webp", "avif", "bmp", "svg", "ico"]
    static let videos: Set<String> = ["mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv"]
    static let audio: Set<String> = ["mp3", "m4a", "wav", "aiff", "caf", "flac", "ogg", "opus", "wma"]
    static let archives: Set<String> = ["zip", "tar", "tgz", "gz", "rar", "7z", "bz2", "xz"]
    static let documents: Set<String> = ["pdf", "pages", "numbers", "key", "ppt", "pptx", "xls", "xlsx", "ods", "csv", "tsv", "doc", "docx", "rtf", "rtfd", "odt", "html", "txt", "md", "epub", "webarchive", "textclipping", "srt", "vtt"]
    static let targets = ["jpg", "png", "webp", "heic", "tiff", "avif", "bmp", "gif",
        "mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv",
        "mp3", "m4a", "wav", "aiff", "caf", "flac", "ogg", "opus", "wma",
        "pdf", "pages", "pptx", "xls", "textclipping", "doc", "docx", "rtf", "rtfd",
        "odt", "html", "txt", "md", "epub", "webarchive", "xlsx", "ods", "csv", "tsv", "srt", "vtt",
        "zip", "tar", "gz"]

    static func supports(source: String, target: String, facts: Facts) -> Bool {
        let s = canonical(source), t = canonical(target)
        guard s != t else { return false }
        // Packaging arbitrary files is implemented by NativeArchives. It is not
        // an audio/video transcode or an archive-content conversion.
        if ["zip", "tar", "gz"].contains(t) {
            return !archives.contains(s) || facts.archiveInputs.contains(s)
        }
        if documents.contains(s) { return facts.documentRoutes[s]?.contains(t) == true }
        if images.contains(s) {
            if t == "pdf" { return facts.imageInputs.contains(s) }
            if images.contains(t) {
                return (facts.imageInputs.contains(s) && facts.imageOutputs.contains(t)) ||
                    (s != "svg" && s != "ico" && facts.mediaOutputs.contains(t))
            }
            return s == "gif" && videos.contains(t) && facts.mediaOutputs.contains(t)
        }
        if videos.contains(s) {
            guard videos.contains(t) || audio.contains(t) || t == "gif" else { return false }
            let nativeSource = ["mp4", "mov", "m4v"].contains(s)
            let nativeTarget = ["mp4", "mov", "m4v", "m4a", "wav", "aiff", "caf", "gif"].contains(t)
            return (nativeSource && nativeTarget) || facts.mediaOutputs.contains(t)
        }
        if audio.contains(s) {
            guard audio.contains(t) else { return false }
            let nativeSource = ["mp3", "m4a", "wav", "aiff", "caf", "flac"].contains(s)
            return (nativeSource && (t == "m4a" || facts.audioOutputs.contains(t))) ||
                facts.mediaOutputs.contains(t)
        }
        return false
    }

    static func outputs(source: String, facts: Facts) -> [String] {
        targets.filter { supports(source: source, target: $0, facts: facts) }
    }
}

#if os(macOS)
extension ConversionRoutes {
    /// One exhaustive UI grouping, preferring the modern settings category
    /// (GIF under Video, slides under Presentations), then legacy-only entries.
    static var catalogGroups: [(name: String, formats: [String])] {
        var seen = Set<String>()
        var groups: [(name: String, formats: [String])] = []
        for group in FormatCatalog.settingsGroups {
            let formats = group.formats.filter { seen.insert($0).inserted }
            groups.append((group.name, formats))
        }
        for group in FormatCatalog.groups {
            let extra = group.formats.filter { seen.insert($0).inserted }
            guard !extra.isEmpty else { continue }
            if let index = groups.firstIndex(where: { $0.name == group.name }) {
                groups[index].formats += extra
            } else { groups.append((group.name, extra)) }
        }
        return groups
    }
    // Dependency discovery happens once on a worker. Main-thread wheel queries
    // read an immutable snapshot and never launch processes or sniff fake files.
    private static let lock = NSLock()
    private static var cached: Facts?
    static var current: Facts {
        lock.lock(); let value = cached; lock.unlock()
        if let value { return value }
        if !Thread.isMainThread { return warmUp() }
        return Facts()
    }

    @discardableResult
    static func warmUp() -> Facts {
        lock.lock(); let value = cached; lock.unlock()
        if let value { return value }
        ExtendedMedia.warmUp()
        var facts = Facts()
        facts.mediaAvailable = ExtendedMedia.available
        facts.imageInputs = Set(images.filter {
            ConversionEngine.supportsImageInput(extension: $0)
        })
        facts.ocrInputs = Set(images.union(["pdf"]).filter {
            ($0 == "pdf" || facts.imageInputs.contains($0)) &&
                NativeOCR.supportsFormat(source: $0, target: "txt")
        })
        facts.imageOutputs = Set(Action.allCases.filter { Action.nativeImageWritable($0) }.map { canonical($0.format) })
        facts.mediaOutputs = Set(targets.filter { ExtendedMedia.supports(format: $0) })
        facts.audioOutputs = Set(audio.filter { NativeAudio.supportsFormat($0) })
        for source in documents {
            facts.documentRoutes[source] = Set(targets.filter {
                NativeDocuments.supportsFormat(source: source, target: $0)
            })
        }
        lock.lock(); cached = facts; lock.unlock()
        return facts
    }

    static func allows(_ url: URL, action: Action, facts: Facts) -> Bool {
        if action == .extract { return facts.archiveInputs.contains(canonical(url.pathExtension)) }
        if action == .ocrText || action == .searchablePDF {
            return facts.ocrInputs.contains(canonical(url.pathExtension))
        }
        let source = canonical(url.pathExtension)
        if action == .pdfPNG || action == .pdfJPEG {
            return source == "pdf" && supports(source: source, target: action == .pdfPNG ? "png" : "jpg", facts: facts)
        }
        if source == "pdf" && (action == .png || action == .jpeg) { return false }
        let target = action == .pdfPNG ? "png" : action == .pdfJPEG ? "jpg" : action.format
        return supports(source: url.pathExtension, target: target, facts: facts)
    }

    static func isNormal(_ action: Action) -> Bool {
        switch action {
        case .compress, .resize, .strip, .rotate, .mergePDF, .splitPDF, .snapshot, .mute, .copyPath, .reveal:
            return false
        default: return true
        }
    }
}
#endif
