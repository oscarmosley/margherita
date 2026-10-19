# v9 PDF, slides and archive execution audit

Audited production source, not compatibility-table checkmarks. Linux tests execute extracted unchanged portable Swift writer functions and NativeArchives with only Darwin → Glibc and /usr/bin/tar → /usr/bin/bsdtar substitutions. That is not a macOS SDK build or a PDFKit/Vision execution claim.

## Executed routes

| Route | Result | Actual validation | Runtime dependencies |
| --- | --- | --- | --- |
| Ordinary folder → ZIP → extracted folder | PASS | Nested 256 KB binary byte equality, OOXML bracket name, ZIP CRC | macOS zip + BSD tar |
| Ordinary folder → TAR → extracted folder | PASS | Independent tarfile listing, nested binary byte equality | BSD tar |
| Ordinary folder → TGZ/GZ/GZIP → extracted folder | PASS | gzip decompression and nested binary byte equality for all three suffixes | BSD tar + gzip |
| ZIP → GZIP | PASS | Repack contains original file rather than nested input ZIP | zip reader in BSD tar + gzip |
| Plain gzip → file | PASS | Independent Python-generated stream, exact output text | gzip |
| DOCX/PPTX/XLSX/EPUB → extracted folder | PASS | Real generated packages extracted by production archive engine, XML parses and CRCs valid | BSD tar |
| Fixed DOCX package generation | PASS | python-docx opens it; two embedded images and full 54,000 UTF-16-unit CJK/emoji sequence, end sentinel | Foundation + zip |
| Editable DOCX package generation | PASS | python-docx opens it; zero image placeholders; full long text and sentinel | Foundation + zip |
| XLSX package generation | PASS | openpyxl opens it; complete long Unicode text split below cell limit; full end sentinel | Foundation + zip |
| PPTX package generation | PASS | python-pptx opens it; two real picture shapes with image blobs; slide count correct | Foundation + zip |
| EPUB package generation | PASS | Actual NativeDocuments writer; first uncompressed mimetype, OPF spine resolves chapter, complete Unicode text and sentinel | Foundation + zip |
| PPTX portable XML reader | PASS | Relationships preserve presentation order, valid media paths, shape text/geometry; hostile XML and traversal rejected | FoundationXML |
| Unsafe archive paths/links/duplicates | PASS (rejected) | No destination committed for traversal, special matcher names, links or duplicates | BSD tar |
| Folder containing non-roundtrippable wildcard name | PASS (rejected) | No output archive produced | Foundation |

The Office fixture images are a tiny valid PNG deliberately supplied to isolate package correctness. They are not presented as proof of PDF page rendering. The EPUB writer is read/extracted from NativeDocuments without editing that other owner's file.

## Mac-only routes, explicitly UNTESTED here

| Route | Status | Dependency / limitation |
| --- | --- | --- |
| PDF → TXT / RTF | MAC-UNTESTED | PDFKit native text, Vision fallback for blank-text pages; AppKit RTF writer |
| PDF → fixed DOCX | MAC-UNTESTED end-to-end; package writer PASS | PDFKit + CoreGraphics/ImageIO raster; page image plus extracted text, not editable layout reconstruction |
| PDF → editable DOCX | MAC-UNTESTED end-to-end; package writer PASS | PDFKit/Vision; text reflow, not original layout |
| PDF → XLSX | MAC-UNTESTED end-to-end; package writer PASS | PDFKit/Vision; page/line/text rows, not table reconstruction |
| PDF → PPTX | MAC-UNTESTED end-to-end; package writer PASS | PDFKit/CoreGraphics; one page image per slide |
| PPTX → PDF native fallback | MAC-UNTESTED rendering; XML reader PASS | AppKit/CoreText/CoreGraphics/ImageIO; deliberately simplified fallback |
| Single-frame image → OCR TXT | MAC-UNTESTED | Vision + ImageIO decoder availability, AVIF conditional |
| Image/PDF → searchable PDF | MAC-UNTESTED | Vision recognition, CoreGraphics invisible text layer |
| PDF → EPUB | MAC-UNTESTED end-to-end; EPUB writer PASS | PDFKit text stage in NativeDocuments |

Existing conditional executable harness in Tests/test_pdf_office.py, NativeOCRMacSmoke.test_real_ocr_pdf_and_office_exports, compiles the production archive/OCR/PDFOffice sources on macOS. It creates selectable, scanned and blank-page PDF fixtures; checks native/OCR page order and searchable text; exports all five PDF Office targets and verifies output ZIP CRCs. It is skipped on Linux, not falsely counted as passing.

