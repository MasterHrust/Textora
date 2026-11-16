# Textora 1.4.2

Inspect AI requests, send feature ideas directly to the developer, and enjoy more reliable settings and local history.

## Advanced Debug
- Open Settings > Advanced Debug and enable LLM request logging to investigate slow requests or errors with any AI provider, including Local and Other.
- Inspect the provider, model, endpoint, HTTP status, request and response bodies, and the time needed to receive the complete response. Rewrite, Translate, Summary and model refresh requests share the same journal.
- API keys and credentials are masked before logs are displayed or copied. Logging starts disabled and keeps the latest 50 requests in memory for the current session. Clear the journal or turn logging off to remove its entries.

## Improvements
- Feature Request replaces Support Project in the menu bar and Settings > About & Updates. It opens an email to indepcode@proton.me with the subject Textora Feature Request.
- Added the developer credit: Developed by Roman Shytskou.
- Automatic update checks now run every 5 hours while Textora is running, when automatic checking is enabled.

## Fixed
- Reduced repeated Keychain permission prompts when saving Rewrite, Translate, Summary and copied results to local history. A successfully loaded encryption key is reused for the current app session.
- Edited API tokens are saved even when you switch AI providers before automatic saving finishes. Failed saves can be retried without losing tokens already saved successfully.
