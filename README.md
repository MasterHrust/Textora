<p align="center">
  <img src="Resources/Assets.xcassets/AppLogo.imageset/applogo.png" alt="Textora app icon" width="180">
</p>

<h1 align="center">Textora</h1>

<p align="center">
  A private, open-source writing assistant for macOS that rewrites, translates, and dictates text directly in the apps you already use.
</p>

Developed by **Roman Shytskou**.

All AI requests are sent directly from your Mac using your own API key (BYO key).  
This repository does not include a Textora backend proxy.

## Features

### Rewrite and translate anywhere

- Select text in native macOS apps, browsers, Electron apps, mail clients, chats, and editors.
- Choose `Fix`, `Shorten`, `Formal`, or `Humanize`, or let SmartAI recommend the best rewrite mode.
- Translate selected text into your configured target language.
- Optional Smart translation direction uses one primary and one second language across selected text and speech: primary → second, every other source → primary. Choose Auto in the translation language list to set it up directly in the result panel, or use Settings > Writing > Rewrite & Translate. Existing settings stay active until you opt in.
- Target changes in Smart mode apply only to the current selection or recording. If the source language is ambiguous, choose a target before translation continues; nothing is inserted automatically while the choice is pending. Summary has its own optional Smart direction choice and still defaults to the original language.
- Apply the result in place or copy it when direct replacement is unavailable.
- Preserve surrounding rich-text formatting where the target app supports it.

### Two ways to work

- **Toolbox** appears automatically near the active text field.
- **Hotkeys** trigger rewrite, translation, or dictation without an on-screen helper.
- Textora lives in the menu bar and can optionally launch automatically when you log in.
- Update dialogs display the release’s changes before installation. The release tooling embeds the GitHub Release description in the signed Sparkle feed; see [UPDATES.md](UPDATES.md).

### Private offline dictation

- Press the configurable shortcut to start recording, then press it again or click Stop to finish. Hold-to-record remains available in Settings > Shortcuts.
- Speech recognition runs entirely on your Mac with the Parakeet V3 model.
- Supports 25 languages with automatic recognition independent of keyboard layout, and microphone selection.
- Optional speech translation sends only the recognized text to your selected AI provider; audio stays local. Translation preferences are shared between Toolbox and Hotkeys.
- Audio is never uploaded or saved. If the active field cannot be verified, explicit dictation can still produce a result to copy; no unverified insertion is attempted.

### My Style

- Create editable Everyday, Work, Personal, or custom named profiles.
- Apply one profile to all apps, or assign profiles to specific applications with a default for the rest.
- Configure tone, length, English spelling, preserved literal terms, and short dashes.
- Optionally turn a short description into suggested settings, then apply or discard the suggestion. Raw descriptions and profile names are never generation instructions. The editor has separate Preferences and Preview tabs; creating a profile does not enable it or change app assignments.
- Access My Style in Settings > Writing > My Style, both result panels, and dictation preferences. It starts disabled. Settings uses a sidebar and focused tabs instead of one long page.

### From thoughts to a message

- Choose Text or Message directly on the recording panel, in Toolbox or Hotkeys mode. Expand translation options to choose Auto-detect or a source language and the target before Stop. Preferences are frozen when recording ends.
- With translation off, Message immediately opens the local transcript as an editable draft. Choose Improve with AI explicitly to polish it using your selected writing profile. Translation, when enabled, prepares the translated message in one AI request.
- Always preview before insertion; review the original transcript, clarify ambiguity, regenerate, copy, or insert into the original verified field.
- Text and the initial Message preview stay offline with translation off, even if My Style is enabled. A provider is only needed for translation or explicit AI improvement; audio is never uploaded.

### Recent Results

- Opt in to encrypted local history of original and final text, including dictation. No audio or clipboard monitoring.
- Defaults after opt-in: 7 days and 200 entries. Choose 1/7/30 days and 50/200/1000 entries in Settings.
- Open from the menu bar, result panels, Settings, or the configurable Control-Option-Command-H shortcut, independent of interface mode.
- Search, filter by operation, sort, copy, and delete results. Disabling saving stops new entries; existing entries expire or can be cleared.
- History uses AES-GCM with a separate, non-synchronizing Keychain key. No plaintext fallback is used if secure storage fails.

### Bring your own AI provider

