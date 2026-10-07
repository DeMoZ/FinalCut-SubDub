# FCP AutoSubs

Automatic subtitles for **Final Cut Pro**: a panel inside FCP that transcribes the speech in a whole project and translates the captions into other languages. It all runs **offline, on your Mac**, using Apple's built-in speech recognition (SpeechAnalyzer) and Translation frameworks. There are no cloud services, API keys or subscriptions.

- Transcribes the whole timeline: clips, connected clips, compound clips, multicam and synchronized clips.
- Translates captions into about 20 languages: English, Thai, Chinese, Japanese, Korean, Spanish, German, French and more.
- Each language is added as its own caption role (iTT), on frame boundaries.
- Also writes `.srt` files for YouTube and other platforms.

## Install

1. Download `FCP-AutoSubs-x.y.pkg` from [Releases](../../releases) and open it.
2. Restart Final Cut Pro.
3. Choose **Window ▸ Extensions ▸ Auto Subtitles**.

> If macOS says the installer is from an unidentified developer, open
> **System Settings ▸ Privacy & Security** and click **Open Anyway**.

**Requirements:** macOS 26 or later (Apple Silicon or Intel) and Final Cut Pro 11 or later.

## Usage

1. Drag a project from the Final Cut Pro browser into the panel.
2. Choose the spoken language and the subtitle languages.
3. Click **Create Subtitles**.

Final Cut Pro imports a copy of the project named "… — subtitles (ru, en, th)", with one caption role per language. Your original project is not touched. Files are also saved to `~/Movies/FCP AutoSubs/`.

The first time you use a language, macOS downloads its speech or translation model once. After that, everything works without an internet connection.

### Notes

- **One caption language at a time in the viewer.** This is how closed captions work in Final Cut Pro. To switch languages, open Timeline Index ▸ Roles ▸ Captions. When you export (File ▸ Share ▸ Roles), you can embed several languages in one file or export each language as a separate sidecar file.
- **Font size can't be changed.** The iTT format lets the viewer's player decide the font and size.
- **Workflow extensions can't edit an open timeline.** That's why the captions arrive in a copy of the project.
- **Punctuation can be missing.** Some on-device models, such as Russian, return no punctuation. Sentences are then split at pauses in the speech.
- **Retimed clips are skipped.** Audio from clips with speed changes isn't transcribed yet, and the panel shows a warning.

## Build from source

Requires Xcode 26 and Final Cut Pro installed. `ProExtension.framework` is linked from Final Cut Pro and is not redistributed.

```bash
./build.sh install   # build and install on this Mac (~/Applications)
./build.sh pkg       # build the installer: build/FCP-AutoSubs-<version>.pkg
Tests/run.sh ru-RU   # end-to-end test on a sample project, without Final Cut Pro
```

Signed and notarized build (requires an Apple Developer ID):

```bash
xcrun notarytool store-credentials fcpas --apple-id you@example.com --team-id TEAMID
DEV_ID_APP="Developer ID Application: Your Name (TEAMID)" \
DEV_ID_INSTALLER="Developer ID Installer: Your Name (TEAMID)" \
NOTARY_PROFILE=fcpas ./build.sh pkg
```

### Project layout

| Path | Contents |
|---|---|
| `Sources/Core` | FCPXML parsing, audio mixdown, transcription, segmentation, translation, caption writing |
| `Sources/UI` | SwiftUI panel, shared by the extension and the app |
| `Sources/Extension` | Final Cut Pro workflow extension entry point |
| `Sources/App` | Companion app that contains the extension |
| `Sources/CLI` | Command-line test tool |
| `Installer` | Installer scripts and resources |
| `Tests` | Sample project with synthetic Russian speech and an end-to-end test script |

## Uninstall

```bash
Installer/uninstall.sh
```

## License

[MIT](LICENSE) © 2026 Roman Kolychev
