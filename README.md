# SubDub for Final Cut Pro

Automatic subtitles and voice-over for **Final Cut Pro**: a panel inside FCP that transcribes the speech in a whole project, translates it into other languages, and adds the result as caption roles and/or dubbed audio. It all runs **offline, on your Mac**, using Apple's built-in speech recognition (SpeechAnalyzer) and Translation frameworks. There are no cloud services, API keys or subscriptions.

- Transcribes the whole timeline: clips, connected clips, compound clips, multicam and synchronized clips.
- Translates captions into about 20 languages: English, Thai, Chinese, Japanese, Korean, Spanish, German, French and more.
- Each language is added as its own caption role (iTT), on frame boundaries.
- **Voice-over (dub):** translated lines are spoken by on-device Apple voices and fitted to the original timing. Each language becomes its own audio role (`Dub English`, `Dub Thai`, …). The original audio can be kept, lowered while the dub speaks, or muted.
- Also writes `.srt` files for YouTube and other platforms, plus a `.wav` file per dubbed language.

## Install

1. Download `SubDub-x.y.pkg` from [Releases](../../releases) and open it.
2. Restart Final Cut Pro.
3. Choose **Window ▸ Extensions ▸ SubDub**.

> If macOS says the installer is from an unidentified developer, open
> **System Settings ▸ Privacy & Security** and click **Open Anyway**.

**Requirements:** macOS 26 or later (Apple Silicon or Intel) and Final Cut Pro 11 or later.

## Usage

1. Drag a project from the Final Cut Pro browser into the panel.
2. Choose what to create (**Subtitles**, **Voice-over** or both), the spoken language and the target languages.
3. For voice-over, choose **Female** or **Male**, adjust the voice per language if you like (🔊 previews it), and choose what happens to the original audio.
4. Click **Create**.

Final Cut Pro imports a copy of the project named "… — subtitles + dub (ru, en, th)" into the same library and event, with one caption role and one dub audio role per language. Your original project is not touched. Files are also saved to `~/Movies/SubDub/`.

The first time you use a language, macOS downloads its speech or translation model once. After that, everything works without an internet connection.

### Notes

- **One caption language at a time in the viewer.** This is how closed captions work in Final Cut Pro. To switch languages, open Timeline Index ▸ Roles ▸ Captions. When you export (File ▸ Share ▸ Roles), you can embed several languages in one file or export each language as a separate sidecar file.
- **Voices.** Apple's default voices are compact. For much better quality, download *Enhanced* or *Premium* voices in System Settings ▸ Accessibility ▸ Read & Speak (Spoken Content on older macOS): click ⓘ next to System voice, or temporarily set System speech language to the language you need and pick a voice to download. Siri voices work only in the SubDub app with Xcode installed; see *Siri voices* below. They show up in the panel automatically. Out of the box many languages only have a female voice; if the chosen gender isn't installed, the panel says so and uses another voice.
- **Voice-over is not voice cloning.** The dub uses a system voice, not the speaker's own voice, and there is no lip sync.
- **Font size can't be changed.** The iTT format lets the viewer's player decide the font and size.
- **Workflow extensions can't edit an open timeline.** That's why the captions arrive in a copy of the project.
- **Punctuation can be missing.** Some on-device models, such as Russian, return no punctuation. Sentences are then split at pauses in the speech.
- **Retimed clips are skipped.** Audio from clips with speed changes isn't transcribed yet, and the panel shows a warning.

## Build from source

Requires Xcode 26 and Final Cut Pro installed. `ProExtension.framework` is linked from Final Cut Pro and is not redistributed.

```bash
./build.sh install   # build and install on this Mac (~/Applications)
./build.sh pkg       # build the installer: build/SubDub-<version>.pkg
Tests/run.sh ru-RU en               # end-to-end test on a sample project, without Final Cut Pro
SUBDUB_DUB=1 Tests/run.sh ru-RU en  # same, with English voice-over
```

Signed and notarized build (requires an Apple Developer ID):

```bash
xcrun notarytool store-credentials subdub --apple-id you@example.com --team-id TEAMID
DEV_ID_APP="Developer ID Application: Your Name (TEAMID)" \
DEV_ID_INSTALLER="Developer ID Installer: Your Name (TEAMID)" \
NOTARY_PROFILE=subdub ./build.sh pkg
```

### Siri voices (SubDub app + Xcode)

macOS only lets programs signed by Apple use **Siri voices**, so the panel inside Final Cut Pro can't offer them. The **SubDub app** can, by running a small helper through Xcode's Swift interpreter, which is Apple-signed. Xcode must be installed.

1. In the Final Cut Pro panel, drop your project and click **Open in App**. The project and your choices move to the SubDub app.
2. In the app, Siri voices you have downloaded appear in the voice list, e.g. **Voice 1 (Thailand) · Siri**, and are preferred for the chosen gender.
3. Click **Create**. The result is imported into Final Cut Pro as usual.

Download Siri voices in System Settings ▸ Accessibility ▸ Read & Speak: set System speech language to the language you need, open the System voice menu and pick a Siri voice. Afterwards you can set the language back.

From the command line, `Tools/siri-revoice.sh --list` shows the Siri voices, and `Tools/siri-revoice.sh "<SubDub output folder>" th Male` re-voices an existing `dub-th.wav`. The original is kept as `dub-th.apple.wav`.

### Project layout

| Path | Contents |
|---|---|
| `Sources/Core` | FCPXML parsing, audio mixdown, transcription, segmentation, translation, voice-over, caption writing |
| `Sources/UI` | SwiftUI panel, shared by the extension and the app |
| `Sources/Extension` | Final Cut Pro workflow extension entry point |
| `Sources/App` | SubDub app: contains the extension, runs the panel standalone with Siri voices |
| `Sources/CLI` | Command-line test tool |
| `Installer` | Installer scripts and resources |
| `Tools` | `siri-revoice`: the Siri voice helper used by the app, also usable from the command line (needs Xcode) |
| `Tests` | Sample project with synthetic Russian speech and an end-to-end test script |

## Uninstall

```bash
Installer/uninstall.sh
```

## License

[MIT](LICENSE) © 2026 Roman Kolychev
