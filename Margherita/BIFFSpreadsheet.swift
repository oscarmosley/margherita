import Foundation

/// Binary BIFF/CFB is intentionally not parsed with an incomplete home-grown decoder.
/// libxls is maintained and fuzzed but needs a separately built C dependency; it is not bundled.
/// Route .xls through installed Numbers / LibreOffice in the integration layer.
enum BIFFSpreadsheet {
    static let requiresApplicationMessage = "Legacy XLS requires installed Numbers or LibreOffice. No native binary XLS decoder is bundled."
    static func isLegacyWorkbook(_ input: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: input)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 8) ?? Data()
        return header == Data([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1])
    }
}
