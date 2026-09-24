# AuthReach

Native macOS (13+) menu-bar app that polls Gmail and IMAP inboxes for one-time passcodes. SwiftPM only — no Xcode project, no dependencies beyond the forked `KeyboardShortcuts`.

## Commands

- `swift build` / `swift test` (`make build` / `make test`). CI runs these on macOS 15 on both Apple silicon and Intel, then assembles a universal app on the Apple silicon runner; keep them green.
- `swift test --filter ImapProviderTests` to run one suite.
- `make app` assembles `build/AuthReach.app` via `scripts/make-app.sh` (release build, signed, host architecture only). `AUTHREACH_ARCHS="arm64 x86_64"` builds each architecture separately and merges them with `lipo`; CI and releases set it. `make run` quits any running AuthReach, waits for it to exit, then opens the fresh build.
- Local signing: `make-app.sh` picks the first "Developer ID Application" identity from the keychain, else ad-hoc. Ad-hoc builds are a new code identity every time, so each Keychain read prompts. CI sets `SIGN_IDENTITY` explicitly.

## Layout

- `Sources/AuthReachCore` — UI-free, fully unit-tested. Everything testable goes here.
  - `OtpCenter` (actor) is the poll loop: per-account watermark + processed ids, in memory only. The first poll of an account only sets a baseline; backlog mail is never processed.
  - `InboxProvider` is the provider surface: `initialWatermark`, `messages(after:skipping:)`, `watermark(for:)`. Watermarks are opaque doubles (epoch seconds for Gmail, UID for IMAP). Calls must be self-contained — no state carried between calls for the poll loop to depend on.
  - `GmailClient` (REST) and `Imap/` (`ImapProvider` → `ImapConnection` → `ImapTransport`, plus `MimeParser`) are the providers.
  - `OtpDetector` holds the heuristics (English + Swedish). Callers NFC-normalise text before detection.
- `Sources/AuthReach` — the AppKit/SwiftUI app. `AppModel` is the composition root (`@MainActor`); `AppDelegate` owns the tray, HUD panel and settings window.
- `Tests/AuthReachCoreTests` — XCTest. `ScriptedTransport` in `ImapProviderTests` is an in-memory IMAP server (supports chunked reads and client literals); `StubInbox` in `OtpCenterTests` is the fake provider.

## Invariants

- **Read-only mail access.** Gmail uses `gmail.readonly`; IMAP opens INBOX with `EXAMINE` and fetches with `BODY.PEEK`. Never add anything that sets flags or moves mail.
- **Secrets only in the Keychain** (`KeychainStore`, service `com.elva-labs.authreach`): Google client credentials under `google-credentials`, IMAP credentials under `imap-account:<accountId>`. `SettingsStore` JSON holds non-secret settings only. Codes live in memory only; nothing about mail is written to disk.
- **Never log or echo credentials.** IMAP errors name the command (`label:`), never its arguments.
- **No Keychain reads on the main thread at launch.** They can block on a user prompt before the tray icon exists.
- The local API is loopback-only, bearer-token-checked in constant time, and rejects any request with an `Origin` header. Keep all three properties.
- The app is `.accessory` (no Dock icon) except while the settings window is open, when it switches to `.regular` so menu-bar managers (Thaw/Ice) can't bury the window.

## IMAP specifics

- Implicit TLS on 993 only; no STARTTLS, no OAuth (so no Outlook/M365), INBOX only.
- `ImapProvider` keeps one signed-in session per account between polls. A session is checked out while a call uses it, replaced after `sessionIdleLimit` of idleness (e.g. across sleep), and retried once on a fresh connection after a transport error. `verify` always uses a throwaway connection.
- `UIDVALIDITY` changes throw `InboxProviderError.baselineReset`; `OtpCenter` treats that as "re-baseline next tick", not as an error.
- LOGIN arguments are quoted strings when plain ASCII, synchronizing literals otherwise (`ImapConnection.Part.literal`).
- `MimeParser` works on a Latin-1 view of the raw bytes; header values are re-read as UTF-8 when valid (RFC 6532) before RFC 2047 decoding.

## Conventions

- Swift 5.10 tools, Swift 5 language mode. Use actors for shared mutable state; `@unchecked Sendable` only with a lock or a serial queue behind it.
- Precompile regexes and `DateFormatter`s as `static let`s; don't build them per call.
- Doc comments explain *why* (protocol quirks, RFC section numbers, platform behaviour). Skip comments that restate the code.
- Parsing and protocol behaviour get unit tests in `AuthReachCoreTests`, including the edge case that motivated the change.
