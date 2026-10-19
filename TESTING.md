Mac acceptance checks, not yet executed
======================================

Build with Build Margherita.command on a real Mac with Command Line Tools. If Xcode is available, also build Debug and Release. Run Product > Analyze. Check both Apple silicon and Intel if distributing to both.

Start without permissions. Choose files and the main drop zone must work. Deny monitoring access and make sure the app remains usable. Grant access, restart, then drag a Finder file and hold Shift. Verify the wheel accepts a drop on every segment, stays still, hides after a drop or Escape, and does not interrupt a normal Finder move. Try Option, Shift-Option, multiple monitors, full screen, edges and Reduce Motion.

Try HEIC to JPG, a rotated iPhone photo, transparent PNG to JPG, JPEG to PNG/TIFF/GIF, animated GIF to GIF, resize with a 720px longest edge, and metadata stripping. Confirm original orientation and dimensions, white JPEG transparency background, and metadata with Preview's Inspector. HEIC export must either work or give a readable error.

Convert short MP4/MOV clips and MP3/M4A/WAV inputs. Check MP4, MOV, M4A, WAV and AIFF outputs in QuickTime. Try silent video, corrupt media, unsupported codecs and cancellation during export. Never install an incomplete file as a completed output.

Merge two PDFs with distinct page counts. Check ordering and dimensions. Export pages to images, including a rotated page. Compress only after the rasterization warning. Verify page appearance and loss of searchable text is disclosed. Test password-locked and malformed files.

ZIP single files, folders, mixed input types and duplicate basenames. Open with Archive Utility and verify payload contents. Filenames with spaces, apostrophes and shell characters must remain plain names. No file is executed.

Try each output location, empty and nonempty suffix, and Unique/Skip/Replace collisions. Originals must never be overwritten. Batch-convert same-basename inputs from different folders to one output folder under Replace. Every result must have a distinct path. A target directory containing an input must be refused.

Undo ordinary and replaced outputs. Cancel the Undo confirmation. Edit an output (including an image inside an exported PDF-pages folder) and verify Undo refuses. Check that a previous replaced output returns after Undo. Simulate a failed/interrupted replacement and inspect the Recovery journal manually before restarting.

Hide both Dock and menu bar. Reopen through Finder and the configured global shortcut. While main/settings is open, confirm the application menu, Settings and Quit work; close them and confirm accessory mode returns. Close all windows and reopen from Applications. Change light/dark/system appearance, all accents and wheel sizes. Verify permissions and chosen folder still work after restart. Enable login only from Applications, sign out/in, and check OS approval where required. Enable and deny notifications and check that denial does not affect conversion.

Quit during a batch must be refused until cancelled/finished. Start another batch after the first; old progress must not overwrite the new batch's status. Repeat with large files, low disk space and read-only destination directories.

CLT-only build checks
=====================

Run python3 Tests/test_build_app.py on any platform for mocked bundle-assembly tests. These do not type-check Swift or create a runnable Mac app. On a Mac with only Command Line Tools selected, double-click Build Margherita.command and confirm build/Margherita.app launches with its icon. Also try MARGHERITA_UNIVERSAL=1 bash scripts/build-app.sh and inspect the binary with lipo -info. Confirm the Dock/menu bar toggles still work; the source plist intentionally has no LSUIElement setting, and the script preserves that behaviour.


V2 smoke checks
===============
Build using Build Margherita.command with current CLT. Confirm the menu icon is a
pizza slice in both light and dark mode. Confirm main-window settings opens.
Hide both icons, then reopen via Spotlight and the recorded global shortcut.
Record Control+Option and a modifier+letter combination; test both during Finder
drag and confirm Shift+Option opens Tools, not Convert. Verify trigger release
keeps the wheel stable. Test 8, 9, 18 actions at both wheel sizes.
Try accent picker/hex/swatches, suffix migration, sound toggle and Reduce Motion.
Convert disposable image, video, audio, text document, EPUB, XLSX, CSV, SRT and PDF.
Check full multipage PDF exports, PDF text reflow caveat and scanned-PDF failure.
Create, extract and repack ZIP/TAR/GZIP; reject traversal and symbolic-link archives.
Test optional FFmpeg absent/present and optional LibreOffice present/absent.
Test cancel, keep-both/skip/replace and Undo before trusting real files.

V3 smoke checks
===============
Drag a Finder file with Control and test all six file actions on disposable copies. Float should add a shelf, pin left/right, accept extra files and drag references out. Removing or clearing a shelf item must not delete it. Copy should paste in Finder. Copy Path should preserve whitespace. Move must ask and not overwrite; include duplicate basenames, folder-plus-child selections, symlinks, a destination inside a selected folder and permission failures. Check rollback Details and Copy for the full recovery paths.

The new wheel should align drawing and hit-test labels across light/dark, 320-460px, one/two rings, paging, and monitor edges. File size belongs in the hub until hovering an option. Confirm gap drops choose the adjacent sector.

Close the main window, convert from the wheel, and confirm only the small HUD appears. Test Cancel, success, short errors and long error Details. Test every ODS/CSV/TSV/XLSX route and multiple-page document PNG/JPG exports. Verify literal spreadsheet values are not interpreted as formulas and large document images fail with a useful limit.
