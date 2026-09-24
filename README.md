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
- Providers with two-factor auth need an **app-specific password**: [Gmail](https://myaccount.google.com/apppasswords) (or use the [Google setup](#google-setup) below), [iCloud](https://appleid.apple.com/account/manage), [Yahoo](https://login.yahoo.com/account/security).
- Outlook.com / Microsoft 365 turned off password sign-in for IMAP; they need OAuth, which is not supported yet.
- Only `INBOX` is watched, and only mail that arrives after the account was added.

### Google setup

AuthReach signs in to Gmail with an OAuth client you create in your own Google Cloud project. One client authorizes all your Gmail accounts.

1. **Create a project and enable the Gmail API.** In the [Google Cloud console](https://console.cloud.google.com), create a project (or pick one), then enable **Gmail API** under **APIs & Services → Library**.
2. **Set up the consent screen** under **Google Auth Platform**:
   - **Branding** — an app name (e.g. "AuthReach") and a support email.
   - **Audience** — **Internal** if every account you'll connect is in one Google Workspace organization. Otherwise **External**, and add each Gmail address under **Test users**.
   - **Data access** — add the scope `https://www.googleapis.com/auth/gmail.readonly`, the only one AuthReach requests.
3. **Create the client.** Under **Clients → Create client**, choose **Desktop app** (other types won't work) and copy the client ID and secret. No redirect URI is needed: AuthReach listens on a random `127.0.0.1` port, which Desktop clients accept.
4. **Connect in AuthReach.** In settings, choose **Set up Google API credentials…**, paste the ID and secret (they're stored in your Keychain), then **Add Google account…** for each account. Google warns that it "hasn't verified this app" — expected for your own client; choose **Advanced → Go to AuthReach**.

**Sign-ins expire after 7 days while an External app is in Testing**, and the account stops polling until you add it again. To avoid that, choose **Publish app** under **Audience**: your own client can stay unverified (up to 100 users) and keeps showing the warning at sign-in. Internal apps don't expire.

**"Error 403: access_denied" / "has not completed the Google verification process"** means the app is in Testing and the Google account you signed in with isn't one of its test users. Add that address under **Audience → Test users** in the project that owns the client ID pasted into AuthReach (or publish the app, as above), then choose **Add Google account…** again.

## License

[MIT](LICENSE) © Elva Group AB
