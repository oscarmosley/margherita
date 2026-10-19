# Conversion research and implementation contract

Research checked 18 October 2026 against the official website, its public interactive demo's format table, App Store description/version history/reviews, press kit, screenshots, and Product Hunt maker comments. No claim of runtime parity is made. The site advertises 275 paths, 26 tools, 6 actions. Website currently says Shift / Command / Control; App Store and older maker comment say Shift / Option+Shift. Margherita keeps the requested Shift and Option+Shift defaults with independent recorders.

Sources

https://tangerineformac.com/
https://tangerineformac.com/assets/home-BU_Sezi2.js
https://tangerineformac.com/press
https://apps.apple.com/us/app/tangerine-file-converter/id6813034065?mt=12
https://www.producthunt.com/products/tangerine-zero-click-file-converter

## Complete advertised conversion matrix

Each line means every input in the left group can target every right-hand format except itself. Input-only formats never appear as outputs. This is the public demo's complete table, not a guessed cross-product of every format on the marketing page.

| Input | Outputs |
| --- | --- |
| JPG, PNG, WebP, HEIC, TIFF, SVG, AVIF, BMP | JPG, PNG, WebP, HEIC, TIFF, AVIF, BMP, PDF |
| MP3, M4A, WAV, FLAC, OGG, Opus, AIFF, WMA | MP3, M4A, WAV, FLAC, OGG, Opus, AIFF, WMA |
| MP4, MOV, MKV, WebM, AVI, WMV | MP4, MOV, MKV, WebM, AVI, WMV, GIF, MP3 |
| GIF | MP4, MOV, MKV, WebM, AVI, WMV |
| PDF | DOCX, Pages, PPTX, XLSX, JPG, PNG, EPUB, TXT, Markdown |
| PPT, PPTX | PDF, JPG, PNG |
| XLSX, XLS, ODS, CSV, TSV | XLSX, ODS, CSV, TSV, PDF |
| DOCX, Pages, Markdown, RTF, RTFD, textClipping | DOCX, Pages, PDF, TXT, Markdown, HTML, EPUB, PNG, JPG |
| EPUB | PDF, DOCX, Pages, TXT, Markdown, HTML |
| TXT | DOCX, Pages, PDF, Markdown, HTML, EPUB, JPG, PNG |
| SRT, VTT | SRT, VTT, TXT |
| ZIP, TAR, GZIP, RAR | ZIP, TAR, GZIP |

Marketing description includes GIF image conversion and SVG among images, but current site explicitly marks SVG input-only and places GIF in video. RAR, PPT, XLS, RTF, RTFD, textClipping are input-only in the demo. App Store review dated Sep 29 says PDF-to-EPUB was not available then; version 2.0 adds EPUB/Office/Pages/spreadsheets, so the older review is not evidence against the current advertised matrix.

## All 26 advertised tools

Compress (images/video/audio/PDF; percentage or target size); metadata read/edit/remove; edit photo; annotate photo; add background; crop image; normalize audio; remove video audio; trim video; split PDF; organize PDF; extract archive; create PDF from images; merge PDFs; crop video; change video speed; join videos; video snapshots; split video; audio visualizer; trim audio; convert audio channels; create collage; redact photo; redact video; bleep audio.

The site mentions QR reading in the App Store prose, beyond the 26 demo tool IDs. Exact target-size compression, arbitrary editing/cropping/trimming/redaction interfaces, metadata editor, collages and visualizer are not part of Margherita v2's requested no-advanced-editing-UI scope. They are documented, never represented by inert buttons.

## All 6 advertised file actions

AirDrop; Float (floating file shelf); Copy; Move; Copy Path; Terminal. Margherita includes Copy Path and Reveal, does not claim the other actions.

## Margherita v4 implementation and dependency audit

The table above is reference-app research, not a claim of identical fidelity. Routes use actual runtime capabilities, and format extensions never stand in for unsupported codecs.

