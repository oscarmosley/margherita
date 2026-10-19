Margherita 1.0.0 release checks

Build on macOS 13 or newer with Build Margherita.command. This source was
edited and tested on Linux, which cannot compile against the macOS SDK.
A syntax pass is not a native build or a UI/runtime test.

Getting Started

An app download does not clear the app's saved preferences. The completion
flag is onboardingCompletedV2 in the com.oscar.margherita preferences domain.
The launch delegate shows onboarding when that flag is absent or false.
Closing or finishing onboarding sets it; merely presenting it does not.

To test that first-run path without resetting other settings, quit every
running Margherita copy, then run in Terminal

    defaults delete com.oscar.margherita onboardingCompletedV2

A message saying the key does not exist means it is already unset.
Open Margherita.app from Finder. Getting Started should appear. Quit before
closing/finishing it, then open again; it should still appear. Close or finish
Getting Started, quit, and reopen; it should no longer appear. The existing
Getting Started menu item still lets you open it deliberately.

This tests the onboarding flag, not a truly fresh install's permission state.
For a full clean-install test, use a separate macOS local user that has never
run the app. Verify first launch, folder access, permissions and conversion
with that user's actual files.

Safety and cancellation

Use disposable copies for all destructive-rule or undo checks. Test spaces,
accents, emoji, uppercase extensions, no extension, symlinks, read-only
folders, duplicate basenames and a deliberately occupied output path.
Originals must remain untouched unless a watch rule explicitly requests
deletion after successful conversion.

Start a multi-page searchable PDF, then cancel immediately and mid-page.
Repeat with a large video. A stale worker must not overwrite a newer HUD.
Completed outputs may remain; partial staging files must be removed.
Office apps already handling an AppleEvent can finish after cancellation.
Do not force-quit someone else's Office app to make a cancellation look fast.

Test recovery by disabling both Dock and menu bar icons, closing Settings,
then reopening Margherita.app from Finder or Spotlight. Settings must be
recoverable without requiring the configured keyboard shortcut.

Run the full Python suite on the source checkout

    python3 -m unittest discover -s Tests

Some tests compile extracted production Swift helpers or run real FFmpeg.
Conditional tests marked macOS-only still require the Mac to run. Source
contracts alone do not prove native conversion, FSEvents delivery, Sparkle
updating, activation behavior, code signing or visual appearance.

Drag-install disk image

After building, double-click Make DMG.command. It uses stock macOS tools to
package build/Margherita.app and an Applications shortcut into a compressed,
read-only Margherita-1.0.0.dmg in the source folder. The version is read from
the built app. Existing images are never replaced; move an older image first.
The app's signature is verified before packaging, and the resulting image
is verified before publication. Packaging never changes the source ZIP.

Open the image, drag the app into Applications, eject, and launch the installed
copy. The volume is named "Margherita 1.0.0" and carries the pizza icon. Native
AppKit renders the custom Getting Started-style background at 1x and 2x.
Finder automation sets icon positions, window size and hidden chrome on a
temporary writable image before compression. Allow Terminal to control Finder
when macOS asks. See DMG-INSTALLER.md for layout and permission checks.
No third-party packaging tools are required.

A DMG does not bypass Gatekeeper or replace Developer ID signing/notarisation.
Before distributing a DMG containing downloaded codec tools, satisfy their
exact corresponding-source and third-party-notice requirements.
