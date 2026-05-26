# codexStack

![codexStack logo](Sources/codexStack/Resources/Assets/codexStack-logo.png)

codexStack is a native macOS menu bar app for managing local Codex sessions,
usage, accounts, and power settings.

## Features

### Session Management

- Groups sessions by project with collapsible hierarchy
- Supports Active / Archived / All scopes and full-text search
- Shows session metadata in a dedicated manager pane
- Opens conversation preview in a separate modal sheet
- Archives, unarchives, renames, moves sessions between projects, and moves sessions to Trash
- Supports whole-project removal by moving all project sessions to Trash
- Shows empty Codex projects that are present in Codex metadata
- Reconciles `session_index.jsonl` after mutations
- Keeps Codex title and project metadata in sync when sessions are renamed or moved

### Usage & Cost Monitoring

- Shows session (5h) and weekly subscription utilization with progress bars
- Supports used or remaining percentage display in the menu bar
- Shows total usage in the menu bar panel with hover details
- Shows cost estimation for today, the last 7 days, and total history, broken down by model
- Can sync model prices from LiteLLM on a configurable interval
- Menu bar icon reflects real-time utilization at a glance
- Refreshes usage and sessions when the menu opens and on a configurable background interval

### Account Orchestration

- Import and manage multiple Codex accounts (supports both official and cliproxyapi OAuth JSON)
- Reorder, pin, remove, and export accounts
- Deduplicates imported accounts by account identity and keeps the newest valid credential
- Two-way account sync: manual or automatic syncing to `~/.codex/auth.json`
- Auto-Switch: automatically migrates to the account with the lowest usage when the current account exceeds configurable Session or Weekly percentage thresholds, with optional macOS notifications
- Expired credential detection: auto-switch skips expired accounts and hides stale usage percentages

### Model Provider Management

- Reads all `[model_providers.*]` sections from `~/.codex/config.toml` automatically
- **Provider Mode** submenu lets you switch between Official Login and any custom provider with one click
- Active provider is shown as a badge in the menu bar panel header
- Auto-Switch is automatically disabled and greyed out when a custom provider is active, with a visible warning banner
- Session metadata is synced after every provider switch to keep history consistent

### Settings

- Native macOS Settings window with sidebar sections
- Configurable Codex root directory, display mode, refresh interval, and menu bar percentage label
- Launch at login toggle
- GitHub Release update check and update archive download
- Power profile controls for keeping Codex available while macOS is locked
- Weekly reset celebration animation (confetti 🎉)

### Power Controls

- Lock macOS from the menu bar while starting a `caffeinate` keep-awake process
- Reads current, AC, battery, or all-power-source settings via `pmset`
- Applies recommended or disabled power settings with administrator authorization
- Controls sleep, display sleep, disk sleep, Wake on Network Access, Power Nap, restart after power failure, and restart after freeze

## Data Sources

- `~/.codex/state_5.sqlite`
- `~/.codex/sessions`
- `~/.codex/archived_sessions`
- `~/.codex/session_index.jsonl`
- `~/.codex/config.toml`
- `~/.codex/auth.json`
- `~/Library/Application Support/codexStack/imported-accounts.json`
- `~/Library/Application Support/codexStack/usage_cache.json`
- `~/Library/Application Support/codexStack/model_prices.json`
- macOS `UserDefaults` for app preferences

Default root path is `~/.codex`, configurable in Settings.

## Install

Homebrew Cask installation via a dedicated tap:

```bash
brew tap ocd0711/tap
brew install --cask ocd0711/tap/codex-stack
```

To upgrade:

```bash
brew update
brew upgrade --cask codex-stack
```

To uninstall (including user data):

```bash
brew uninstall --cask --zap codex-stack
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
xcodebuild -project codexStack.xcodeproj -scheme codexStack -configuration Debug build -derivedDataPath ./build
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
