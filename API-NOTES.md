API compatibility review
========================

Deployment is macOS 13, Swift 5 mode. These choices were checked against Apple's documentation; a real SDK build is still required.

NSEvent global and local monitors, NSPanel's nonactivatingPanel style, NSDraggingDestination callbacks and NSDraggingInfo file-url pasteboards are AppKit APIs predating macOS 13. Global monitor callbacks are observational, not event interceptors. Local monitor returns the original event.

https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:)
https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents(matching:handler:)
https://developer.apple.com/documentation/appkit/nsimage/draw(in:from:operation:fraction:respectflipped:hints:)

SMAppService.mainApp and register/unregister require macOS 13. The project does not use the older deprecated helper-login-item scheme.

https://developer.apple.com/documentation/servicemanagement/smappservice
https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp

AVAsset asynchronous property loading and loadTracks(withMediaType:) are available at the deployment target. AVAssetExportSession.exportAsynchronously is deprecated in macOS 15 but remains available; using the replacement exclusively would raise the deployment target. AVAudioFile performs chunked native PCM decoding/writing.

https://developer.apple.com/documentation/avfoundation/avassetexportsession/exportasynchronously(completionhandler:)
https://developer.apple.com/documentation/avfaudio/avlinearpcmisnoninterleaved

ImageIO's transformed thumbnail decoding applies EXIF orientation. CGImageDestination's supported type list is checked before encoding rather than assuming HEIC is available. PDFKit provides rendering and merging. Core Graphics creates image PDFs; no private Quartz compression-filter API is used.

https://developer.apple.com/documentation/imageio/cgimagesourcecreatethumbnailatindex(_:_:_:)
https://developer.apple.com/documentation/imageio/kcgimagesourcecreatethumbnailwithtransform
https://developer.apple.com/documentation/pdfkit/pdfpage

SwiftUI grouped Forms, LabeledContent and the controls used here are available on macOS 13. No Observation macros, newer onChange overloads, MenuBarExtra dependency, or macOS 14-only content-unavailable view is used.

Reference app research was read from the website, App Store listing and Product Hunt gallery. Its wheel uses warm frosted radial segments, a small centre hub and dark semibold format labels. Papaya uses its own artwork and implementations. Website and App Store descriptions differ in trigger shortcuts and supported features; this project follows the requested Shift/Option interaction and only claims its implemented native formats.

https://tangerineformac.com/
https://apps.apple.com/us/app/tangerine-file-converter/id6813034065?mt=12
https://www.producthunt.com/products/tangerine-zero-click-file-converter
