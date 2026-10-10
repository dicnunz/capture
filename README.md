# Capture

A small native macOS screenshot and recording tool with independent app audio and a quick clipboard workflow. It uses a familiar capture toolbar and Apple’s ScreenCaptureKit, with no third-party runtime dependencies in the native app.

[Watch the real app demo](docs/demo.mp4).

[Download the Mac build](https://github.com/dicnunz/capture/releases/latest) or build from source below. The prebuilt preview is for Apple silicon, ad-hoc signed, and not Apple notarized.

## Build and run

Runs on macOS 15 or later. Building requires Xcode 26 or its Command Line Tools, including the macOS 26 SDK and a Swift 6 toolchain. From the repository root:

```sh
./script/build_and_run.sh
```

The script builds `outputs/Capture.app` and opens it. Allow **Screen & System Audio Recording** when macOS asks. Microphone permission is requested only when you choose a microphone. The local app bundle is ad-hoc signed; it is not Apple notarized.

## Capture

| Action | Shortcut or gesture |
| --- | --- |
| Open or dismiss the toolbar; stop and save a recording | **Control–Command–Shift–5** |
| Copy a screenshot; stop and copy a recording | **Control–Command–Shift–C** |
| Select an area | Drag, then move the selection or resize its edges |
| Save the selected area | **Return** |
| Copy the selected area without saving a file | **Command–C** |
| Record the selected area | **Command–R** |
| Capture a window | Choose Window, hover a window, then click to save |
| Record a window | Choose Window, hover a window, then **Command–R** |
| Copy from the result preview | **Command–C** |
| Open the result in its default app | **Return** |

**Escape** dismisses the toolbar or selector and cancels a countdown. Options contains capture delay, recording cursor/click controls, and quality. The selected area and audio source are remembered.

Screenshots copied directly to the clipboard create no file. Saved captures go to `~/Movies/Captures`. Stop-and-copy recordings use a temporary cache so their clipboard file stays readable, without creating a Movies file. Save a permanent copy when you need one; cache files older than seven days may be removed, except the file currently referenced by the clipboard.

## Audio and quality

Choose **Off**, **System audio**, **Microphone only**, or one running app independently of the screen, window, or area being recorded. App audio includes that app’s **entire audio output, including other windows and tabs**. You can add a selected microphone to system or app audio; the finished recording combines both into one playable audio track.

- Screenshots: lossless PNG at native pixel dimensions. On macOS 26, screenshots preserve the display’s color space.
- High quality recording: native dimensions, SDR HEVC, up to 60 fps.
- Compatible recording: native dimensions, SDR H.264, up to 30 fps.
- Audio: 48 kHz AAC, with 320 kbps target bitrate for system/app audio and 192 kbps for a microphone. Combined audio uses a stereo mix.

Actual frame delivery depends on screen updates and hardware. Capture does not currently offer HDR recording or screenshots, annotation, scrolling capture, or a video editor.

## Scope and references

Capture focuses on a familiar native capture flow, explicit audio sources, and copying results quickly. [QuickRecorder](https://github.com/lihaoyun6/QuickRecorder) already offers a broader ScreenCaptureKit recorder; [CleanShot X](https://cleanshot.com/features) provides a mature capture, editing, and sharing workflow; [Shottr](https://shottr.cc/) specializes in screenshots and annotation; [OBS](https://obsproject.com/kb/macos-desktop-audio-capture-guide) already supports independent app audio. This project does not claim better overall capability or benchmarked image quality than those tools.

The interaction reference is [Apple’s screenshot flow](https://support.apple.com/en-us/102646) and [screen recording flow](https://support.apple.com/en-us/102618). Apple already supports lossless SDR PNG and HDR capture on supported macOS 26 models. Sources accessed 2026-10-10.

## Local demo playground

`outputs/playground/index.html` provides local Waves/Fog backgrounds, a soft test tone, and real clipboard/file previews for recording demonstrations. It makes no external network requests and uploads nothing. Its motion libraries are separate from the native app and retain their MIT notices in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Release verification

The local release checks and measured audio isolation are recorded in [Verification](docs/Verification.md).

Before publishing a build, verify the exact source revision with all of these:

- A clean build and real native screen, window, and area flows, including selection, Escape, and global shortcuts.
- A valid playable demo recorded with the app, with actual screenshot and recording results shown.
- Clipboard-only screenshots create no file; copied recordings remain pasteable without a permanent Movies file.
- Two distinguishable audio sources demonstrate that app capture includes the selected source and excludes the other; combined microphone audio plays normally.
- Recordings survive stopping, quitting, and a failed save or audio postprocess.

Capture’s original code is [MIT licensed](LICENSE).
