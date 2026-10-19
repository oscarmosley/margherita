import Foundation

/// Modern Finder binary-plist clipping writer; bounded legacy resource-fork reader.
/// Plain text only. Formatting is intentionally not preserved.
enum TextClipping {
    static let limit = 8 * 1024 * 1024
    static func supports(input: URL, format: String) -> Bool {
        supportsFormat(source: input.pathExtension, target: format)
    }
    static func supportsFormat(source: String, target: String) -> Bool {
        let s = source.lowercased(), t = target.lowercased()
        if s == "textclipping" { return ["txt", "doc", "docx", "rtf", "rtfd", "odt", "html", "webarchive", "md", "pdf", "epub", "png", "jpg"].contains(t) }
        return t == "textclipping" && ["pdf", "doc", "docx", "rtf", "rtfd", "odt", "html", "htm", "txt", "webarchive", "md", "epub", "srt", "vtt"].contains(s)
    }
    static func bounded(_ url: URL) throws -> Data {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let d = try h.read(upToCount: limit + 1) ?? Data()
        guard d.count <= limit else { throw NativeConversionError.message("Text clipping exceeds 8 MB.") }
        return d
    }
    static func read(_ url: URL) throws -> String {
        let data = try bounded(url)
        if !data.isEmpty {
            guard let p = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let types = p["UTI-Data"] as? [String: Any] else { throw NativeConversionError.message("Unsupported clipping property list.") }
            if let s = types["public.utf8-plain-text"] as? String { return s }
            for (key, encoding) in [("public.utf8-plain-text", String.Encoding.utf8), ("public.utf16-external-plain-text", .utf16), ("public.utf16-plain-text", .utf16BigEndian), ("com.apple.traditional-mac-plain-text", .macOSRoman)] {
                if let d = types[key] as? Data, let s = String(data: d, encoding: encoding) { return s }
            }
        }
        return try resourceText(bounded(URL(fileURLWithPath: url.path + "/..namedfork/rsrc")))
    }
    static func resourceText(_ data: Data) throws -> String {
        let b = [UInt8](data)
        func n(_ p: Int, _ count: Int) throws -> Int {
            guard p >= 0, count <= 4, p <= b.count - count else { throw NativeConversionError.message("Malformed clipping resource fork.") }
            return b[p..<p+count].reduce(0) { ($0 << 8) | Int($1) }
        }
        let start = try n(0, 4), map = try n(4, 4), length = try n(8, 4), mapLength = try n(12, 4)
        guard start <= b.count, length <= b.count - start, map <= b.count, mapLength <= b.count - map, mapLength >= 30 else { throw NativeConversionError.message("Invalid resource ranges.") }
        let typeList = try map + n(map + 24, 2)
        let count = try n(typeList, 2) + 1
        guard typeList >= map + 28, typeList <= map + mapLength - 2, count <= 256, count <= (map + mapLength - typeList - 2) / 8 else { throw NativeConversionError.message("Too many clipping resource types.") }
        var found: [String: Data] = [:]
        for i in 0..<count {
            let entry = typeList + 2 + i * 8
            let tagValue = try n(entry, 4)
            let tag = String(bytes: [UInt8((tagValue >> 24) & 255), UInt8((tagValue >> 16) & 255), UInt8((tagValue >> 8) & 255), UInt8(tagValue & 255)], encoding: .ascii) ?? ""
            let resources = try n(entry + 4, 2) + 1, refs = try typeList + n(entry + 6, 2)
            guard refs >= typeList + 2, refs <= map + mapLength, resources <= 1024, resources <= (map + mapLength - refs) / 12 else { throw NativeConversionError.message("Too many clipping resources.") }
            for j in 0..<resources {
                let r = refs + j * 12
                let id = try n(r, 2), attr = try n(r + 4, 1), offset = try n(r + 5, 3)
                guard offset <= length - 4 else { throw NativeConversionError.message("Invalid resource offset.") }
                let size = try n(start + offset, 4), p = start + offset + 4
                guard size <= length - offset - 4, p <= b.count - size else { throw NativeConversionError.message("Invalid resource size.") }
                if id == 256 && attr & 1 == 0 { found[tag] = Data(b[p..<p+size]) }
            }
        }
        for (tag, enc) in [("utf8", String.Encoding.utf8), ("ut16", .utf16), ("utxt", .utf16BigEndian), ("TEXT", .macOSRoman)] {
            if let d = found[tag], let s = String(data: d, encoding: enc) { return s }
        }
        throw NativeConversionError.message("No supported plain-text resource in clipping.")
    }
    static func convert(input: URL, to output: URL, format: String) throws {
        guard supports(input: input, format: format), !FileManager.default.fileExists(atPath: output.path) else { throw NativeConversionError.message("Unsupported clipping conversion or output already exists.") }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("Margherita-clipping-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let plain = work.appendingPathComponent("text.txt")
        if input.pathExtension.lowercased() == "textclipping" {
            try read(input).write(to: plain, atomically: true, encoding: .utf8)
            if format.lowercased() == "txt" { try FileManager.default.moveItem(at: plain, to: output) }
            else { try NativeDocuments.convert(input: plain, to: output, format: format) }
        } else {
            if input.pathExtension.lowercased() == "txt" { try FileManager.default.copyItem(at: input, to: plain) }
            else { try NativeDocuments.convert(input: input, to: plain, format: "txt") }
            guard let text = String(data: try bounded(plain), encoding: .utf8) else { throw NativeConversionError.message("Clipping text must be UTF-8.") }
            let data = try PropertyListSerialization.data(fromPropertyList: ["UTI-Data": ["public.utf8-plain-text": text]], format: .binary, options: 0)
            try data.write(to: output, options: .withoutOverwriting)
        }
    }
}
