# Claude Profiles

Create macOS launchers for multiple Claude Desktop accounts from one JSON file. Each launcher has a tinted Claude icon, its own name, and a persistent profile.

## Setup

Requires macOS, Claude Desktop in `/Applications` or `~/Applications`, and Apple's Command Line Tools (`xcode-select --install`).

Create `config.json` from `config.example.json` and fill in your configuration. Then run **Create Launchers.command** to generate one app per config entry and install them automatically in `~/Applications`.

Temporary files in `.build/` are cleaned up automatically, including on failure. Run one build at a time.

## Dock behavior

Colored icons belong to the launchers. Each launcher starts the original Claude app, so running instances appear separately in the Dock with Claude's original icon; they do not attach to the pinned colored launcher. Pinning a launcher does not change this behavior. Use Finder or Raycast to select a profile by its launcher name.

## Configuration

```json
{
  "apps": [
    { "profile": "default", "name": "Claude - Personal", "color": "#247DE8" },
    { "profile": "work", "name": "Claude - Work", "color": "#9346CF" }
  ]
}
```

| Field | Meaning |
| --- | --- |
| `profile` | Unique data folder under `~/.claude-instances/`. Use `default` for your existing Claude session. 1–64 lowercase letters, numbers, or hyphens. |
| `name` | Full app name, e.g. `Claude - Work`, without `.app`. |
| `color` | Hex color in `#RRGGBB` format. |

Add entries for more accounts, order matters. A name change replaces the old installed launcher.

## First login

Quit other Claude instances before signing in to a new profile: `claude://` login links can open the wrong instance. Once signed in, launch accounts side by side. Repeat this precaution when signing in again.

## Remove

Double-click **Delete a Profile.command**, choose a profile, and type the requested confirmation. Quit the selected profile first; other Claude profiles can stay open. The script moves the profile's local data and its generated/installed launchers to Trash, then removes its config entry. Selecting `default` removes your regular Claude Desktop session's local data. The original Claude app and online account are kept.

Preview without changes: `"./Delete a Profile.command" work --dry-run`.

To remove only a launcher, delete its config entry and rebuild, then delete the installed shortcut from `~/Applications` yourself.

Based on [Philipp Stracker's `--user-data-dir` approach](https://philippstracker.com/multiple-claude-instances/). This is an unofficial launcher; Claude updates may affect profile isolation, MCP, or Cowork behavior.
