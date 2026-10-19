import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if os(macOS)
import AppKit
import CoreText
import ImageIO
#endif

/// Deliberately simplified PPTX recovery renderer, not a PowerPoint layout engine.
/// Every slide is preserved in presentation order, including empty/hidden slides.
/// No themes, masters, group transforms, charts, animations, rich runs or vectors.
enum NativeSlides {
    static func supports(input: URL, format: String) -> Bool {
        supportsFormat(source: input.pathExtension, target: format)
    }
    static func supportsFormat(source: String, target: String) -> Bool {
        source.lowercased() == "pptx" && target.lowercased() == "pdf"
    }
    struct Box {
        let x: Double, y: Double, width: Double, height: Double
    }
    struct Item {
        let text: String
        let imageID: String?
        let box: Box?
    }
    static func items(_ node: SlideXML.Node) -> [Item] {
        // Walk the shape tree in drawing order. Group coordinates are intentionally not guessed.
        guard let tree = node.all("spTree").first else { return [] }
        return tree.children.flatMap { shape -> [Item] in
            let text = shape.all("p").map { p in
                p.all("t").map { $0.text }.joined()
            }.joined(separator: "\n")
            let imageID = shape.all("blip").first?.attributes["r:embed"]
            let transform = shape.all("xfrm").first
            var box: Box?
            if let off = transform?.children.first(where: { $0.name == "off" }),
               let ext = transform?.children.first(where: { $0.name == "ext" }),
               let x = Double(off.attributes["x"] ?? ""), let y = Double(off.attributes["y"] ?? ""),
               let w = Double(ext.attributes["cx"] ?? ""), let h = Double(ext.attributes["cy"] ?? ""),
               [x,y,w,h].allSatisfy({ $0.isFinite && abs($0) <= 1e10 }), w > 0, h > 0 {
                box = Box(x: x/12700, y: y/12700, width: w/12700, height: h/12700)
            }
            return text.isEmpty && imageID == nil ? [] : [Item(text: text, imageID: imageID, box: box)]
        }
    }

    /// Resolve OOXML package-relative relationships, allowing legitimate ../media paths
    /// without permitting traversal outside the already validated extracted package.
    static func resolve(_ target: String, relativeTo part: String) throws -> String {
        guard !target.isEmpty, !target.contains("\\"), !target.contains(":"),
              !target.contains("%"), !target.contains("?"), !target.contains("#") else {
            throw NativeConversionError.message("Unsafe presentation relationship.")
        }
        var parts = target.hasPrefix("/") ? [] : part.split(separator: "/").dropLast().map(String.init)
        for component in target.split(separator: "/").map(String.init) {
            if component == "." { continue }
            if component == ".." {
                guard !parts.isEmpty else { throw NativeConversionError.message("Relationship escapes presentation.") }
                parts.removeLast()
            } else { parts.append(component) }
        }
        guard !parts.isEmpty else { throw NativeConversionError.message("Empty presentation relationship.") }
        return parts.joined(separator: "/")
    }

    static func slidePaths(presentation: SlideXML.Node, relationships: SlideXML.Node) throws -> [String] {
        let ids = presentation.all("sldId")
        guard !ids.isEmpty, ids.count <= 2000 else { throw NativeConversionError.message("Presentation needs 1–2000 slides.") }
        return try ids.map { slide in
            guard let id = slide.attributes["r:id"],
                  let rel = relationships.all("Relationship").first(where: { $0.attributes["Id"] == id }),
                  rel.attributes["TargetMode"] != "External",
                  rel.attributes["Type"]?.hasSuffix("/slide") == true,
                  let target = rel.attributes["Target"] else {
                throw NativeConversionError.message("Invalid slide relationship.")
            }
            return try resolve(target, relativeTo: "ppt/presentation.xml")
        }
    }

