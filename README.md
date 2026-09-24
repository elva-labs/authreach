# AuthReach

Native macOS menu-bar app that watches your Gmail and IMAP inboxes and surfaces incoming one-time passcodes the moment they land — auto-copied to your clipboard, shown as a notification, listed in the tray, and one global shortcut (⌘⇧O) away in a floating HUD.

## Features

- **Connect any number of Gmail accounts** with your own Google OAuth client (Desktop type, `gmail.readonly` scope). Tokens live in your Keychain; mail is read-only and codes are kept in memory only — nothing is ever written to disk.
- **Connect any IMAP inbox** (iCloud, Fastmail, Yahoo, GMX, self-hosted…) over TLS. Credentials live in your Keychain; the mailbox is opened read-only (`EXAMINE` + `BODY.PEEK`), so nothing is ever marked as read.
- **Heuristic OTP detection** — cue-worded codes ("code is 123456"), Google-style `G-` codes, split digits, with a keyword gate so ordinary mail with stray numbers is ignored.
- **Live expiry countdowns** when the email states one ("expires in 10 minutes") — in the tray, the HUD, and the API.
- **Auto-copy + notification** on arrival; configurable poll interval.
- **Local API** for scripts and tools: loopback-only, bearer-token-authenticated —
  `GET http://localhost:8877/v1/otps/latest[/code]`, filterable by `service`, `sender`, `accountEmail`, `maxAgeSeconds`. Constant-time token checks; browser requests (anything with an Origin header) are rejected.

## Install

Runs on Apple silicon and Intel Macs with macOS 13 or later; releases are universal binaries.

Build from source (macOS 13+, Xcode 15+):

```sh
git clone https://github.com/elva-labs/authreach.git
cd authreach
make app && make run
```

`make app` builds for your own Mac's architecture. For a universal binary, run `make app AUTHREACH_ARCHS="arm64 x86_64"`.

A notarized release and Homebrew cask (`elva-labs/elva`) are on the way.

### IMAP setup

Choose **Add IMAP account…**, enter the address, server and password, and AuthReach verifies the sign-in before saving anything. Notes:

- Implicit TLS only (port 993). STARTTLS on 143 and plaintext are not supported.
- Proton Mail Bridge is not supported: it serves IMAP over STARTTLS with a self-signed certificate.
- Providers with two-factor auth need an **app-specific password**: [Gmail](https://myaccount.google.com/apppasswords) (or use the Google connector above), [iCloud](https://appleid.apple.com/account/manage), [Yahoo](https://login.yahoo.com/account/security).
- Outlook.com / Microsoft 365 turned off password sign-in for IMAP; they need OAuth, which is not supported yet.
- Only `INBOX` is watched, and only mail that arrives after the account was added.

### Google setup

Create an OAuth client in the [Google Cloud console](https://console.cloud.google.com/apis/credentials) — type **Desktop app**, with the Gmail API enabled — and paste its ID and secret into AuthReach's settings. One client authorizes all your accounts.

## License

[MIT](LICENSE) © Elva Group AB
