# Changelog

All notable changes to Textora, from the latest update to the initial release.

Published release dates come from GitHub Releases. Version 1.4.0 is included from the prepared local release package and uses its preparation date. The 1.4.2 entry also includes changes documented in the signed app's bundled release notes.

## [1.4.2](https://github.com/MasterHrust/Textora/releases/tag/v1.4.2) — 2026-11-16

### Advanced Debug

- Added Settings > Advanced Debug to investigate slow AI requests and errors with any provider, including Local and Other.
- Inspect the provider, model, endpoint, HTTP status, request and response bodies, and the time needed to receive the complete response.
- Rewrite, Translate, Summary and model refresh requests share the same journal.
- API keys and credentials are masked before logs are displayed or copied.
- Logging starts disabled and keeps the latest 50 requests in memory for the current session. Clearing the journal or turning logging off removes its entries.

### Improvements

- Feature Request replaces Support Project in the menu bar and Settings > About & Updates. It opens an email to indepcode@proton.me with the subject Textora Feature Request.
- Added the developer credit: Developed by Roman Shytskou.
- Automatic update checks now run every 5 hours while Textora is running, when automatic checking is enabled.

### Fixed

- Reduced repeated Keychain permission prompts when saving Rewrite, Translate, Summary and copied results to local history. A successfully loaded encryption key is reused for the current app session.
- Edited API tokens are saved even when switching AI providers before automatic saving finishes. Failed saves can be retried without losing tokens already saved successfully.

## [1.4.1](https://github.com/MasterHrust/Textora/releases/tag/v1.4.1) — 2026-11-16

### Summary

- Summarize a selected conversation, email, article or other text from the Toolbox or with the configurable Control-Option-Command-S shortcut.
- Get an overview, key points, decisions, tasks and open questions when they are present in the selected text.
- Choose Brief or Detailed output and keep the original language or select an output language. Changing either option generates a new summary.
- Review the captured original text, copy the summary or regenerate it.
- Summaries use the configured AI provider and appear in Recent Results when history saving is enabled.

### Local and Other AI

- Connect OpenAI-compatible model servers on the Mac with Local. Localhost HTTP connections are supported, and a token is optional when the server allows it.
- Connect OpenAI-compatible services over HTTPS with Other. Local and Other keep separate server addresses, model choices and tokens.
- Refresh available models and choose from a dropdown during setup or in Settings > Writing > AI Provider.
- Manual model IDs remain available for servers that do not provide a model list.

### Improvements

- Summary uses the same dark floating-panel design as Rewrite and Translate, with matching typography, cards, language controls and buttons.
- Summary reads the full captured selection, including text beyond the rewrite preview's 6,000-character limit.
- Improved explicit selection capture in Mattermost using the same clipboard-based approach as Slack.
- Changing summary options or closing the panel cancels the pending request. Late responses cannot replace a newer result.

### Fixed

- Fixed a Keychain access issue that prevented enabled local history from saving results.
- Fixed writing actions being blocked when a configured local model server does not require an API key.

## 1.4.0 — 2026-11-12

Recorded from the prepared local release package. A separate GitHub Release for this version was not present in the release list when this changelog was compiled.

### My Style

- Added reusable writing profiles for all apps or selected applications.
- Start with Everyday, Work or Personal in Settings > Writing > My Style, edit the profile and enable My Style when ready.
- Profiles add writing preferences to the selected action: Fix keeps corrections minimal, while Formal maintains a professional tone.
- New features remain disabled until enabled by the user.

### Message

- Added an editable preview of dictated text before insertion.
- Choose Message in Settings > Dictation > Output & Translation or switch between Text and Message while recording.
- With translation off, the local transcript becomes a draft without an AI request. Review it, then choose Insert or Copy.
- Improve with AI explicitly polishes the draft using the selected writing profile. Translation also uses the configured AI provider; audio stays on the Mac.

### Recent Results

- Added optional encrypted local history of original text and finished results.
- Search, copy or delete saved results without repeating an AI request.
- Open history from the Recent Results window, result toolbar or Control-Option-Command-H.
- History starts disabled. After enabling, defaults are 7 days and 200 results, adjustable in Settings. Audio is never saved.

### Interface and Updates

