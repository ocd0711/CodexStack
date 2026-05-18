# codexStack

![codexStack logo](Sources/codexStack/Resources/Assets/codexStack-logo.png)

codexStack is a native macOS menu bar app for managing local Codex sessions.

## What It Does

- Groups sessions by project with collapsible hierarchy
- Supports Active/Archived scopes and text search
- Shows session metadata in a dedicated manager pane
- Opens conversation preview in a separate modal
- Supports whole-project removal by moving project sessions to Trash
- Archives, unarchives, renames, and moves sessions to Trash
- Reconciles `session_index.jsonl` after mutations
- Reads Codex session titles from `state_5.sqlite`
- Shows session/weekly subscription utilization
- Shows cost estimation for today and last 30 days
- Manage multiple Codex accounts (import, reorder, remove, and export to Codex or cliproxyapi JSON formats)
- Configurable Auto-Switch feature: automatically switches to the account with the lowest usage when the current account hits customizable Session (e.g. 5h) or Weekly usage percentage limits, with optional macOS notifications
- Two-way account sync: manual or automatic syncing to `~/.codex/auth.json` to seamlessly swap active accounts
- Provides a menu bar Settings window for display options and Codex root directory

## Data Sources

- `~/.codex/state_5.sqlite`
- `~/.codex/sessions`
- `~/.codex/archived_sessions`
- `~/.codex/session_index.jsonl`

Default root path is `~/.codex`, configurable in `Settings...` from the menu bar.

## Install

Homebrew Cask installation is supported from this repository tap:

```bash
brew tap ocd0711/codexstack https://github.com/ocd0711/CodexStack
brew install --cask codex-stack
```

The cask removes the downloaded app quarantine attribute after installation:

```bash
xattr -dr com.apple.quarantine /Applications/codexStack.app
```

To upgrade from GitHub Releases:

```bash
brew update
brew upgrade --cask codex-stack
```

## Run Locally

```bash
swift run codexStack
```

## Build

```bash
swift build
```

The repository also includes a standard Xcode macOS app project:

```bash
xcodebuild -project codexStack.xcodeproj -scheme codexStack -configuration Debug build
```

## Unsigned App Builds

Builds made without a Developer ID certificate may be blocked by Gatekeeper after download.
If macOS reports that the app cannot be verified, right-click the app and choose Open, or
remove the quarantine attribute:

```bash
xattr -dr com.apple.quarantine /path/to/codexStack.app
```

## Acknowledgements

- Inspired by and partially informed by implementation patterns from
  [steipete/CodexBar](https://github.com/steipete/CodexBar), especially around
  Codex usage parsing, cost history aggregation, status item icon rendering, and
  hover-detail chart UX.
