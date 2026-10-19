# Sparkle release setup

The CLT builder downloads the official universal Sparkle 2.10.0 distribution, verifies its pinned SHA-256 against the GitHub release asset digest, probes Swift import for each requested architecture, links with an executable-relative Frameworks rpath, preserves framework symlinks with ditto, copies its complete LICENSE, and signs helpers inside-out before signing the app. No Xcode download is needed for this route. Offline/download/import failures explicitly build without Sparkle instead. Set MARGHERITA_SPARKLE=0 to skip downloading. MARGHERITA_UNIVERSAL=1 builds Intel and Apple Silicon.

Xcode/project.yml builds currently use the conditional no-Sparkle fallback. The pinned binary integration is implemented in scripts/build-app.sh, not Swift Package Manager. Do not assume the Xcode route embeds Sparkle.

The repository has no real owner/repository or signing key yet. SUFeedURL deliberately contains REPLACE_OWNER/REPLACE_REPOSITORY and SUPublicEDKey is a placeholder. UpdateController refuses to create or start Sparkle until both are configured. Automatic checks and automatic downloads default off; no broken background requests are sent. The auto-check toggle uses Sparkle's own persisted preference, not a second custom preference.

## Before the first public updater-enabled build

Run the CLT build once on a Mac. The verified distribution and tools are in build/dependencies/sparkle-2.10.0/distribution. From that directory run bin/generate_keys once. Keep the private key in the login Keychain and back it up securely offline; never commit or upload a private key. Copy only the printed base64 public key into SUPublicEDKey.

Replace the two repository placeholders in SUFeedURL with the actual GitHub repository. The intended stable URL is https://github.com/OWNER/REPOSITORY/releases/latest/download/appcast.xml. Set both values in Margherita/Info.plist, scripts/generate_project.py, and project.yml so regeneration does not undo configuration. Keep the first release's CFBundleShortVersionString and CFBundleVersion at 1.0.0. Increase CFBundleVersion for every later update.

Confirm a public release really contains appcast.xml at that URL before distributing a configured build. The download archive URLs in that feed must be immutable version-tag URLs, not /latest/. Serve everything over HTTPS. Enable automatic checking only by explicit user choice; automatic downloads remain off by default.

## Publishing

The local builder produces an ad-hoc signed app, not a notarized distribution. For public releases use Developer ID signing and notarization and sign Sparkle's nested helpers correctly with the distribution identity (including their required hardened runtime options and entitlements). Prefer Apple's archive/export distribution workflow per Sparkle's documentation; do not treat the local ad-hoc build script as a notarization pipeline.

On macOS, archive the finalized, signed and notarized app with symlinks intact, for example:
    
    ditto -c -k --sequesterRsrc --keepParent build/Margherita.app updates/Margherita-1.0.1.zip

Run bin/sign_update updates/Margherita-1.0.1.zip to obtain the EdDSA signature and exact length for a hand-authored enclosure, or preferably run bin/generate_appcast --download-url-prefix https://github.com/OWNER/REPOSITORY/releases/download/v1.0.1/ updates/ to generate appcast.xml and signatures using the Keychain key. Check bin/generate_appcast --help for the pinned tool's complete options. Do not alter an archive after signing it.

Upload the ZIP and generated appcast.xml as GitHub release assets with their exact names. If generating delta updates, upload those too and verify each URL; older archives/deltas need URLs for the release where they are actually hosted. For a simple first setup, generate the appcast from only the new full archive to avoid incorrect historical URL prefixes. Make the release public and non-prerelease so GitHub's latest endpoint resolves. Validate appcast XML, EdDSA signature, byte length, version and all enclosure URLs before publishing.

Test a real upgrade from a lower-version installed app on both architectures. Test manual checking, opt-in/out persistence, offline errors, cancellation, relaunch, bad signature rejection and Gatekeeper/notarization. No native Mac build or live upgrade was performed in the Linux development sandbox.

## Lifecycle API

Call UpdateController.shared.start() after applicationDidFinishLaunching.
Use checkForUpdates() for menu actions. Bind UI enabled state to canCheckForUpdates and automatic-check settings to automaticallyChecksForUpdates. The controller is @MainActor and ObservableObject. isConfigured and statusMessage explain unavailable builds; automaticallyChecksEnabled is published for redraws. A manual action on an unconfigured build shows a local explanatory alert, not a request.

## Sources checked

https://sparkle-project.org/documentation/
https://sparkle-project.org/documentation/programmatic-setup
https://sparkle-project.org/documentation/api-reference/Classes/SPUUpdater.html
https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0

The chub catalog had no Sparkle documentation; official documentation and the pinned binary headers were consulted instead. Download SHA-256 is c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c.
