Margherita disk image

Run Make DMG.command on macOS after Build Margherita.command. The installed
Xcode command-line tools used to build the app also provide swiftc for the
artwork renderer. Only Apple-provided tools are used. ZIP packaging is unchanged.

The installer follows Getting Started's tomato, oven-dark, mozzarella and basil
palette, with a warm gradient, glass panel, cream typography and a central arrow.
Finder supplies the actual draggable pizza app icon and Applications shortcut.
The artwork intentionally does not draw duplicate icons. The canvas is 800 by
440 logical points; icon centres are at (220, 242) and (580, 242).

scripts/render-dmg.swift renders background.png and background@2x.png using
AppKit, and tiffutil combines them into a multi-resolution background.tiff.
All three are inside the image's hidden .background directory.
Checked-in artwork/dmg/background.png (800 by 440) and background@2x.png
(1600 by 880) are actual rendered PNG reference assets, not mockup descriptions.
They were generated and visually inspected on Linux. Their optional development
renderer uses Pillow and Liberation Sans; it is never required or invoked by
packaging. The Mac packaging script regenerates matching artwork with native
AppKit typography and the current release version, using only stock Mac tools. The existing
pizza AppIcon.icns is copied to .VolumeIcon.icns; NSWorkspace applies its custom
volume icon, including the Finder custom-icon flag. SetFile is not required.
No app bundle resources, entitlements or signatures are changed.

A temporary writable HFS+ image is mounted at an isolated directory inside
build/.margherita-dmg.*. Finder sets icon view, window bounds, icon positions,
background, text size, and hidden toolbar/status bar/sidebar through the checked-in
AppleScript. The script uses path arguments instead of source interpolation and
a 30-second Apple-event timeout. There are no sleeps or polling loops.

Terminal needs Automation permission to control Finder. Run in a logged-in Mac
desktop session and approve the macOS prompt. A denied request, missing artwork,
missing pizza icon, absent Finder layout file, or failed volume icon prevents
publishing rather than silently producing an unstyled installer. If permission
was previously denied, enable Terminal under System Settings, Privacy & Security,
Automation, Finder, then rerun.

The image is detached before UDZO compression and verified before publication.
Existing destination files and symlinks are never overwritten. Publishing uses
an exclusive hard link on the same filesystem, so concurrent packaging cannot
replace another output. Failed operations attempt to detach and clean up. If
even forced detachment fails, the temporary directory is deliberately retained
rather than deleting files on a mounted volume. Eject it manually before removing
that directory. The built app and source ZIP remain untouched.

Validation

Run python3 -m unittest discover -s Tests -p test_make_dmg.py -v.
Mocked stock commands exercise rendering, Retina assembly, icon setup, mount and
detach ordering, Finder failure, layout persistence failure, compression and
verification failures, cleanup, stuck mounts, existing outputs and publication races.
These are workflow tests, not macOS rendering or AppleScript integration tests.

Before release, run Make DMG.command on a Mac. Open the final image freshly,
check the pizza volume icon, crisp artwork on a Retina screen, readable native
icon labels, alignment and arrow, hidden sidebar/toolbar and no extra visible
files. Close and reopen the Finder window, eject and remount the image, and verify
the layout persists. Drag to Applications and launch the copied app. Check
codesign --verify --deep --strict on both the original and installed app.
Native Finder persistence, visual output, Automation permissions and mounting
cannot be validated on the Linux development host.

This packaging step does not notarise the app, remove Gatekeeper warnings or
change third-party binary licence/source-distribution obligations.
