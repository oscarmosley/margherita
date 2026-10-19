"""Production-engine smoke tests. Only the Darwin test is an actual media decode test.
Linux syntax/source checks are not codec verification.
"""
import os
import json
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SWIFTC = shutil.which("swiftc") or "/tmp/swift-toolchain/usr/bin/swiftc"
ENV = dict(os.environ, LD_LIBRARY_PATH="/tmp/swift-libs:" + os.environ.get("LD_LIBRARY_PATH", ""))
SOURCES = [
    "Models", "ConversionEngine", "Safety", "ExtendedMedia", "NativeAudio",
    "NativeMovieAudio", "GIFSampling", "NativeOCR", "NativeArchives",
    "NativeDocuments", "NativeSlides", "AppleDocuments",
    "LegacySpreadsheet", "BIFFSpreadsheet", "TextClipping", "PDFOffice",
    "OfficeApplications", "PythonPDFDocuments",
]

HARNESS = r'''
import Foundation
import AppKit
import AVFoundation
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers

@main struct EngineAudit {
    static let engine = ConversionEngine()
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let svg = root.appendingPathComponent("fixture.svg")
        try """
        <svg xmlns="http://www.w3.org/2000/svg" width="120" height="60" viewBox="0 0 120 60">
        <rect width="120" height="60" fill="red"/></svg>
        """.write(to: svg, atomically: true, encoding: .utf8)
        // Inspect actual decode capability. NSImage preview acceptance alone does
        // not authorize ImageIO conversion, and no QuickLook thumbnail is used.
        let svgSource = CGImageSourceCreateWithURL(svg as CFURL, nil)
        let svgPixels = svgSource.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        let appKitAcceptsSVG = NSImage(contentsOf: svg) != nil
        print("SVG actual ImageIO decode: \(svgPixels != nil), NSImage accepts: \(appKitAcceptsSVG)")
        let svgResult = await engine.run([svg], action: .png, options: ConversionOptions(), progress: { _, _ in })
        if appKitAcceptsSVG {
            precondition(svgResult.notes.isEmpty, svgResult.notes.joined(separator: "; "))
            let raster = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(svgResult.outputs[0] as CFURL, nil)!, 0, nil)!
            precondition(raster.width == 120 && raster.height == 60)
            let check = CGContext(data: nil, width: 120, height: 60, bitsPerComponent: 8,
                bytesPerRow: 480, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            check.draw(raster, in: CGRect(x: 0, y: 0, width: 120, height: 60))
            let color = check.data!.assumingMemoryBound(to: UInt8.self)
            precondition(color[0] > 240 && color[1] < 15 && color[2] < 15 && color[3] > 240)
        } else {
            precondition(svgResult.outputs.isEmpty && !svgResult.notes.isEmpty)
            print("AppKit SVG renderer unavailable; honest unsupported result")
        }
        for bad in [
            "<!DOCTYPE svg [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><svg>&x;</svg>",
            "<svg width='10' height='10'><script/></svg>",
            "<svg width='10' height='10'><image href='https://example.com/a'/></svg>",
            "<svg width='10' height='10'><rect fill='url(a)'/></svg>",
            "<svg width='20000' height='20000'/>"
        ] {
            let unsafe = root.appendingPathComponent("unsafe-" + UUID().uuidString + ".svg")
            try bad.write(to: unsafe, atomically: true, encoding: .utf8)
            let rejection = await engine.run([unsafe], action: .png, options: ConversionOptions(), progress: { _, _ in })
            precondition(rejection.outputs.isEmpty && !rejection.notes.isEmpty)
        }
        let source = root.appendingPathComponent("alpha.png")
        let bitmap = CGContext(data: nil, width: 2048, height: 64, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        bitmap.fill(CGRect(x: 1024, y: 0, width: 1024, height: 64))
        let image = bitmap.makeImage()!
        let dest = CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        precondition(CGImageDestinationFinalize(dest))
        for action in [Action.jpeg, .png, .heic, .tiff, .gif, .webp, .avif, .bmp] {
            guard Action.nativeImageWritable(action) else {
                print("Native encoder unavailable, not tested: " + action.format); continue
            }
            let output = try await run(source, action)
            let decoded = CGImageSourceCreateWithURL(output as CFURL, nil)!
            let cg = CGImageSourceCreateImageAtIndex(decoded, 0, nil)!
            precondition(cg.width == 2048 && cg.height == 64, "Ordinary conversion resized the original")
            if action == .jpeg {
                let pixel = CGContext(data: nil, width: 2048, height: 64, bitsPerComponent: 8,
                    bytesPerRow: 2048 * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                pixel.draw(cg, in: CGRect(x: 0, y: 0, width: 2048, height: 64))
                let bytes = pixel.data!.assumingMemoryBound(to: UInt8.self)
                precondition(bytes[0] > 240 && bytes[1] > 240 && bytes[2] > 240,
                             "Transparent JPEG background was not white")
            }
        }
        var chosen = ConversionOptions()
        chosen.maxDimension = 512
        let chosenResult = await engine.run([source], action: .png, options: chosen, progress: { _, _ in })
        precondition(chosenResult.notes.isEmpty)
        let chosenImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(chosenResult.outputs[0] as CFURL, nil)!, 0, nil)!
        precondition(chosenImage.width == 512 && chosenImage.height == 16)
        chosen.maxDimension = 1920
        let resizeResult = await engine.run([source], action: .resize, options: chosen, progress: { _, _ in })
        precondition(resizeResult.notes.isEmpty)
        let resized = resizeResult.outputs[0]
        let resizeImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(resized as CFURL, nil)!, 0, nil)!
        precondition(resizeImage.width == 1920)
        let rotated = try await run(source, .rotate)
        let rotatedImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(rotated as CFURL, nil)!, 0, nil)!
        precondition(rotatedImage.width == 64 && rotatedImage.height == 2048)
        let documentURL = root.appendingPathComponent("three.pdf")
        var box = CGRect(x: 0, y: 0, width: 144, height: 72)
        let pdf = CGContext(documentURL as CFURL, mediaBox: &box, nil)!
        for i in 0..<3 {
            pdf.beginPDFPage(nil)
            pdf.setFillColor(CGColor(red: CGFloat(i) / 2, green: 0.5, blue: 1, alpha: 1))
            pdf.fill(box)
            pdf.endPDFPage()
        }
        pdf.closePDF()
        for action in [Action.pdfPNG, .pdfJPEG] {
            let folder = try await run(documentURL, action)
            let pages = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            precondition(pages.count == 3)
            for page in pages {
                let cg = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(page as CFURL, nil)!, 0, nil)!
                precondition(cg.width == 300 && cg.height == 150)
            }
        }
        let imagePDF = try await run(source, .pdf)
        precondition(PDFDocument(url: imagePDF)!.pageCount == 1)
        let wav = root.appendingPathComponent("tone.wav")
        try tone(wav)
        let video = root.appendingPathComponent("silent.mov")
        try await movie(video)
        let combined = root.appendingPathComponent("fixture.mov")
        let composition = AVMutableComposition()
        let movieAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: wav)
        let videoTrack = try await movieAsset.loadTracks(withMediaType: .video).first!
        let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first!
        let range = CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1))
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(range, of: videoTrack, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(range, of: audioTrack, at: .zero)
        let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
        exporter.outputURL = combined; exporter.outputFileType = .mov
        await exporter.export()
        precondition(exporter.status == .completed, exporter.error?.localizedDescription ?? "fixture export")
        // Exercise the movie-track decoder directly even on Macs whose AudioFile API
        // happens to accept MOV containers.
        for ext in ["wav", "aiff", "caf"] {
            let extracted = root.appendingPathComponent("direct." + ext)
            try await NativeMovieAudio.convert(input: combined, output: extracted, progress: { _, _ in })
            let audio = try AVAudioFile(forReading: extracted, commonFormat: .pcmFormatFloat32, interleaved: false)
            precondition(abs(Double(audio.length) / audio.processingFormat.sampleRate - 1) < 0.08)
            let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096)!
            try audio.read(into: buffer)
            precondition((0..<Int(buffer.frameLength)).contains { abs(buffer.floatChannelData![0][$0]) > 0.01 })
        }
        do {
            try await NativeMovieAudio.convert(input: video, output: root.appendingPathComponent("no-track.wav"),
                                               progress: { _, _ in })
            preconditionFailure("Silent movie unexpectedly produced audio")
        } catch {}
        for action in [Action.wav, .aiff, .caf, .m4a] {
            let output = try await run(combined, action)
            let audio = try AVAudioFile(forReading: output)
            let seconds = Double(audio.length) / audio.processingFormat.sampleRate
            precondition(abs(seconds - 1) < 0.08)
            precondition(audio.processingFormat.channelCount == 2)
            let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096)!
            try audio.read(into: buffer)
            precondition(buffer.frameLength > 0)
        }
        for action in [Action.mp4, .mov, .m4v, .mute] {
            let output = try await run(combined, action)
            let asset = AVURLAsset(url: output)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            precondition(videoTracks.count == 1)
            let duration = try await asset.load(.duration).seconds
            precondition(abs(duration - 1) < 0.08)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            precondition(audioTracks.count == (action == .mute ? 0 : 1))
            let generator = AVAssetImageGenerator(asset: asset)
            _ = try generator.copyCGImage(at: CMTime(value: 1, timescale: 2), actualTime: nil)
        }
        let gif = try await run(combined, .gif)
        let gifSource = CGImageSourceCreateWithURL(gif as CFURL, nil)!
        precondition(CGImageSourceGetCount(gifSource) == 15)
        for index in 0..<15 { precondition(CGImageSourceCreateImageAtIndex(gifSource, index, nil) != nil) }
        if ExtendedMedia.supports(format: "mp4") {
            let gifMovie = try await run(gif, .mp4)
            let movieAsset = AVURLAsset(url: gifMovie)
            let tracks = try await movieAsset.loadTracks(withMediaType: .video)
            precondition(tracks.count == 1)
            let seconds = try await movieAsset.load(.duration).seconds
            precondition(abs(seconds - 1) < 0.1)
            let generator = AVAssetImageGenerator(asset: movieAsset)
            _ = try generator.copyCGImage(at: CMTime(value: 1, timescale: 2), actualTime: nil)
        } else {
            print("GIF to MP4 enhancer dependency unavailable, route not tested")
        }
        let snapshot = try await run(combined, .snapshot)
        precondition(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(snapshot as CFURL, nil)!, 0, nil) != nil)
        // Pre-cancelled work must not generate any outputs.
        let cancelled = Task { () throws -> Void in
            while !Task.isCancelled { await Task.yield() }
            try await NativeMovieAudio.convert(input: combined, output: root.appendingPathComponent("cancel.wav"),
                                               progress: { _, _ in })
        }
        cancelled.cancel()
        do { try await cancelled.value; preconditionFailure("Cancellation ignored") }
        catch is CancellationError {}
        try await inventory(fixtures: [source, documentURL, wav, combined, gif], root: root)
        print("Production engine real-image/PDF/audio/video decode audit passed")
    }

    /// Derive routes from production Action.available for real fixture files.
    /// Only image/PDF/audio/video fixtures are supplied, so no Office automation
    /// or document application launches are triggered by this inventory.
    static func inventory(fixtures: [URL], root: URL) async throws {
        var rows: [[String: Any]] = []
        let forbidden: Set<Action> = [.copyPath, .reveal]
        let documentAutomation: Set<Action> = [.pages, .pptx, .xls, .doc, .docx, .rtf, .rtfd,
            .odt, .html, .txt, .md, .epub, .webarchive, .xlsx, .ods, .csv, .tsv, .textClipping]
        for fixture in fixtures {
            for advanced in [false, true] {
                let actions = Action.available([fixture], advanced: advanced)
                for action in actions {
                    var row: [String: Any] = [
                        "input": fixture.lastPathComponent,
                        "input_kind": FileKind.of(fixture).rawValue,
                        "action": action.rawValue,
                        "advanced": advanced,
                        "discovery": "production Action.available on actual fixture"
                    ]
                    if documentAutomation.contains(action) {
                        row["runtime_status"] = "skipped-office-automation-no-opt-in"
                        row["reason"] = "Document export may invoke an installed application or helper"
                        rows.append(row); continue
                    }
                    if forbidden.contains(action) {
                        row["runtime_status"] = "skipped-file-action"
                        rows.append(row); continue
                    }
                    let folder = root.appendingPathComponent("inventory-" + UUID().uuidString)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                    var options = ConversionOptions()
                    options.destination = folder
                    options.maxDimension = 0
                    let result = await engine.run([fixture], action: action, options: options,
                                                  progress: { _, _ in })
                    row["runtime_status"] = result.notes.isEmpty && !result.outputs.isEmpty ? "pass" : "fail"
                    row["notes"] = result.notes
                    row["engines"] = result.engines
                    var artifacts: [[String: Any]] = []
                    for output in result.outputs {
                        var artifact: [String: Any] = ["filename": output.lastPathComponent,
                                                       "extension": output.pathExtension]
                        let values = try output.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                        artifact["is_directory"] = values.isDirectory ?? false
                        artifact["bytes"] = values.fileSize ?? 0
                        if let source = CGImageSourceCreateWithURL(output as CFURL, nil),
                           let pixels = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                            artifact["image_width"] = pixels.width
                            artifact["image_height"] = pixels.height
                            artifact["image_frames"] = CGImageSourceGetCount(source)
                            artifact["image_first_frame_decoded"] = true
                        }
                        if output.pathExtension.lowercased() == "pdf",
                           let pdf = PDFDocument(url: output) { artifact["pdf_pages"] = pdf.pageCount }
                        if values.isDirectory == true {
                            artifact["entries"] = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
                        }
                        if [FileKind.audio, .video].contains(FileKind.of(output)) {
                            let asset = AVURLAsset(url: output)
                            if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite {
                                artifact["duration_seconds"] = seconds
                            }
                            if let tracks = try? await asset.loadTracks(withMediaType: .audio) {
                                artifact["audio_tracks"] = tracks.count
                            }
                            if let tracks = try? await asset.loadTracks(withMediaType: .video) {
                                artifact["video_tracks"] = tracks.count
                            }
                        }
                        artifacts.append(artifact)
                    }
                    row["artifacts"] = artifacts
                    rows.append(row)
                }
            }
        }
        let report: [String: Any] = [
            "platform": "macOS",
            "runtime_status": "executed",
            "inventory_source": "Action.available on generated actual image/PDF/audio/video fixtures",
            "office_automation": "not requested; no Office inputs or Office actions",
            "scope": "all production-offered basic and advanced actions for these fixtures, not every possible input format",
            "routes": rows
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("engine-action-results.json"), options: .atomic)
        // Preserve the runtime report outside the TemporaryDirectory when requested.
        if let destination = ProcessInfo.processInfo.environment["MARGHERITA_ENGINE_AUDIT_JSON"] {
            try data.write(to: URL(fileURLWithPath: destination), options: .atomic)
        }
        print(String(data: data, encoding: .utf8)!)
    }

    static func run(_ input: URL, _ action: Action) async throws -> URL {
        var options = ConversionOptions()
        options.maxDimension = 0
        let result = await engine.run([input], action: action, options: options, progress: { _, _ in })
        precondition(result.notes.isEmpty, action.rawValue + ": " + result.notes.joined(separator: "; "))
        precondition(result.outputs.count == 1)
        return result.outputs[0]
    }
    static func tone(_ url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
        pcm.frameLength = 44100
        for ch in 0..<2 {
            for i in 0..<44100 { pcm.floatChannelData![ch][i] = Float(sin(Double(i) * 0.05)) * 0.2 }
        }
        let writer = try AVAudioFile(forWriting: url, settings: format.settings)
        try writer.write(from: pcm)
    }
    static func movie(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let track = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: track,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                                         kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(track)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !track.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var pixel: CVPixelBuffer?
            precondition(CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixel) == kCVReturnSuccess)
            CVPixelBufferLockBaseAddress(pixel!, [])
            memset(CVPixelBufferGetBaseAddress(pixel!)!, frame * 7, CVPixelBufferGetDataSize(pixel!))
            CVPixelBufferUnlockBaseAddress(pixel!, [])
            precondition(adaptor.append(pixel!, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        track.markAsFinished()
        await writer.finishWriting()
        precondition(writer.status == .completed)
    }
}
'''


