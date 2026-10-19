# v9 conversion audit

This report separates real executable output checks, portable writer/reader checks,
source contracts, and macOS-only integration that cannot run on Linux.
A passing syntax check, routing mock, package skeleton, or nonempty file is not
an end-to-end conversion pass.

The portable audit is complete; native Mac integration remains unexecuted. Do not interpret the compatibility table as a
test report. Its checkmarks mean a route is available with the current installed
codecs/apps, not that every possible file or layout has been tested.

## Evidence categories

Linux end-to-end means production conversion code consumed a generated real input
and its output was decoded independently and checked for content and media
dimensions/duration as appropriate.

Portable component means actual production parser/writer code was executed, but a
macOS decoder, renderer or application step was absent. This is not a complete
Mac conversion pass.

Mac-only untested means the check needs macOS ImageIO, AVFoundation, PDFKit,
Vision, textutil or installed document-app automation. These routes are not
removed merely because this audit environment is Linux.

Required local enhancements are reported separately from defects. Unsupported
codec availability should suppress only routes that need the absent encoder or
application, not routes with a working native implementation.

## Component evidence

Tests/media-audit.json records independently probed media outputs produced by the
production FFmpeg conversion implementation on Linux. These results depend on the
host's actual FFmpeg build; they are not native AVFoundation passes.

Tests/artifacts/v9-documents-routes.json inventories 578 candidates, including 27 portable-helper-tested records and 551 Mac-only-untested records. No full-app end-to-end pass is claimed. Tests/v9-documents-audit.json distinguishes portable native text/spreadsheet
execution from routes that still need a Mac. Its exhaustive candidate pairs include
unsupported pairs, so its row count is not a count of offered conversions.

PDF-ARCHIVE-AUDIT.json and PDF-ARCHIVE-AUDIT.md separate real archive extraction and
portable OOXML/EPUB package writers from unexecuted PDFKit/Vision rendering. BZ2,
XZ and 7z fixtures passed using local libarchive. RAR remains fixture-untested.

ENGINE-AUDIT.md describes the conditional production-engine Mac harness. It checks
real pixels, PCM samples, movie tracks, GIF frames, PDF pages and cancellation when
run on macOS. It is skipped on this Linux host, not marked as a conversion pass.

Reports overlap in helpers and candidate format pairs. Do not sum their route
counts into an application-wide end-to-end pass rate. No claim is made that every
compatibility-table conversion was executed on a Mac.

## Repairs made rather than hiding routes

Movie-to-PCM decodes audio tracks using AVAssetReader instead of attempting to open
a video container as an ordinary audio file. Image conversion no longer silently
shrinks large originals; explicit Resize is separate. Image encoding retries FFmpeg only for profiles it actually supports. PDF page image exports draw the actual page.

GIF sampling uses distinct exact timestamps, 15 fps and proper GIF frame delays.
Native GIF export accepts up to 30 seconds; longer clips are rejected clearly,
not silently truncated. FFmpeg GIF exports preserve the complete clip duration.

PPTX extraction is exposed. Archive creation rejects names its safe extractor
cannot round-trip. Slide text uses CoreText fit checks and continuation pages
instead of silently clipping the remaining text. Native slide rendering still
does not reconstruct themes, grouped transforms, charts or editable Office layout.

## Third-party dependencies are not audit failures

MP3/OGG/Opus/WMA encoding and additional video container/codec exports need local
FFmpeg where macOS lacks an encoder. FLAC depends on a real available encoder.
Pages output needs Pages. Binary legacy XLS needs Numbers or LibreOffice; XML XLS
is a separate native route. Legacy PPT requires Keynote or LibreOffice.
Exact editable reconstruction of arbitrary PDF layouts is not promised by any
native recovery route. Installed application automation remains Mac-untested.

The final FFmpeg inventory records 271 actual conversions and five safety checks.
SVG now attempts full-size AppKit vector rasterization with unsafe/external content
rejected; this new Mac route has not been runtime-verified here.
SpreadsheetML exports flatten multiple worksheets into labeled value rows. They
do not preserve separate sheets, formulas or formatting, and are not binary XLS.