| Source | Local route | Dependency and fidelity |
| --- | --- | --- |
| Images | ImageIO formats, full PDF, Vision OCR TXT/searchable PDF | Runtime decoders/encoders; OCR single-frame input. Optional FFmpeg adds encoders. SVG depends on system decoding, not general vector export; OCR SVG excluded. |
| Audio/video | AVFoundation common MP4/MOV/M4V/M4A/WAV/AIFF/CAF; streaming Core Audio WAV/AIFF/CAF/conditional FLAC | Native routes preferred. MP3/OGG/Opus/WMA/MKV/WebM/AVI/WMV and other absent encoders need optional FFmpeg. FLAC is shown natively only if encoder discovery succeeds; enhancer fallback on writer failure. |
| PDF | TXT/RTF/Markdown/EPUB; DOCX page images plus paragraphs; PPTX page-image slides; XLSX page/line/text rows; PNG/JPG all-page rendering | Vision OCR for text-empty pages. Not editable-layout reconstruction or table recognition. Searchable PDF rasterizes and loses interactive/vector content. PDF Office/OCR bounded to 200 pages, 3200 pixels/page, 8 MB text and 128 MB output. |
| DOC/DOCX/Markdown/RTF/RTFD/TXT/HTML/EPUB | Native textutil/CoreText/PDFKit reflow outputs, PDF, images, textClipping | Formatting/artwork may be lost. Standalone sanitized HTML. No Office layout engine. |
| Pages | Genuine Pages save/export via installed Pages; DOCX/PDF staging | Installed Pages and Automation permission, app may appear. PDF-to-Pages stages recovery DOCX, not original editable layout. No fake Pages ZIP or thumbnail output. |
| Numbers/Keynote | Installed-app XLSX/PDF export then native staging | Installed matching app and Automation permission. No thumbnail-as-document fallback. |
| PPTX | Positioned text and raster-image recovery to PDF, then all-page images | Native simplified renderer, disclosure on each page. Omits themes/masters/charts/vector/group transforms. Installed Keynote preferred for full renderer. |
| PPT | Installed Keynote or optional LibreOffice to PDF/images | No native legacy PPT decoder. |
| CSV/TSV/XLSX/ODS | Native first-sheet imports/exports and PDF; XLS XML export | Cached values only, no formula evaluation/charts/style/multisheet retention. Native ODS supported. Delimited cells defend against formula injection. |
| XLS | Excel 2003 SpreadsheetML XML native; binary BIFF via installed Numbers or LibreOffice PDF | Output action explicitly says XLS (XML), never claims BIFF. BIFF availability gated by installed app. |
| textClipping | Genuine modern Finder UTI-Data binary plist; bounded classic resource-fork input | Plain text only; Finder runtime verification pending. |
| SRT/VTT | Native cue/text conversion | No full positioning/styling or embedded subtitle extraction. |
| ZIP/TAR/GZIP/RAR | System bounded archive creation/extraction/repacking | RAR input depends on system decoder, never output. GZIP with multiple entries is tar.gz. Links/devices/traversal and excessive expansion rejected. |

The six file actions are AirDrop, Float, Copy, Move, Copy Path and Terminal. Main window contains only conversion actions. Editing tools are on the Shift+Option wheel.

No automatic downloads, uploads or remote OCR. Optional FFmpeg/LibreOffice and installed iWork applications are enhancers, never silently installed. iWork automation opens private copies but is not an untrusted-document sandbox. LibreOffice denies network and macros but is not a full filesystem sandbox. Native document/archive parsing is bounded and rejects external entities and traversal.

This source update passed syntax and Linux logic tests, not whole-app macOS SDK typechecking or UI/native-conversion verification. Relevant Mac smoke tests are included and skipped on Linux. Never describe these checks as a successful Mac build.


## Installed-app layout engines

DOC/DOCX/RTF to PDF prefers installed Microsoft Word, then Pages, then isolated LibreOffice, then native text reflow. PPT/PPTX to PDF prefers PowerPoint, then Keynote, then LibreOffice, then simplified native PPTX recovery when possible. XLS/XLSX to PDF prefers Excel, then Numbers, then LibreOffice, then native cached-value recovery when supported. These app exports aim to preserve layout but depend on fonts, application compatibility and print settings; exact fidelity is not guaranteed.

PDF to DOCX attempts installed Word, then LibreOffice with writer_pdf_import, then native recovery. Word for Mac PDF import varies by version and may be unavailable locally. Never approve an online/upload conversion offer if files must stay local; Margherita does not approve those dialogs. No Word/LibreOffice PDF reconstruction is guaranteed to preserve all tables or layout. If those fail or are absent, an already-installed Python/pdf2docx is tried before native recovery. Python must have pdf2docx in its isolated prefix environment; a dedicated venv is detected at ~/Library/Application Support/Margherita/pdf2docx-venv. Nothing is installed automatically. This optional engine has a 200-page input bound, isolated Python imports, denied network, timeout and DOCX validation. pdf2docx is no longer actively maintained by Artifex and is used only if already installed.

The success HUD and history name the engine that actually succeeded, including native recovery when an installed-app export fails. Automation requests happen only during an explicit conversion, never at launch. Denied permissions or app-export errors trigger another available route. Private copies are used and unrelated documents are never intentionally closed. Installed Office/iWork applications are not sandboxed, may show dialogs and follow their own macro/external-link policies. LibreOffice uses a private profile, restrictive macro setting, disabled network and bounded input/output checks.

AppleScript syntax references and fidelity caveats checked during implementation

https://discussions.apple.com/thread/250067807
https://www.macscripter.net/t/converting-excel-to-pdf-via-applescript/58198
https://github.com/jeongwhanchoi/convert-ppt-to-pdf/blob/master/convert-ppt-to-pdf.applescript
https://support.microsoft.com/en-us/word/opening-pdfs-in-word
https://learn.microsoft.com/en-nz/answers/questions/5131892/convert-pdf-to-editable-word-document
https://askubuntu.com/questions/1259632/convert-pdf-to-word-using-libreoffice-in-terminal

App scripting dictionaries, Automation permissions and actual export fidelity require testing with the installed Mac application versions. Linux syntax/source tests do not verify these routes.

Optional dependency API reference https://pdf2docx.readthedocs.io/en/latest/quickstart.convert.html


### v9 video GIF temporal behavior

Native GIF output uses frame-accurate AVAssetImageGenerator requests at 15fps with zero before/after tolerance, max480px, infinite looping and both GIF delay keys. GIF delays use cumulative centisecond rounding. Native clips above30 seconds are rejected, not trimmed; FFmpeg can handle longer clips at15fps/max480px. No output path silently drops the tail. The timing-plan tests run on Linux; the conditional macOS motion test additionally needs local FFmpeg to generate its long-GOP fixture.