    #if os(macOS)
    /// Fit against CoreText's actual visible UTF-16 range, not an estimated height.
    /// If even 8pt cannot fit, return the unrendered suffix for continuation pages.
    static func drawText(_ text: String, in rect: CGRect, context: CGContext) -> String {
        guard !text.isEmpty else { return "" }
        guard rect.width >= 1, rect.height >= 1 else { return text }
        let length = (text as NSString).length
        func frame(_ size: CGFloat) -> CTFrame {
            let style = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.black])
            let setter = CTFramesetterCreateWithAttributedString(style as CFAttributedString)
            return CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
                                            CGPath(rect: rect, transform: nil), nil)
        }
        var selected = frame(8)
        let minimumVisible = CTFrameGetVisibleStringRange(selected).length
        if minimumVisible >= length {
            var low: CGFloat = 8, high: CGFloat = 18
            for _ in 0..<8 {
                let mid = (low + high) / 2
                let candidate = frame(mid)
                if CTFrameGetVisibleStringRange(candidate).length >= length {
                    low = mid; selected = candidate
                } else { high = mid }
            }
        }
        let visible = min(length, CTFrameGetVisibleStringRange(selected).length)
        guard visible > 0 else { return text }
        context.saveGState()
        context.textMatrix = .identity
        CTFrameDraw(selected, context)
        context.restoreGState()
        return (text as NSString).substring(from: visible)
    }

    static func convert(input: URL, to output: URL, format: String) throws {
        guard supports(input: input, format: format) else {
            throw NativeConversionError.message("Native slides supports simplified PPTX to PDF only. Old PPT needs Keynote or LibreOffice.")
        }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: output.path) else { throw NativeConversionError.message("Output already exists.") }
        let work = fm.temporaryDirectory.appendingPathComponent("Margherita-slides-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let root = work.appendingPathComponent("package")
        try NativeArchives.extract(input: input, to: root)
        let presentation = try SlideXML.read(root.appendingPathComponent("ppt/presentation.xml"))
        let rels = try SlideXML.read(root.appendingPathComponent("ppt/_rels/presentation.xml.rels"))
        let paths = try slidePaths(presentation: presentation, relationships: rels)
        let size = presentation.all("sldSz").first
        let width = (Double(size?.attributes["cx"] ?? "") ?? 9144000) / 12700
        let height = (Double(size?.attributes["cy"] ?? "") ?? 6858000) / 12700
        guard width.isFinite, height.isFinite, width >= 1, height >= 1, width <= 14400, height <= 14400 else {
            throw NativeConversionError.message("Invalid presentation dimensions.")
        }
        var media = CGRect(x: 0, y: 0, width: width, height: height)
        let staged = work.appendingPathComponent("slides.pdf")
        guard let consumer = CGDataConsumer(url: staged as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &media, nil) else {
            throw NativeConversionError.message("Could not create presentation PDF.")
        }
        var finished = false
        defer { if !finished { context.closePDF() } }
        var continuationCount = 0
        for path in paths {
            if Task.isCancelled { throw NativeConversionError.message("Conversion cancelled.") }
            let slide = try SlideXML.read(root.appendingPathComponent(path))
            let components = path.split(separator: "/").map(String.init)
            let relPath = components.dropLast().joined(separator: "/") + "/_rels/" + components.last! + ".rels"
            let relURL = root.appendingPathComponent(relPath)
            let slideRels: SlideXML.Node? = fm.fileExists(atPath: relURL.path) ? try SlideXML.read(relURL) : nil
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(media)
            let content = items(slide)
            var overflow: [String] = []
            for (index, item) in content.enumerated() {
                let box = item.box ?? Box(x: 30, y: 30 + Double(index)*50, width: max(1,width-60), height: 50)
                let rect = CGRect(x: box.x, y: height-box.y-box.height, width: box.width, height: box.height)
                context.saveGState()
                context.clip(to: media)
                if let id = item.imageID,
                   let rel = slideRels?.all("Relationship").first(where: { $0.attributes["Id"] == id }),
                   rel.attributes["TargetMode"] != "External",
                   rel.attributes["Type"]?.hasSuffix("/image") == true,
                   let target = rel.attributes["Target"] {
                    let imagePath = try resolve(target, relativeTo: path)
                    let imageURL = root.appendingPathComponent(imagePath)
                    try NativeProcess.checkFile(imageURL)
                    if let source = CGImageSourceCreateWithURL(imageURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                       let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                       let w = props[kCGImagePropertyPixelWidth] as? NSNumber,
                       let h = props[kCGImagePropertyPixelHeight] as? NSNumber,
                       w.doubleValue > 0, h.doubleValue > 0, w.doubleValue*h.doubleValue <= 32000000,
                       let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
                         [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 4096,
                          kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
                        context.draw(image, in: rect)
                    }
                }
                if !item.text.isEmpty {
                    // Fit inside the actually visible shape area, including off-slide shapes.
                    let visibleRect = rect.intersection(media)
                    let remainder = drawText(item.text, in: visibleRect, context: context)
                    if !remainder.isEmpty { overflow.append(remainder) }
                }
                context.restoreGState()
            }
            // Disclosure is embedded on every page, never imply layout fidelity.
            let note = NSAttributedString(string: "Simplified PPTX import · layout, fonts and graphics may differ",
                attributes: [.font: NSFont.systemFont(ofSize: 7), .foregroundColor: NSColor.gray])
            let line = CTLineCreateWithAttributedString(note as CFAttributedString)
            context.textPosition = CGPoint(x: 8, y: 4); CTLineDraw(line, context)
            context.endPDFPage()
            // Overflow is explicit recovery content, never silently dropped or painted
            // outside its shape. Bound extra pages and fail atomically if no progress.
            for text in overflow {
                var remaining = text
                while !remaining.isEmpty {
                    continuationCount += 1
                    guard continuationCount <= 2000 else {
                        throw NativeConversionError.message("Presentation text needs too many continuation pages.")
                    }
                    if Task.isCancelled { throw NativeConversionError.message("Conversion cancelled.") }
                    context.beginPDFPage(nil)
                    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(media)
                    let inset = min(30, min(width, height) / 10)
                    let area = media.insetBy(dx: inset, dy: inset)
                    let next = drawText(remaining, in: area, context: context)
                    guard (next as NSString).length < (remaining as NSString).length else {
                        throw NativeConversionError.message("Slide dimensions are too small to recover overflowing text.")
                    }
                    let label = CTLineCreateWithAttributedString(NSAttributedString(
                        string: "Recovered slide text · continuation",
                        attributes: [.font: NSFont.systemFont(ofSize: 7),
                                     .foregroundColor: NSColor.gray]) as CFAttributedString)
                    context.textPosition = CGPoint(x: 8, y: 4); CTLineDraw(label, context)
                    context.endPDFPage()
                    remaining = next
                }
            }
        }
        context.closePDF(); finished = true
        try fm.moveItem(at: staged, to: output)
    }
    #endif
}

