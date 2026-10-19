"""Office routing/security contracts; real Office scripting still requires a Mac."""
import subprocess
import tempfile
import unittest
from pathlib import Path
from test_native_documents_archives import ROOT, SWIFTC, ENV

SOURCE = ROOT / "Margherita/OfficeApplications.swift"

class OfficeApplicationsTests(unittest.TestCase):
    def test_swift_syntax(self):
        subprocess.run([SWIFTC, "-frontend", "-parse", "-swift-version", "5", str(SOURCE)],
                       check=True, env=ENV, capture_output=True, text=True)

    def test_no_active_or_shell_automation(self):
        source = SOURCE.read_text()
        for unsafe in ["set d to active", "close active", "do shell script", "quit\\n",
                       "run VB macro", "do Visual Basic", "set display alerts"]:
            self.assertNotIn(unsafe, source)
        for required in ["with timeout of 120 seconds", "AppleDocuments.literal",
                         "/usr/bin/osascript", "update links do not update links",
                         "Disable Word automatic link updates",
                         "NativeProcess.checkFile", "AppleDocuments.validateInput",
                         "catch is CancellationError", "engine.rawValue",
                         "!pdf.isEncrypted", "!pdf.isLocked", "pdf.pageCount > 0",
                         "word/document.xml", "NativeArchives.extract",
                         "if boundPrivate then close d saving no"]:
            self.assertIn(required, source)

    def test_routes_typecheck_with_appkit_stubs(self):
        # Compile the entire implementation, not a hand-copied routing function.
        # Replaces only unavailable AppKit APIs; no claim of real AppleScript execution.
        stub = r'''
import Foundation
final class PDFDocument {
    init?(url: URL) {}
    var isEncrypted: Bool { false }
    var isLocked: Bool { false }
    var pageCount: Int { 1 }
}
final class NSWorkspace {
    static let shared = NSWorkspace()
    var installed: Set<String> = []
    func urlForApplication(withBundleIdentifier id: String) -> URL? {
        installed.contains(id) ? URL(fileURLWithPath: "/Applications/mock.app") : nil
    }
}
final class NSAppleScript {
    static let errorNumber = "NSAppleScriptErrorNumber"
    init?(source: String) {}
    func executeAndReturnError(_ error: inout NSDictionary?) -> Int { 0 }
}
enum ConversionCancellation { static func checkCurrent() throws {} }
enum NativeConversionError: Error { case message(String) }
enum NativeProcess {
    static func checkFile(_ url: URL) throws {}
    static func run(_ executable: String, _ args: [String], limit: Int, timeout: TimeInterval) throws -> Data { Data() }
}
enum NativeArchives {
    static func extract(input: URL, to output: URL) throws {}
}
enum AppleDocuments {
    static func validateInput(_ input: URL, work: URL) throws {}
    static func literal(_ value: String) -> String { "\"" + value + "\"" }
}
'''
        harness = r'''
let scenario = CommandLine.arguments[1]
let word = URL(fileURLWithPath: "/tmp/input.docx")
let ppt = URL(fileURLWithPath: "/tmp/input.pptx")
let xls = URL(fileURLWithPath: "/tmp/input.xls")
let pdf = URL(fileURLWithPath: "/tmp/input.pdf")
if scenario == "none" {
assert(!OfficeApplications.supports(input: word, format: "pdf"))
}
if scenario == "iwork" {
NSWorkspace.shared.installed = ["com.apple.iWork.Pages", "com.apple.iWork.Numbers", "com.apple.iWork.Keynote"]
assert(OfficeApplications.supports(input: word, format: "PDF"))
assert(OfficeApplications.supports(input: ppt, format: "pdf"))
assert(OfficeApplications.supports(input: xls, format: "pdf"))
assert(!OfficeApplications.supports(input: pdf, format: "docx"))
}
if scenario == "office" {
NSWorkspace.shared.installed = ["com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint"]
assert(OfficeApplications.supports(input: word, format: "pdf"))
assert(OfficeApplications.supports(input: ppt, format: "pdf"))
assert(OfficeApplications.supports(input: xls, format: "pdf"))
assert(OfficeApplications.supports(input: pdf, format: "docx"))
assert(!OfficeApplications.supports(input: pdf, format: "pptx"))
assert(!OfficeApplications.supports(input: word, format: "xlsx"))
assert(!OfficeApplications.supports(input: URL(string: "https://example.com/a.docx")!, format: "pdf"))
}
'''
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            main = path / "main.swift"
            main.write_text(stub + SOURCE.read_text().replace("import AppKit", "").replace("import PDFKit", "") + harness)
            subprocess.run([SWIFTC, "-swift-version", "5", str(main), "-o", str(path / "test")],
                           check=True, env=ENV, capture_output=True, text=True)
            # Each run models a fresh launch; installed-app discovery is cached per process.
            for scenario in ["none", "iwork", "office"]:
                subprocess.run([str(path / "test"), scenario], check=True, env=ENV, capture_output=True, text=True)

if __name__ == "__main__":
    unittest.main()