class EngineAuditTests(unittest.TestCase):
    def test_syntax_only_not_codec_verification(self):
        for name in ["ConversionEngine", "NativeMovieAudio"]:
            subprocess.run([SWIFTC, "-frontend", "-parse", str(ROOT / "Margherita" / (name + ".swift"))],
                           check=True, env=ENV)

    def test_source_routes_and_preservation_contract(self):
        source = (ROOT / "Margherita/ConversionEngine.swift").read_text()
        self.assertIn("try await NativeMovieAudio.convert", source)
        self.assertNotIn("private func pcmAudio", source)
        self.assertIn("action != .resize && !Action.nativeImageWritable(action)", source)
        self.assertIn("let limit = ext == \"gif\"", source)
        self.assertIn("bitmap.drawPDFPage(reference)", source)
        self.assertNotIn("page.thumbnail", source)

    def test_inventory_does_not_claim_mac_execution(self):
        report = json.loads((ROOT / "Tests/v9-engine-route-inventory.json").read_text())
        self.assertFalse(report["mac_harness"]["compiled"])
        self.assertFalse(report["mac_harness"]["executed"])
        self.assertTrue(all(route["runtime_status"] == "mac-only-untested" for route in report["routes"]))
        source = (ROOT / "Margherita/ConversionEngine.swift").read_text()
        self.assertLess(source.index("try await validateArtifact(stage"), source.index("let backup = try install"))
        self.assertIn("guard pages.count == original.pageCount", source)

    @unittest.skipUnless(platform.system() == "Darwin", "Needs real macOS SDK and AVFoundation/ImageIO runtime")
    def test_production_engine_real_decodes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            harness = root / "EngineAudit.swift"
            harness.write_text(HARNESS)
            binary = root / "engine-audit"
            sources = [str(ROOT / "Margherita" / (name + ".swift")) for name in dict.fromkeys(SOURCES)]
            subprocess.run([SWIFTC, "-parse-as-library", *sources, str(harness), "-o", str(binary)],
                           check=True, env=ENV, timeout=300)
            subprocess.run([str(binary), str(root)], check=True, env=ENV, timeout=180)


if __name__ == "__main__":
    unittest.main()
