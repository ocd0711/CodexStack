# ConvStack

ConvStack is a native macOS menu bar app for managing local Codex sessions.

## What It Does

- Groups sessions by project with collapsible hierarchy
- Supports Active/Archived scopes and text search
- Shows session metadata in a dedicated manager pane
- Opens conversation preview in a separate modal
- Supports whole-project removal (move all project sessions to Trash)
- Archives, unarchives, and moves sessions to Trash
- Reconciles `session_index.jsonl` after mutations
- Provides a menu bar Settings window to configure Codex root directory

## Data Sources

- `~/.codex/sessions`
- `~/.codex/archived_sessions`
- `~/.codex/session_index.jsonl`

Default root path is `~/.codex`, configurable in `Settings...` from the menu bar.

## Run Locally

```bash
swift run ConvStackApp
```

## Build

```bash
swift build
```
