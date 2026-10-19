V6 checks

On first launch, only Getting Started should appear. Quit and relaunch, no Settings or Home should appear. Reopen the running app, one Settings window should appear. About must select its tab even on a cold settings open. There must be no Home window or paid/trial controls.

Check each Getting Started page inside the stadium outline for clipping, traffic lights and animations. Reopen it from the menu. Grant Home access, restart, confirm it persists, then remove the grant without any file being deleted.

Try all five Settings tabs, a custom shortcut, Glass/Solid, linked sound/haptics, and both Float modes. Close/clear shelves and verify original files are untouched. Check quality/archive compression changes using disposable files. PDF layout Auto should retain installed-app engines; Editable and Fixed intentionally use native routes. Video height is disabled unless FFmpeg is installed.

# Mac-only lifecycle smoke checks

Static guards do not validate AppKit event ordering. Run these on macOS after building.

Quit all old copies before installing. Start with the old version's saved settings window open, quit, then replace the app with this build. Do not delete preferences or saved state, so the migration is exercised.

Launch from Finder with Dock enabled and then disabled. Repeat with menu bar enabled and disabled, including both hidden. The initial launch must show no settings window, conversion window, permission dialog or restored window. Repeat after login with Launch at login enabled, and with a fresh local test user for first launch. A file-open launch should accept files in the background without opening a window.

With the process already running, double-click the app or reopen through Spotlight/Dock. Exactly one Settings window should appear. Open Settings through its menu bar item, Command-comma, the app menu, home settings icon and configured global shortcut. All should focus that same window and preserve its current tab. Close it and repeat, then minimize it and repeat.

Change Accessibility/Input Monitoring only using the explicit permission buttons. No permission prompts should appear just from normal launch. Drag conversion and file-action wheels, convert a disposable file and verify the conversion HUD still works. Explicit Open Margherita and Choose files menu actions must still open the conversion window.

Record the OS version, Dock/menu preferences and exact entry point for any failure. macOS SDK compilation and this smoke check cannot run in the Linux development environment.


## v8 targeted checks

Build and launch v8 after v7 with the old onboarding flag still present. Getting Started must appear once. Quit before dismissing it and relaunch, and it must appear again. Finish or close it, relaunch, and it must stay closed. Getting Started from the menu must still open it. With Dock disabled, close onboarding and confirm the app returns to accessory mode without hiding the menu item.

On the folder-access page, check the single tomato folder silhouette, centered house glyph and restrained glow. There must be no green back tab or translucent overlap artifact.

Compare Glass and Solid over Finder text and a patterned desktop. Glass should visibly blur the background through pale translucent sectors and show a bright rim; Solid should be opaque and flat. Repeat in the onboarding demo. System Reduce Transparency can affect the native blur.

In Formats, click the far right and the empty middle of a row, not just its text. Both must select the format.

In Compatibility, place the mouse over every table and scroll vertically. The single page must move without moving the mouse away. At the minimum Settings window width, all headings including XLSX must fit. Wide output matrices are divided into stacked panels with repeated input labels.


## v9 targeted checks

In Compatibility, each category has exactly one matrix. All output headings appear together, rotated vertically. Check the Documents and Video matrices at the minimum Settings width, with no clipped columns or stacked output panels. Scroll while the pointer is over each table; the page must still move.

Convert a moving short video to GIF. Confirm smooth progression, not repeated keyframes, and loop playback. Run the macOS GIF integration test when FFmpeg is installed to generate the moving fixture. The automated pure sampling tests do not alone prove AVFoundation decodes distinct frames.

Open image/PDF tools and File Actions wheels at minimum and maximum sizes. Check Searchable PDF, OCR Text and Copy Path, plus multi-ring long labels. Long labels must wrap and remain inside their slice. Glass and Solid must still work.
