# AuthReach

Native macOS menu-bar app that watches your Gmail inboxes and surfaces incoming one-time passcodes the moment they land — auto-copied to your clipboard, shown as a notification, listed in the tray, and one global shortcut (⌘⇧O) away in a floating HUD.

## Features

- **Connect any number of Gmail accounts** with your own Google OAuth client (Desktop type, `gmail.readonly` scope). Tokens live in your Keychain; mail is read-only and codes are kept in memory only — nothing is ever written to disk.
- **Heuristic OTP detection** — cue-worded codes ("code is 123456"), Google-style `G-` codes, split digits, with a keyword gate so ordinary mail with stray numbers is ignored.
- **Live expiry countdowns** when the email states one ("expires in 10 minutes") — in the tray, the HUD, and the API.
- **Auto-copy + notification** on arrival; configurable poll interval.
- **Local API** for scripts and tools: loopback-only, bearer-token-authenticated —
  `GET http://localhost:8877/v1/otps/latest[/code]`, filterable by `service`, `sender`, `accountEmail`, `maxAgeSeconds`. Constant-time token checks; browser requests (anything with an Origin header) are rejected.

IMAP account support is planned.

## Install

Build from source (macOS 13+, Xcode 15+):

```sh
git clone https://github.com/elva-labs/authreach.git
cd authreach
make app && make run
```

A notarized release and Homebrew cask (`elva-labs/elva`) are on the way.

### Google setup

Create an OAuth client in the [Google Cloud console](https://console.cloud.google.com/apis/credentials) — type **Desktop app**, with the Gmail API enabled — and paste its ID and secret into AuthReach's settings. One client authorizes all your accounts.

## License

[MIT](LICENSE) © Elva Group AB