/// Bounded tree with no external entities, network loads, DTDs or unbounded recursion.
final class SlideXML: NSObject, XMLParserDelegate {
    final class Node {
        let name: String, attributes: [String: String]
        var children: [Node] = []
        var text = ""
        init(_ name: String, _ attributes: [String: String]) { self.name = name; self.attributes = attributes }
        func all(_ name: String) -> [Node] {
            (self.name == name ? [self] : []) + children.flatMap { $0.all(name) }
        }
    }
    private var stack: [Node] = []
    private var root: Node?
    private var count = 0, bytes = 0
    private var invalid = false
    static func read(_ url: URL) throws -> Node {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 8*1024*1024 else { throw NativeConversionError.message("Slide XML exceeds 8 MB.") }
        return try parse(Data(contentsOf: url))
    }
    static func parse(_ data: Data) throws -> Node {
        guard data.count <= 8*1024*1024, let text = String(data: data, encoding: .utf8),
              !text.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !text.localizedCaseInsensitiveContains("<!ENTITY") else {
            throw NativeConversionError.message("Unsafe or oversized presentation XML.")
        }
        let reader = SlideXML(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = reader
        guard parser.parse(), !reader.invalid, let root = reader.root else {
            throw NativeConversionError.message("Invalid presentation XML.")
        }
        return root
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        count += 1
        guard count <= 100000, stack.count < 64 else { invalid = true; parser.abortParsing(); return }
        let node = Node(elementName.components(separatedBy: ":").last ?? elementName, attributeDict)
        if let parent = stack.last { parent.children.append(node) } else { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        bytes += string.utf8.count
        guard bytes <= 8*1024*1024 else { invalid = true; parser.abortParsing(); return }
        stack.last?.text += string
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if !stack.isEmpty { stack.removeLast() }
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        invalid = true; parser.abortParsing(); return nil
    }
}
