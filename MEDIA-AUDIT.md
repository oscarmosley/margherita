Real media audit, v9

The Linux run compiled the complete production ExtendedMedia.swift with Swift 6.0.3 in Swift 5 language mode. Only executable discovery was redirected from the Homebrew candidate to /usr/bin/ffmpeg. ConversionOptions and the app error type were minimal Foundation-only stubs. Actual profile selection, capability parsing, argv construction, process execution, staging and installation ran unchanged.

FFmpeg 6.1.1 supplied all 20 output profiles. Tests/media-audit.json records 276 passing checks, comprising 271 real conversion routes and five rejection/preservation checks. No profile was unavailable and no matrix route failed.

Generated sources cover all nine audio formats, seven video containers, GIF, WebP, AVIF, BMP, PNG, JPEG, TIFF, a literal frame%03d.jpg filename, and silent MP4. Every video-container source includes generated moving video and a sine-wave audio stream. Sources are encoded through production profiles before being converted again. All seven video sources extract successfully to every audio target, including WAV, AIFF and CAF.

Each output is inspected with ffprobe for its actual codec, stream kinds, dimensions, audio channel/sample-rate validity and, where meaningful, duration and frame rate. Every output then undergoes a complete strict FFmpeg decode. Video-container conversions check audio retention. GIF checks use frame count divided by duration rather than FFmpeg's misleading avg_frame_rate field, which can report the inverse minimum frame delay for alternating 6/7-centisecond frames.

The rejection checks cover directories, a network-referencing playlist, corrupt audio, existing-destination preservation, and extracting audio from a silent movie. A literal percent-pattern JPEG is converted without interpreting its name as an image sequence.

Production hardening removes the image2 input demuxer, whose default numbered-filename semantics can read adjacent files, and removes the pipe input protocol. JPEG inputs explicitly select jpeg_pipe because otherwise probing sometimes chooses image2. The remaining whitelist retains normal single-file PNG/TIFF/BMP/WebP/AVIF/GIF and all tested media containers. No action was hidden or removed.

The existing GIF suite also passed its four Linux-executable checks, including a real 31-second moving GIF that retains the full duration at 15 fps and at most 480 pixels. Its macOS integration test was skipped. Native GIF's separate 30-second cap is unchanged.

NativeAudio.swift parsed successfully. Its actual AVFoundation/Core Audio round-trip test was skipped because this environment is Linux. No native-audio production change was needed or made. Native movie-audio extraction, app dispatch, AppKit lifecycle, Apple encoder availability, and full macOS app compilation are not proven by this media harness. Those require a Mac run. The matrix does not claim every codec variant, malformed file, HDR/color profile, multichannel layout or quality-option combination.

Reproduce with python Tests/test_v9_media_audit.py, python Tests/test_native_audio.py and python Tests/test_v9_gif.py. The first command regenerates the machine-readable route artifact.
