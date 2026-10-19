# V9 document, spreadsheet and subtitle audit

This is a Linux helper audit, not a successful Mac app build or a blanket claim that every advertised route works. Run `PYTHONPATH=Tests python Tests/test_v9_documents_audit.py` to rebuild the executable fixtures and regenerate `Tests/v9-documents-audit.json`.

## Evidence

The executable is compiled from actual Swift functions extracted from NativeDocuments.swift, the actual XML reader/writer from LegacySpreadsheet.swift, actual TextClipping.swift, and actual NativeArchives/NativeProcess. Linux adapters replace Darwin with Glibc, the BSD tar executable path, and ditto's ZIP packaging invocation with zip. They do not generate document content or fake conversion success.

The actual native supports() function is executed for the full input/output matrix. Platform-dependent OfficeApplications, AppleDocuments, PDFOffice and NativeSlides capability probes are explicitly disabled in that portable probe, so its Boolean is not the complete Mac route availability. LegacySpreadsheet.supports and TextClipping.supports are real. Unsupported cross-family pairs are in the ledger for completeness, not advertised as supported.

The route ledger contains 554 nonidentity pairs. On this run 27 have real conversion-helper evidence and 527 are mac-untested. Each pass states its scope. The ledger deliberately does not turn support predicates, source strings, throwing platform adapters, or skipped tests into conversion passes. The full app dispatch remains untested on Mac.

Nine test methods run, seven execute successfully and two are skipped for missing macOS frameworks/textutil. Actual tests cover all distinct spreadsheet value routes, OOXML ZIP members and XML, ODS mimetype storage order, XML namespaces and escaping, literal formula-like strings, cached numeric formula results, sparse XLSX cells, second worksheet content in XLSX/ODS/SpreadsheetML, signed numbers, multiline cells, Unicode, spaces, a real binary-plist clipping roundtrip, an EPUB package, and subtitle timestamps. Existing ODS and archive suites also pass, 15 methods total.

## Concrete fixes

- XLSX, ODS and SpreadsheetML no longer silently discard every worksheet after the first. The current values-only export flattens worksheets into one output table, with worksheet label rows. Worksheet boundaries/names are visible, but independent worksheet structure is NOT preserved. This is an explicit fidelity limit, not an Excel-equivalent exporter.
- SpreadsheetML uses the direct values path for XLSX/ODS/TSV/PDF output and native table input for XLS output. The old CSV intermediate inserted apostrophes into formula-like literal strings before packaging them.
- Signed finite numeric data such as -12.5 is no longer mangled by CSV formula protection. Executable-looking strings remain protected in CSV/TSV. Spreadsheet packages always emit literal strings, never executable formulas.
- XLSX formula cells lacking cached results now throw with a recalculate-and-save instruction instead of silently exporting blank values. Cached results are preserved; formulas are never recalculated, translated, or preserved as formulas.
- Combined worksheet row/cell/text budgets and per-cell expansion limits prevent multi-sheet bypasses.
- Spreadsheet image support now reaches the existing native PDF-to-image path for CSV/TSV/XLSX/ODS and XML XLS. It is not hidden merely because no Office app is installed.
- Subtitle conversion now ignores NOTE blocks, rejects impossible minute/second values and overflowing hour fields, and rejects cues ending before they begin.

## Actual dispatch and fidelity

NativeDocuments.convertReporting selects installed Office applications first for Office-to-PDF/PDF-to-DOCX, then sandboxed LibreOffice, optional installed pdf2docx for PDF-to-DOCX, then native recovery. App availability is not proof of successful export. The final engine string should be verified in the Mac UI.

convertNative selects LegacySpreadsheet, permitted iWork, TextClipping, PDFOffice, NativeSlides, then image/PDF, subtitles, spreadsheet values, and general text/rich-text handling. Document-to-image uses the full document PDF, not a Quick Look thumbnail. The current renderer stacks all PDF pages vertically, with a 32-megapixel and 65535-pixel dimension limit. It throws for larger composites rather than returning only page one. This macOS renderer is not runtime-verified here.

Rich input uses real textutil to RTF and NSAttributedString. Rich outputs generally use textutil; PDF uses paginated CoreText. Native HTML output is escaped plain text, not preserved layout. Markdown/EPUB/PDF text exports are reflowed text. EPUB export has a real manifest/spine/NCX and uncompressed first mimetype member; EPUB chapter import uses textutil in spine order. DRM EPUB is unsupported. PDF extraction can invoke OCR on empty-text pages; image-only PDFs therefore depend on actual macOS Vision execution.

SRT/VTT conversion preserves cue text and millisecond timing but does not preserve VTT styling, regions, cue settings, original identifiers, or SRT numbering. It is a timing/text conversion, not a lossless container rewrite.