- Redesigned Settings with a sidebar and focused tabs for writing, dictation, shortcuts, permissions and updates.
- Update dialogs show the release's changes before installation.

### Dictation Improvements

- Press the shortcut once to start recording, then click Stop or press it again to finish. Hold-to-record remains available in Shortcuts.
- Choose Text or Message directly on the recording panel and select source and target languages before stopping.
- Recording controls remain stable while the audio meter updates. Using the controls or switching apps does not end recording.
- Improved focus resolution for editors such as Slack. When a target field cannot be verified, the transcript or message draft stays available to copy without attempting an unverified paste.

### Local Draft Privacy and Reliability

- Message no longer sends an automatic AI request when translation is off. Local previews work without an AI provider.
- Local and AI drafts are clearly labelled. Writing profiles apply only when AI processing is requested.
- If explicit AI improvement fails, the local transcript remains available. Late responses cannot replace a newer local draft.

## [1.3.2](https://github.com/MasterHrust/Textora/releases/tag/v1.3.2) — 2026-10-26

### Improvements and Fixes

- Fixed false rewrite failures caused by date and time formatting.
- Fixed translation updates after copying text or changing the target language.
- Added answer progress and navigation to unanswered clarification questions.
- Prevented background selection detection from modifying the clipboard and interfering with normal copy and paste.
- Reduced false insertion failures caused by missing selection ranges and delayed clipboard updates.
- Improved font and formatting preservation when inserting rewritten text.
- Added clearer insertion failure messages, with the result copied to the clipboard for manual pasting.

## [1.3.1](https://github.com/MasterHrust/Textora/releases/tag/v1.3.1) — 2026-10-07

### Improvements and Fixes

- Fixed text shrinking after corrections in Gmail.
- Improved formatting preservation, including font sizes, bold text, underlining and links.
- Removed misleading insertion warnings in Slack and other editors. The window now closes after applying changes.
- Improved insertion checks so they no longer disrupt text selection or typing.
- Corrected text remains available to copy if automatic insertion is unavailable.

## [1.3](https://github.com/MasterHrust/Textora/releases/tag/v1.3) — 2026-09-23

### Improvements and Fixes

- Fixed rewrite panels getting stuck after applying changes.
- Improved number validation to allow formatting changes such as `12000` to `12,000` while protecting values.
- Preserved user settings across updates, including modes, languages, shortcuts and AI models.
- Improved retry controls and added regression tests.

## [1.2](https://github.com/MasterHrust/Textora/releases/tag/v1.2) — 2026-09-18

### Interface Improvements

- Redesigned ToolPanel and HotKeys windows with a compact layout for Fix, Shorten, Formal and Humanize.
- Apply a rewrite by clicking the result area. HotKeys Rewrite also supports Enter.
- Translation starts only when clicking Translate or using its dedicated hotkey.
- Added first-launch guidance and improved dictation settings.

### Smarter Rewriting

- SmartAI recommends a suitable mode and marks results that need no changes.
- Ambiguous text shows Meaning unclear, allowing a choice of interpretation or an explanation in the user's own words.
- Clarifications generate a preview first, without automatic insertion.
- Strengthened meaning-preservation rules and reduced false rejections when durations are written as words.

### Dictation and Speech Translation

- Local speech recognition supports automatic language detection.
- Added optional translation of dictated text. Audio stays on the Mac; only the transcript is sent to the AI provider.
- Added quick language swapping and an expandable control panel beside the microphone.
- Removed the legacy Floating Icon and moved its useful features into ToolPanel and HotKeys.

### Stability and Reliability

- Improved selection handling in browser fields and pop-up windows.
- Added cancellation of outdated requests and protection against repeated application.
- Improved text-insertion verification, including emoji shortcode conversion.
- Reduced redundant context checks and unnecessary AI requests.
- Added in-app update checking and installation.

## [1.1](https://github.com/MasterHrust/Textora/releases/tag/v1.1) — 2026-09-15

### Improvements and Fixes

- Fixed browser text replacement.
- Fixed dictation status in Google Docs.
- Added in-app updates and automatic update checks.
- Users upgrading from earlier versions needed to install this version manually once to enable future in-app updates.

## [Initial Release](https://github.com/MasterHrust/Textora/releases/tag/Textora) — 2026-06-08

- First published release of Textora for macOS, under the tag `Textora`.
