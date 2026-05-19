# codexStack

![codexStack logo](Sources/codexStack/Resources/Assets/codexStack-logo.png)

codexStack is a native macOS menu bar app for managing local Codex sessions.

## Features

### Session Management

- Groups sessions by project with collapsible hierarchy
- Supports Active / Archived scopes and full-text search
- Shows session metadata in a dedicated manager pane
- Opens conversation preview in a separate modal sheet
- Archives, unarchives, renames, and moves sessions to Trash
- Supports whole-project removal by moving all project sessions to Trash
- Reconciles `session_index.jsonl` after mutations
- Reads Codex session titles from `state_5.sqlite`

### Usage & Cost Monitoring

- Shows session (5h) and weekly subscription utilization with progress bars
- Cost estimation for today and last 30 days, broken down by model
- Menu bar icon reflects real-time utilization at a glance

### Account Orchestration

- Import and manage multiple Codex accounts (supports both official and cliproxyapi OAuth JSON)
- Reorder, pin, remove, and export accounts
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

- Configurable Codex root directory, display mode, and refresh interval
- Launch at login toggle
- Session and weekly reset celebration animations (confetti 🎉)

## Data Sources

- `~/.codex/state_5.sqlite`
- `~/.codex/sessions`
- `~/.codex/archived_sessions`
- `~/.codex/session_index.jsonl`
- `~/.codex/config.toml`
- `~/.codex/auth.json`

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
