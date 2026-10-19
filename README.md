<div align="center">
  <img src="Margherita-icon.png" width="160" height="160">
  <h1>Margherita</h1>
  <p>A free, open-source file converter that lives in your menu bar.</p>

  [![Download](https://img.shields.io/badge/download-latest-e8473d?style=flat-square)](../../releases/latest)
  ![Platform](https://img.shields.io/badge/platform-macOS-blue?style=flat-square)
  ![Requirements](https://img.shields.io/badge/requirements-macOS%2013%2B-4a9e3f?style=flat-square)
  [![License](https://img.shields.io/badge/license-GPL--3.0-lightgrey?style=flat-square)](LICENSE)
</div>

Drag a file, pick a slice, done. Margherita converts images, video, audio, PDFs, documents and archives without opening a single window. Everything happens locally on your Mac.

A free, open-source alternative to Tangerine. Not affiliated with Tangerine or its developers.

<img width="480" height="367" alt="Recording 2026-10-19 at 23 57 12-gifconvert" src="https://github.com/user-attachments/assets/f4612118-e4f6-41be-a0de-8d4065f1d6fc" />


<a href="https://buymeacoffee.com/oscarmosley" target="_blank">
  <img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" height="50">
</a>

## Install

Download `Margherita-1.0.0.dmg` from the [latest release](../../releases/latest), open it and move the app into your `Applications` folder.

> [!NOTE]
> Margherita isn't notarised yet, so the first time you open it, right click the app and choose **Open**.

## Usage

1. Start dragging any file.
2. Hold <kbd>SHIFT (⇧)</kbd> to open the conversion wheel, then drop it on the format you want.
3. Hold <kbd>CONTROL (⌃)</kbd> instead for the actions wheel.
4. The converted file appears next to the original.

Both shortcuts can be changed in Settings.

## Features

- [x] Pizza-slice conversion wheel with file size in the centre
- [x] Actions wheel: AirDrop, copy, move, float, copy path, open in Terminal
- [x] Images, video, audio, PDF, documents, spreadsheets, subtitles and archives
- [x] Video to GIF
- [x] OCR for screenshots and scanned PDFs
- [x] Per-format quality and compression settings
- [x] Custom shortcuts and file name suffixes
- [x] Glass or solid wheel style and custom accent colour
- [x] Hide the Dock icon, menu bar icon, or both
- [x] FFmpeg bundled, nothing extra to install
- [ ] File tools (coming soon)
- [ ] Notarised builds
- [ ] Homebrew cask

## Building from source

Margherita only needs Apple's Command Line Tools. Xcode isn't required.

```sh
xcode-select --install
```

Then right click `Build Margherita.command` and choose **Open**. The app is built to `build/Margherita.app`.

## FAQ

### Some Office formats are greyed out
Word, Excel and PowerPoint conversions need [LibreOffice](https://www.libreoffice.org) (free) or Microsoft Office. Exporting to .pages needs Pages. Margherita checks for them each time it launches.

### macOS says the app can't be opened
Right click the app and choose **Open**, or go to System Settings > Privacy & Security and click **Open Anyway**.

## License

Margherita is licensed under [GPL-3.0](LICENSE). It bundles [FFmpeg](https://ffmpeg.org), which is licensed under the GPL.
