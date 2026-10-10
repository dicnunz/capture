# Capture playground

Serve this folder locally, then open `index.html` in the Codex in-app browser. Every script and visual asset is included locally. The page makes no external network requests and never uploads imported or pasted media.

Use **Waves** or **Fog** for two restrained animated recording backgrounds. The four scene buttons change demonstration instructions. They do not simulate Capture’s native controls or claim that anything has been captured.

**Play test audio** starts a soft 660 Hz sine wave only after a click. **Stop audio** silences it. Audio starts muted and also stops when a real result is opened or the page is left. To demonstrate app audio, choose the app hosting this browser in Capture’s actual audio menu.

**Copy screenshot** shows an editable paste target. A pasted image opens the actual image preview. **Finish & preview** and **Result** let you open real local screenshots and recordings. Video has native playback controls and starts paused. Back or Escape closes the preview.

Visual code and licenses, accessed 2026-10-10:

- Vanta Waves and Fog, by Teng Bao, MIT: https://github.com/tengbao/vanta and https://www.vantajs.com/. Exact downloaded commit and URLs are in `sources.json`; license is `vendor/VANTA-LICENSE.md`.
- three.js r134, MIT, the version recommended by Vanta’s primary README: https://github.com/mrdoob/three.js/tree/r134. License is `vendor/THREE-LICENSE.txt`.

The visual adaptation keeps Vanta’s actual geometry and shaders. Colors, animation speed, content spacing, and the few controls are tailored to a readable capture demonstration. No photographs, generated imagery, fonts, or remote assets are used.