- Supports OpenAI, Gemini, Claude, and OpenAI-compatible endpoints.
- Loads available models from supported providers while still allowing an automatic recommended model.
- API keys stay in the macOS Data Protection Keychain and requests go directly from your Mac to the selected provider.

### Advanced Debug

- Open **Settings > Advanced Debug** and enable LLM request logging before reproducing a slow request or an error.
- Inspect the provider, model, endpoint, HTTP status, full request duration, request body and response body. Rewrite, Translate, Summary and model refresh requests use the same journal.
- API keys and credentials are redacted before display or copying. Request and response text can still contain private content, so review a copied log before sharing it.
- Logging starts disabled and keeps up to 50 requests in memory for the current app session. Clear the journal or turn logging off to remove entries; no debug log is written to disk.

### Safety and app control

- Per-app Allow, Deny, and Ask controls for text access.
- First-run setup guides you through provider configuration, interface mode, shortcuts, and Accessibility permission.
- HTTPS-only AI transport with same-host redirect enforcement.
- Accessibility plus guarded clipboard fallbacks for apps that expose limited text metadata.

## Requirements

- macOS 14+
- Xcode 15+
- Optional: [XcodeGen](https://github.com/yonaskolb/XcodeGen) to regenerate the Xcode project from `project.yml`

## Repository Structure

```text
apps/macos-app/
  Sources/            Swift source code
  Resources/          Assets and plist files
  Textora.xcodeproj/  Xcode project
  project.yml         XcodeGen project definition
```

## Build and Run

### Xcode

1. Open `apps/macos-app/Textora.xcodeproj`.
2. Select scheme `Textora`.
3. Run the app.

### Regenerate Project (optional)

```bash
cd apps/macos-app
xcodegen generate
```

### Command-line Build

```bash
cd apps/macos-app
xcodebuild -project Textora.xcodeproj -scheme Textora -configuration Debug -sdk macosx build
```

### Release Verification (DMG/App)

For in-app updates and the GitHub Release workflow, see [UPDATES.md](UPDATES.md).

After installing `Textora.app`, verify macOS sees the correct app identity:

```bash
plutil -p "/Applications/Textora.app/Contents/Info.plist"
codesign -dv --verbose=4 "/Applications/Textora.app" 2>&1
spctl -a -vv "/Applications/Textora.app"
xattr -l "/Applications/Textora.app"
```

Expected:
- `CFBundleIdentifier` is `com.textora.app`
- `codesign` identifier is `com.textora.app`
- no `com.apple.quarantine` xattr after trusted install path

## First Launch Setup

1. Open quick setup wizard.
2. Add an API key (default provider: OpenAI).
3. Verify connection.
4. Choose Toolbox or Hotkeys.
5. Complete setup and grant Accessibility permission.

Provider key links:

- OpenAI: <https://platform.openai.com/api-keys>
- Gemini: <https://aistudio.google.com/app/apikey>
- Claude: <https://console.anthropic.com/settings/keys>

For `Other AI`, set:

- OpenAI-compatible base URL (e.g. `https://api.example.com/v1`)
- model ID
- API token

## Permissions

Textora requires **Accessibility** permission to:

- read selected/focused text reliably
- replace text directly in input fields

You can grant access in macOS Settings under:
`Privacy & Security` -> `Accessibility`.

macOS keeps Accessibility decisions in its protected privacy database. Removing the app does not automatically remove that system entry; remove Textora manually from the same Accessibility settings page if you want to clear it completely.

## Launch at Login

Enable **Launch Textora at login** under **Settings > System**. macOS may ask you to approve Textora under `General` -> `Login Items` the first time it is enabled.

## Privacy

- API keys are stored locally in the Data Protection Keychain. Textora never falls back to the legacy login keychain.
- Textora does not route your data through an app-owned backend in this repository.
- Offline Dictation processes audio locally and does not save recordings.
- Your provider's data policies and terms apply when using their API.

## Known Limitations

- Some apps expose limited accessibility metadata, so fallback behavior may be used.
- Auto-apply may be restricted in certain secure or custom text controls.
- Provider-side rate limits and model availability affect response quality and speed.

## Contributing

Contributions are welcome:

1. Create a feature branch.
2. Keep changes focused and documented.
3. Ensure the app builds successfully.
4. Open a pull request with a clear summary and test notes.

## Feature Requests

Send feature requests to [indepcode@proton.me](mailto:indepcode@proton.me).

## License

MIT
