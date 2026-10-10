# Local verification

Tested on macOS 26.6.2 on October 10, 2026. The native release executable is 1,364,144 bytes, approximately 1.4 MB. Native builds, app launch, and screen/system audio permission passed.

The current capture-engine run is recorded in the local `work/verification-v2/media-analysis.json`. Three lossless PNGs loaded and fully decoded: area and window at 1280 × 724, screen at 3420 × 2224. All retained a Display P3 profile. Five HEVC recordings fully decoded with ffmpeg and retained native dimensions:

| Recording | Dimensions | Video duration |
| --- | --- | --- |
| Audio Off | 1280 × 724 | 3.298 s |
| System audio | 1280 × 724 | 3.397 s |
| Selected app audio | 1280 × 724 | 3.430 s |
| Window | 1280 × 724 | 2.110 s |
| Screen | 3420 × 2224 | 1.988 s |

High quality requested up to 60 fps; measured frame delivery remained within that limit and varied with screen updates. Earlier H.264 recordings fully decoded. Current Compatible mode requests up to 30 fps at native dimensions; the latest five-file run above exercised HEVC.

Two separate native audio fixtures emitted 660 Hz and 1120 Hz simultaneously. System audio contained both. Selected-app capture retained 660 Hz and suppressed 1120 Hz by 111.9 dB in the measured one-second segment. The isolation value describes this controlled fixture and segment. Audio Off had no audio track. System/app captures had one stereo AAC track at 48 kHz. The encoder targets 320 kbps; simple test tones produced lower actual bitrates.

The controlled two-track mixing test produced one stereo AAC 48 kHz track, retained both fixture sources, and preserved the compressed HEVC video byte-for-byte. Its proof is retained locally in `work/mix-test-proof.txt`.

Live microphone permission was subsequently approved and the native microphone recording path passed. `~/Movies/Captures/Capture 2026-10-10 at 12.39.22 772B.mp4` contained 1688 × 1440 HEVC at 60 fps, a 26.1967-second video track, and one stereo AAC 48 kHz track lasting 26.1971 seconds. Full ffmpeg decoding passed. The native result preview played the video, Open launched it in QuickTime, and Command + C copied it from the preview.

Direct screenshot copying and an actual image paste into native TextEdit passed. The native toolbar and area state were inspected live; region move/resize geometry passed six checks. Shortcut registration succeeded, and the current source includes both Carbon global handlers and a foreground event fallback.

The workflow provides file-free direct screenshot copying and cache-backed stop-and-copy video without a permanent Movies file. Cache cleanup preserves the currently referenced clipboard file and otherwise removes entries older than seven days. Live area resize produced a 1576 × 1096 clipboard PNG; direct screenshot copying left the Movies file list unchanged. Window selector cancellation and an accessible window selection into preview passed. Foreground Control + Command + Shift +5 stopped into preview; Control + Command + Shift + C stopped and copied video from the area selector. The copied video pasted into Finder with a matching SHA-256 hash and no additional Movies file. Quitting during a 10.76-second window recording finalized and saved a readable HEVC/AAC MP4, and the app then exited. Forced mixing failure retained a finalized video and surfaced the error. A second display, long recordings, and physical global shortcut delivery from another app have not been exercised.

A final exclusion regression check recorded the native toolbar inside an independent self-demo while normal area recordings omitted it. Both fresh HEVC/AAC outputs at 1412 × 1440 fully decoded. The second recording was copied to the clipboard cache, with no matching file in Movies. The full native preview played the first recording. The release ZIP was checked against the current executable and strict code-signature verification passed.

Primary references: [Apple audio filtering](https://developer.apple.com/videos/play/wwdc2022/10155/), [Apple microphone capture](https://developer.apple.com/videos/play/wwdc2024/10088/), [Apple capture sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos), and [Nonstrict’s recording example](https://github.com/nonstrict-hq/ScreenCaptureKit-Recording-example). Sources accessed 2026-10-10. The native application uses Apple frameworks; vendored MIT motion libraries belong only to the local demo playground.
