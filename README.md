# Quodex

Quodex is a lightweight, standalone macOS menu-bar app that lets you see usage limits and banked resets across multiple ChatGPT accounts in one place.

Quodex is an independent project and is not affiliated with or endorsed by OpenAI.

## Features

- Add, reauthenticate, and remove accounts with OpenAI's device-code login.
- Keep each account's email and subscription plan visible.
- Show every usage lane reported by the service, including 5 hour, weekly, and gpt-reserve lanes when present.
- Show remaining percentages, countdowns, and reset times.
- Show banked resets and their earliest expiry when available.
- Show pooled capacity across accounts.
- Refresh all accounts manually, refresh one account independently, and check every account every 30 minutes while Quodex is running.
- Detect early quota resets and newly detected banked resets.
- Optional local notifications for usage resets; automatic banked resets notifications do not require enabling an account bell.
- Drag accounts into a custom order, with new free subscription accounts automatically placed at the bottom after paid accounts.
- Refresh and sort accounts once by their soonest reported reset, then keep the resulting manual order stable.
- Open automatically at login so background checks continue without opening the popover.
- Support up to 100 accounts with smooth scrolling and bounded refresh concurrency.

## How it works

Quodex stores one record per stable ChatGPT account ID. Each successful refresh replaces that account's cached usage snapshot. The interface labels data as live only for a short freshness window; older data is shown with its exact age rather than being presented as current.

Unrecognized or incomplete server responses are shown as unavailable.

## Requirements

- Apple silicon or 64-bit Intel Mac.
- macOS 14 or later.
- A ChatGPT account.

Quodex has no third-party Swift package dependencies, helper process, local server, browser extension, or Electron runtime.

## Install

### Homebrew

```bash
brew install --cask hxbib/tap/quodex
```

Upgrade or remove Quodex with:

```bash
brew upgrade --cask quodex
brew uninstall --cask quodex
```

### DMG or app ZIP

Download the Apple Silicon (`arm64`) or Intel (`x86_64`) DMG from [GitHub Releases](https://github.com/hxbib/Quodex/releases), open it, and drag Quodex into Applications. Matching app ZIPs are available as alternatives.

This release is ad-hoc signed and is not notarized by Apple. If macOS blocks the first launch, try opening Quodex, then go to **System Settings → Privacy & Security → Open Anyway** and confirm. On older macOS versions, Control-click → Open may also be available. See [Apple’s guidance](https://support.apple.com/102445). Quodex never removes quarantine or changes Gatekeeper settings automatically.

After copying the app, eject the mounted Quodex image and move the downloaded DMG to Trash if you no longer need it.

## Build from source

Local builds require Swift 6 and the macOS Command Line Tools. A full Xcode installation is not required.

Clone the repository and build:

```bash
git clone https://github.com/hxbib/Quodex.git
cd Quodex
./Scripts/build-app.sh
./Scripts/install-app.sh
```

The build script targets the current Mac by default. Cross-compile a specific architecture with:

```bash
QUODEX_ARCH=arm64 ./Scripts/build-app.sh
QUODEX_ARCH=x86_64 ./Scripts/build-app.sh
```

The installer places Quodex in `/Applications` when the destination is writable. To use a user-owned Applications directory instead:

```bash
QUODEX_INSTALL_DIR="$HOME/Applications" ./Scripts/install-app.sh
```

The local build is ad-hoc signed. Rebuilt versions can prompt again for Quodex’s Keychain entries because their code signature changes; approving an entry does not delete or replace the account.

## Data and privacy

Quodex does not read or modify the official ChatGPT app, Codex app, browser cookies, `~/.codex`, or another app's Keychain items.

Access and ID tokens are stored as per-account generic-password items in the macOS Keychain service `com.quodex.Quodex.oauth-tokens`. Refresh tokens returned during device login are discarded. The local metadata file is:

```text
~/Library/Application Support/Quodex/accounts.json
```

That file contains account labels, stable IDs, plans, and the last successful usage snapshot; it does not contain OAuth token values. The file and its directory are written with owner-only permissions. Notifications are local macOS notifications and do not transmit account data.

Quodex never retries or refreshes an expired or rejected access token. An affected account is marked `Login required`; its account-specific sign-in action copies the email and starts a fresh device-code flow.

Quodex does not route or submit chats, redeem banked resets, read browser cookies, read another app's Keychain items, expose a local server, or send credentials to redirects or unapproved hosts. Tokens, device codes, account IDs, and email addresses are not written to logs or diagnostics.

## Network behavior

Authentication uses OpenAI's device-code sign-in. Usage and reset information is read through OpenAI services. It does not submit chats, redeem reset credits, or route traffic.

## Notifications

The account bell enables scheduled local notifications for future reset timestamps and early reset detection for that account. Quodex also automatically reports a newly observed increase in confirmed banked resets for every account, independently of the bell setting. The global check runs every 30 minutes while Quodex is running; Open at Login is enabled by default and can be changed from the menu-bar icon’s secondary-click menu.

Enable or disable notifications in Quodex, or manage the final macOS permission in System Settings → Notifications → Quodex.

## Verification

For a release build, verify the bundle and its executable:

```bash
codesign --verify --deep --strict build/Quodex.app
codesign -dv --verbose=4 build/Quodex.app 2>&1 | sed -n '1,80p'
```

## Project layout

- `Sources/Quodex/` contains the SwiftUI interface, app lifecycle, account store, Keychain access, OAuth device flow, network client, and notification scheduler.
- `Resources/` contains the bundle metadata and the shared Quodex icon artwork.
- `Scripts/` contains dependency-free build and install scripts.

## License

Quodex is released under the MIT License. See [LICENSE](LICENSE).
