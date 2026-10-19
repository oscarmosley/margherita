import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Optional local FFmpeg support. No runtime downloader, shell or network input. Bundled tools take priority.
/// Call off the main thread; cancellation follows the current Swift task.
enum ExtendedMedia {
    private struct Profile {
        let muxer: String
        let video: String?
        let audio: String?
        let still: Bool
        init(_ muxer: String, video: String? = nil, audio: String? = nil, still: Bool = false) {
            self.muxer = muxer; self.video = video; self.audio = audio; self.still = still
        }
    }
    private static let profiles: [String: Profile] = [
        "mp3": Profile("mp3", audio: "libmp3lame"),
        "flac": Profile("flac", audio: "flac"),
        "ogg": Profile("ogg", audio: "libvorbis"),
        "opus": Profile("opus", audio: "libopus"),
        "wma": Profile("asf", audio: "wmav2"),
        "wav": Profile("wav", audio: "pcm_s16le"),
        "aiff": Profile("aiff", audio: "pcm_s16be"),
        "caf": Profile("caf", audio: "pcm_s16le"),
        "m4a": Profile("ipod", audio: "aac"),
        "mp4": Profile("mp4", video: "libx264", audio: "aac"),
        "mov": Profile("mov", video: "libx264", audio: "aac"),
        "m4v": Profile("ipod", video: "libx264", audio: "aac"),
        "mkv": Profile("matroska", video: "libx264", audio: "aac"),
        "webm": Profile("webm", video: "libvpx-vp9", audio: "libopus"),
        "avi": Profile("avi", video: "mpeg4", audio: "libmp3lame"),
        "wmv": Profile("asf", video: "wmv2", audio: "wmav2"),
        "gif": Profile("gif", video: "gif"),
        "webp": Profile("image2", video: "libwebp", still: true),
        "avif": Profile("avif", video: "libaom-av1", still: true),
        "bmp": Profile("image2", video: "bmp", still: true)
    ]
    private struct Capabilities {
        let executable: URL?
        let encoders: Set<String>
        let muxers: Set<String>
    }
    // Swift static initialization is synchronized and runs once per launch.
    private static let probedCapabilities: Capabilities = {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("bin/ffmpeg"))
        }
        // Only absolute PATH entries: never execute from the current/input directory.
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for directory in path.split(separator: ":") where directory.hasPrefix("/") {
                candidates.append(URL(fileURLWithPath: String(directory)).appendingPathComponent("ffmpeg"))
            }
        }
        candidates += [URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
                       URL(fileURLWithPath: "/usr/local/bin/ffmpeg")]
        for binary in candidates where FileManager.default.isExecutableFile(atPath: binary.path) {
            do {
                let encoders = try run(binary, ["-hide_banner", "-nostdin", "-encoders"], timeout: 15)
                let muxers = try run(binary, ["-hide_banner", "-nostdin", "-muxers"], timeout: 15)
                return Capabilities(executable: binary, encoders: names(encoders), muxers: names(muxers))
            } catch { continue }
        }
        return Capabilities(executable: nil, encoders: [], muxers: [])
    }()
    private static let capabilityLock = NSLock()
    private static var cachedCapabilities: Capabilities?
    /// Only the background warm-up executes capability subprocesses. UI lookups never block.
    static func warmUp() {
        let found = probedCapabilities
        capabilityLock.lock(); cachedCapabilities = found; capabilityLock.unlock()
    }
    private static var capabilities: Capabilities {
        capabilityLock.lock(); let found = cachedCapabilities; capabilityLock.unlock()
        if let found { return found }
        if !Thread.isMainThread { warmUp(); return probedCapabilities }
        return Capabilities(executable: nil, encoders: [], muxers: [])
    }
    private static func names(_ text: String) -> Set<String> {
        var result = Set<String>()
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 2, fields[0] != "=", fields[1] != "=" else { continue }
            for name in fields[1].split(separator: ",") { result.insert(String(name)) }
        }
        return result
    }
    static var available: Bool { capabilities.executable != nil }
    static func supports(format: String) -> Bool {
        guard available, let profile = profiles[format.lowercased()],
              capabilities.muxers.contains(profile.muxer) else { return false }
        return [profile.video, profile.audio].compactMap { $0 }.allSatisfy { capabilities.encoders.contains($0) }
    }

    static func convert(input: URL, to output: URL, format: String, options: ConversionOptions) throws {
        try ConversionCancellation.checkCurrent()
        guard input.isFileURL, output.isFileURL,
              (try input.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
            throw MargheritaError.message("FFmpeg accepts regular local files only.")
        }
        guard let executable = capabilities.executable,
              let profile = profiles[format.lowercased()],
              capabilities.muxers.contains(profile.muxer),
              profile.audio.map({ capabilities.encoders.contains($0) }) ?? true else {
            throw MargheritaError.message("This format needs a local FFmpeg build with the required encoder and muxer. Nothing was installed or downloaded.")
        }
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw MargheritaError.message("The destination already exists. Choose a new filename.")
        }
        // Private staging prevents partial outputs and never touches an existing destination.
        let staging = output.deletingLastPathComponent().appendingPathComponent(".margherita-media-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let temporary = staging.appendingPathComponent("output." + format.lowercased())
        // Restrict demuxers as well as protocols: playlists and devices are not inputs.
        // image2 is deliberately absent: it interprets numbered filenames as sequences
        // and can read adjacent files instead of only the selected regular file.
        let demuxers = "mov,matroska,webm,avi,asf,mp3,flac,ogg,wav,aiff,caf,aac,m4v,mpeg,mpegts,flv,gif,png_pipe,jpeg_pipe,tiff_pipe,bmp_pipe,webp_pipe,avif"
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-n",
                    "-protocol_whitelist", "file", "-format_whitelist", demuxers]
        // JPEG probing can select image2 even for one file. Force its single-file
        // demuxer so literal percent signs never become sequence placeholders.
        if ["jpg", "jpeg", "jpe"].contains(input.pathExtension.lowercased()) {
            args += ["-f", "jpeg_pipe"]
        }
        args += ["-i", input.path, "-sn", "-dn"]
        if options.stripMetadata { args += ["-map_metadata", "-1", "-map_chapters", "-1"] }
        let audioQuality = options.audioQuality.isFinite ? min(1, max(0, options.audioQuality)) : 0.8
        let bitrate = String(options.audioBitrate > 0 ? min(512, max(32, options.audioBitrate)) : Int(64 + audioQuality * 256)) + "k"
        let requestedCodec = options.videoCodec.lowercased()
        guard ["auto", "h264", "hevc"].contains(requestedCodec) else {
            throw MargheritaError.message("Unknown video codec selection.")
        }
        if requestedCodec != "auto" && !["mp4", "mov"].contains(format.lowercased()) {
            throw MargheritaError.message("H.264 and HEVC codec overrides are supported for MP4 and MOV only.")
        }
        let selectedVideo = requestedCodec == "auto" ? profile.video : (requestedCodec == "hevc" ? "libx265" : "libx264")
        if let selectedVideo, !capabilities.encoders.contains(selectedVideo) {
            throw MargheritaError.message("The selected video encoder is unavailable in this FFmpeg build.")
        }
        func audioSettings(_ codec: String) -> [String] {
            var settings: [String] = []
            if !codec.hasPrefix("pcm_") && codec != "flac" {
                // Vorbis rejects high nominal rates on mono input. Keep source
                // channel count, and use a supported nominal target instead.
                let target = codec == "libvorbis" ? String(min(192, max(32, options.audioBitrate))) + "k" : bitrate
                settings += ["-b:a", target]
            }
            if options.audioChannels > 0 { settings += ["-ac", String(min(8, max(1, options.audioChannels)))] }
            if options.audioSampleRate > 0 { settings += ["-ar", String(min(192000, max(8000, options.audioSampleRate)))] }
            else if codec == "libopus" { settings += ["-ar", "48000"] }
            return settings
        }
        if let video = selectedVideo {
            if video != "gif" { args += ["-map", "0:v:0"] }
            args += ["-c:v", video]
            if profile.still {
                if options.maxDimension > 0 {
                    let cap = min(16384, options.maxDimension)
                    args += ["-vf", "scale=w='min(iw,\(cap))':h='min(ih,\(cap))':force_original_aspect_ratio=decrease"]
                }
                args += ["-frames:v", "1", "-an"]
                if video == "libwebp" {
                    let q = options.imageQuality.isFinite ? min(1, max(0, options.imageQuality)) : 0.82
                    args += ["-quality", String(Int(q * 100))]
                }
            } else if video == "gif" {
                let width = min(4096, max(16, options.gifWidth))
                let fps = min(50, max(1, options.gifFPS))
                let cap = options.videoHeight > 0 ? min(4096, options.videoHeight) : width
                let dither = options.gifDither ? "sierra2_4a" : "none"
                let filter = "fps=\(fps),scale=w='min(iw,\(width))':h='min(ih,\(cap))':force_original_aspect_ratio=decrease:flags=lanczos,split[frames][palette];[palette]palettegen[p];[frames][p]paletteuse=dither=\(dither)[gifout]"
                args += ["-map", "[gifout]", "-an", "-filter_complex_threads", "1", "-filter_complex", filter,
                         "-loop", options.gifLoop ? "0" : "-1"]
            } else {
                // Even dimensions for YUV420 codecs, no upscaling, aspect ratio retained.
                let height = options.videoHeight > 0 ? min(8192, max(2, options.videoHeight)) : 0
                let scale = height > 0 ? "scale=w=-2:h='max(2,trunc(min(ih,\(height))/2)*2)'" : "scale=trunc(iw/2)*2:trunc(ih/2)*2"
                let filter = options.videoFPS > 0 ? scale + ",fps=\(min(240, max(1, options.videoFPS)))" : scale
                args += ["-vf", filter, "-pix_fmt", "yuv420p"]
                if video == "libx265" && ["mp4", "mov"].contains(format.lowercased()) {
                    args += ["-tag:v", "hvc1"]
                }
                let crf = options.videoQuality == "high" ? "18" : (options.videoQuality == "small" ? "28" : "23")
                if video == "libx264" || video == "libx265" { args += ["-preset", "medium", "-crf", crf] }
                else if video == "libvpx-vp9" { args += ["-crf", crf, "-b:v", "0"] }
                else { args += ["-q:v", "4"] }
                if let audio = profile.audio {
                    args += ["-map", "0:a:0?", "-c:a", audio] + audioSettings(audio)
                }
                if ["mp4", "mov", "m4v"].contains(format.lowercased()) { args += ["-movflags", "+faststart"] }
            }
        } else if let audio = profile.audio {
            args += ["-map", "0:a:0", "-vn", "-c:a", audio]
            args += audioSettings(audio)
        }
        args += ["-f", profile.muxer, temporary.path]
        _ = try run(executable, args, timeout: 3600)
        try ConversionCancellation.checkCurrent()
        let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
        guard (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
            throw MargheritaError.message("FFmpeg produced an empty output.")
        }
        try FileManager.default.moveItem(at: temporary, to: output)
        do { try ConversionCancellation.checkCurrent() } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// File-backed stdout/stderr avoids pipe-buffer deadlocks, with bounded diagnostics.
    private static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("margherita-ffmpeg-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("log")
        guard FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw MargheritaError.message("Could not create FFmpeg diagnostics.")
        }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        // Do not pass FFREPORT or other ambient FFmpeg configuration into the child.
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "LANG": "C", "AV_LOG_FORCE_NOCOLOR": "1"]
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try ConversionCancellation.checkCurrent()
        try process.run()
        let child = ConversionChild(process)
        let token = ConversionCancellation.current
        let registration = token?.register { child.stop() }
        defer { if let registration { token?.unregister(registration) } }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var interrupted = false
        var cancelled = false
        var oversizedLog = false
        while finished.wait(timeout: .now() + 0.1) == .timedOut {
            do { try ConversionCancellation.checkCurrent() } catch { cancelled = true }
            // Malformed inputs can emit unbounded diagnostics even with loglevel error.
            let logBytes = (try? log.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            oversizedLog = logBytes > 8 * 1024 * 1024
            if cancelled || oversizedLog || ProcessInfo.processInfo.systemUptime >= deadline {
                interrupted = true
                child.stop()
                if finished.wait(timeout: .now() + 2) == .timedOut {
                    if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                    _ = finished.wait(timeout: .now() + 2)
                }
                break
            }
        }
        try ConversionCancellation.checkCurrent()
        if interrupted {
            if cancelled { throw CancellationError() }
            if oversizedLog { throw MargheritaError.message("FFmpeg exceeded the diagnostics size limit.") }
            throw MargheritaError.message("FFmpeg exceeded the conversion time limit.")
        }
        let reader = try FileHandle(forReadingFrom: log)
        defer { try? reader.close() }
        let text = String(decoding: try reader.read(upToCount: 131072) ?? Data(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw MargheritaError.message("FFmpeg could not convert this file. " + String(text.suffix(3000)))
        }
        return text
    }
}