NativeSlides rendering still needs a Mac smoke run with representative PowerPoint files, including groups, charts, unusual themes and fonts. Its source explicitly does not implement masters/themes, group transforms, charts, rich runs or vectors. Text overflow now uses actual CoreText visible ranges, smaller fonts and bounded continuation pages; Mac execution remains untested. It should be described as a recovery fallback, not layout preservation. Installed PowerPoint/Keynote/LibreOffice routes are outside this owned-file audit.

## Concrete fixes

NativeArchives now includes PPTX in extractable OOXML input formats. Previously PPTX extraction could execute directly but supports() did not expose the route.

Archive creation now rejects nested names that its safe extractor cannot read back, instead of successfully creating an unusable output. Top-level and nested duplicate-name detection now uses the same Unicode normalization and case folding as extraction.

## Other dependencies and limits

RAR and 7z decoding are claimed only to the extent the installed BSD tar/libarchive supports their actual compression method. RAR remains UNTESTED. A later 7z native libarchive fixture and Bzip2/xz plain-stream fixtures passed; see additional decoder fixtures below. Legacy PPT, encrypted Office and exact editable PDF layout recovery are not implemented by these four files; third-party application routes must handle them or return a clear unsupported error.

Archives reject symlinks, hardlinks, devices, path traversal, wildcard matcher names, duplicates, over 10,000 entries, individual expanded members over 128 MB and aggregate expanded content over 512 MB. Compression output remains capped at 128 MB. GZ/GZIP creation intentionally means gzip-compressed TAR for folder/batch preservation, whereas plain gzip decoding produces one file.

## Reproduce

Install test-only Python readers python-docx, openpyxl and python-pptx, plus Swift and BSD tar. Production application requires none of these Python packages.

Run from repository root:

```sh
python3 -m unittest discover -s Tests -p test_v9_pdf_archives_audit.py -v
python3 -m unittest discover -s Tests -p test_native_documents_archives.py -v
python3 -m unittest discover -s Tests -p test_pdf_office.py -v
python3 -m unittest discover -s Tests -p test_native_slides.py -v
```

Observed result on this Linux host: 22 executed tests passed, 2 Mac-only tests skipped. All four owned Swift files also passed swiftc -frontend -parse. Portable extracted code compiled and ran; full Mac framework typechecking and rendering remain unverified.

## Additional decoder fixtures

Real 7z fixture generation using installed bsdtar --format=7zip and extraction through the production NativeArchives helper passed, with Unicode payload equality. No 7z third-party executable was used. This establishes Linux libarchive 3.7.2 capability, not stock macOS libarchive parity.

Python-generated plain BZ2 and XZ streams also passed production extraction with byte equality. Both standalone fallback executables are installed on this audit host. Plain XZ fallback depends on /usr/bin/xz, which is not guaranteed on a stock Mac. No blanket third-party requirement or hidden route is justified for RAR/7z. RAR remains untested because neither a local fixture nor a RAR writer was available.

## Slide text overflow fix

NativeSlides.drawText checks CoreText visible UTF-16 ranges and binary-searches an 8–18pt font that fits. When 8pt still overflows, it returns the exact unrendered suffix; conversion writes it onto labeled continuation pages after the original slide, rather than discarding it. The effective text box is intersected with the page so off-slide text is recovered too. Continuations are limited to 2000 additional pages with cancellation and progress checks; an impossibly small page fails atomically instead of claiming success with missing content. Output can therefore contain more PDF pages than source slides.

Tests/test_v9_pdf_archives_audit.py now has a conditional executable CoreText test that renders a long text through multiple continuation pages, opens the generated PDF with PDFKit, and checks all recovered characters and a final sentinel. This test was skipped on Linux, not counted as passing. NativeSlides passed Swift syntax parsing and the actual portable XML/relationship harness. Mac framework typechecking and fit/continuation rendering still require the Mac run.

The requested BZ2, XZ and native 7z real fixtures were completed in preceding commit 0b12a26 and rerun successfully here. No external fixture downloads or untrusted executables were used. Local /usr/share and /tmp scans found no RAR fixture; no rar/unrar/7z writer executable exists. RAR therefore stays explicitly untested and offered as codec-dependent, not hidden.