TextClipping writes a binary UTI-Data property list and reads modern text values or bounded classic resource forks. Rich formatting is not preserved. The portable tests exercise actual writer/reader roundtrip; Finder interoperability still requires Mac confirmation.

## Genuine dependency limits

Binary BIFF/CFB XLS is not decoded natively. BIFFSpreadsheet explicitly documents that no libxls decoder is bundled. Binary XLS requires installed Numbers/Excel or applicable LibreOffice routes. Native .xls OUTPUT is Excel 2003 SpreadsheetML XML, not binary BIFF. Do not label this as native binary XLS support.

Pages/Numbers/Keynote formats require their installed applications and Automation permission for original-app conversion. PPTX/native slide and PDFOffice ownership lies in separate audits. Installed applications may fail, prompt, or reject documents; the portable harness does not emulate them.

No hidden download of a converter, OCR package, Office app, or binary spreadsheet decoder occurs.

## Mac executable follow-up

The same audit file contains two Mac-only executable tests, not checklists: real textutil rich-format exports and text roundtrips, and real extracted CoreText multi-page PDF plus full-height PNG decoded with PDFKit/AppKit. Run them on Mac; failures, particularly any textutil target unsupported by that OS, must be treated as failures and fixed rather than reclassified as passes.

Also build the full application and check routed formats, real iWork/Office documents, mixed scanned PDFs, rich text attributes/images, clipping drag/drop from Finder, EPUB chapter import, PDF page rotation, and the all-page bitmap's visual order. None has been claimed to pass here.

## Parser fixture compile fix and discovery API

The existing Tests/test_apple_legacy_clippings.py now has the shared values entry-point declarations and traps if any platform/shared conversion stub is accidentally invoked. Its real SpreadsheetML and clipping parser assertions pass. Stubs are not counted as conversion evidence.

LegacySpreadsheet.supportsFormat(source:target:) is a pure XML SpreadsheetML discovery API. For that API only, source "xls" means Excel 2003 XML. The compatibility table must label it XLS (XML). Runtime conversion continues to use supports(input:format:) with real-file inspection; nonexistent and binary XLS do not become XML merely because discovery advertises XML support. The fixture verifies both the pure capability results and rejection of a nonexistent input.

## Aggregator route inventory update

The generated canonical inventory is now **Tests/artifacts/v9-documents-routes.json**. The older Tests/v9-documents-audit.json is regenerated as an identical compatibility copy.

It covers the full document/spreadsheet/subtitle source-target matrix, plus separate binary-BIFF/CFB XLS input records and the two special PDF OCR actions. Every route includes a conversion evidence status. Successful portable helpers are explicitly `portable-helper-tested`; all full-app end-to-end statuses remain `Mac-only-untested`. Neither availability predicates nor platform adapters are called end-to-end successes.

For each ordinary route, actual extracted NativeDocuments, LegacySpreadsheet, TextClipping, AppleDocuments, OfficeApplications, PDFOffice and NativeSlides capability predicates are run in two explicit scenarios: no Office/iWork/LibreOffice installation, and all supported applications installed. Only installed-app discovery is supplied by the harness. The real support logic is compiled and executed. The report records UI candidate inclusion separately from these capability predicates; installation-conditioned UI advertising is not an unconditional support claim. Full app execution has not occurred in either scenario.

Binary XLS probes use only a CFB header to test dispatch discrimination. This is intentionally NOT a valid workbook conversion fixture and is explicitly marked untested. XML XLS fixtures, by contrast, undergo actual read/write value conversions.

### Binary XLS feasibility research

Fresh upstream sources reviewed for this follow-up:

- https://github.com/libxls/libxls and https://github.com/libxls/libxls/releases describe a fuzz-tested C **reader** and xls2csv CLI. It cannot produce genuine binary XLS. Bundling it requires C build/link integration for supported Mac architectures and real BIFF corpus tests. Merely checking that xls2csv exists would neither solve XLS export nor preserve worksheet structure.
- https://github.com/jmcnamara/libxlsxwriter creates OOXML **XLSX**, not binary XLS. It cannot fix a .xls export by changing the suffix.
- https://github.com/pyexcel/pyexcel documents an XLS plugin dependent on xlrd/xlwt, requiring an additional Python runtime/plugin stack; it is not a bundled Swift-compatible dependency.
- https://www.libxl.com/ supports true binary XLS read/write but is a separate commercial native dependency, not a drop-in permissively licensed fix for this free converter.

No speculative decoder, renamed XLSX, or unvalidated new runtime has been added. Current XLS exports remain **Excel 2003 SpreadsheetML XML**, with that representation on every XLS target record. Genuine BIFF output needs a deliberately integrated maintained engine (or actual desktop LibreOffice/Excel export with format validation), which must be Mac-tested. Binary XLS input remains dependency-conditioned, not hidden indiscriminately.
