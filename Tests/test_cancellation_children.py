"""Real subprocess regression test, Linux/macOS when a Swift toolchain is installed."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

from test_native_documents_archives import SWIFTC, ENV

ROOT = pathlib.Path(__file__).resolve().parents[1]

class CancellationChildrenTests(unittest.TestCase):
    def test_source_no_main_script_or_unbounded_wait(self):
        for name in ('AppleDocuments.swift', 'OfficeApplications.swift'):
            source = (ROOT / 'Margherita' / name).read_text()
            self.assertNotIn('executeAndReturnError', source)
            self.assertNotIn('DispatchQueue.main.sync', source)
            self.assertIn('/usr/bin/osascript', source)
            for mutation in ('set update links at open', 'set update links at print',
                             'set display alerts', 'close active', 'close every', 'quit application'):
                self.assertNotIn(mutation, source)
        source = (ROOT / 'Margherita/NativeArchives.swift').read_text()
        self.assertNotIn('task.waitUntilExit()', source)
        self.assertIn('token?.register { child.stop() }', source)

    @unittest.skipUnless(pathlib.Path(SWIFTC).exists(), 'Swift compiler not installed')
    def test_real_process_cancellation_and_timeout(self):
        with tempfile.TemporaryDirectory() as folder:
            directory = pathlib.Path(folder)
            main = directory / 'main.swift'
            main.write_text(r'''
import Foundation

let token = ConversionCancellation()
precondition(!token.isCancelled)
let began = ProcessInfo.processInfo.systemUptime
DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { token.cancel() }
do {
    try ConversionCancellation.$current.withValue(token) {
        _ = try NativeProcess.run("/bin/sh", ["-c", "trap '' TERM; exec sleep 20"], timeout: 10)
    }
    fatalError("cancel did not throw")
} catch is CancellationError {} catch { fatalError("wrong error: \(error)") }
precondition(ProcessInfo.processInfo.systemUptime - began < 3)
precondition(token.isCancelled)
// A cancelled token immediately invokes newly registered callbacks, outside its lock.
let late = token.register { token.cancel() }
token.unregister(late)
do { try token.check(); fatalError("cancelled check returned") } catch {}
let timeoutStart = ProcessInfo.processInfo.systemUptime
do {
    _ = try NativeProcess.run("/bin/sh", ["-c", "trap '' TERM; exec sleep 20"], timeout: 0.1)
    fatalError("timeout did not throw")
} catch {}
precondition(ProcessInfo.processInfo.systemUptime - timeoutStart < 3)
let data = try NativeProcess.run("/bin/echo", ["ok"])
precondition(String(decoding: data, as: UTF8.self) == "ok\n")
''')
            binary = directory / 'test'
            subprocess.run([SWIFTC, '-swift-version', '5',
                            str(ROOT / 'Margherita/ConversionCancellation.swift'),
                            str(ROOT / 'Margherita/NativeArchives.swift'), str(main), '-o', str(binary)],
                           check=True, env=ENV, capture_output=True, text=True, timeout=60)
            subprocess.run([str(binary)], check=True, env=ENV, capture_output=True, text=True, timeout=15)
