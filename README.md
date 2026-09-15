<p align="center">
  <img src="Resources/Assets.xcassets/AppLogo.imageset/applogo.png" alt="Textora app icon" width="180">
</p>

<h1 align="center">Textora</h1>

<p align="center">
  A private, open-source writing assistant for macOS that rewrites, translates, and dictates text directly in the apps you already use.
</p>

[Support the project](https://paypal.me/RShytskou)

All AI requests are sent directly from your Mac using your own API key (BYO key).  
This repository does not include a Textora backend proxy.

## Features

### Rewrite and translate anywhere

- Select text in native macOS apps, browsers, Electron apps, mail clients, chats, and editors.
- Choose `Fix`, `Shorten`, `Formal`, or `Humanize`, or let SmartAI recommend the best rewrite mode.
- Translate selected text into your configured target language.
- Apply the result in place or copy it when direct replacement is unavailable.
- Preserve surrounding rich-text formatting where the target app supports it.

### Three ways to work

- **Toolbox** appears automatically near the active text field.
- **Floating icon** keeps Textora close without opening the full toolbox.
- **Hotkeys** trigger rewrite, translation, or dictation without an on-screen helper.
- Textora lives in the menu bar and can optionally launch automatically when you log in.

### Private offline dictation

- Hold a configurable shortcut to dictate into the active text field.
- Speech recognition runs entirely on your Mac with the Parakeet V3 model.
- Supports 25 languages, automatic keyboard-layout language selection, a fallback language, and microphone selection.
- Audio is never uploaded or saved.

### Bring your own AI provider

- Supports OpenAI, Gemini, Claude, and OpenAI-compatible endpoints.
- Loads available models from supported providers while still allowing an automatic recommended model.
- API keys stay in the macOS Data Protection Keychain and requests go directly from your Mac to the selected provider.

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
4. Choose Toolbox, Floating icon, or Hotkeys.
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

## Support

If Textora helps you, you can support development here: [paypal.me/RShytskou](https://paypal.me/RShytskou).

## License

MIT
