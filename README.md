# Claude Profiles

Create launchers for multiple Claude Desktop accounts from one JSON file, on macOS and Windows. Each launcher has a tinted Claude icon, its own name, and a persistent profile, so you can run accounts side by side without signing out.

## Configuration

Everything runs from one menu: double-click **Claude Profiles - macOS.command** on macOS or **Claude Profiles - Windows.cmd** on Windows, then choose an action (**Create launchers**, **Delete a profile**, and on Windows **Sign in a profile**). From a terminal, pass the action directly, e.g. `create` or `delete work --dry-run`; `--help` lists them.

Create `config.json` from `config.example.json` and fill in your configuration. Both platforms use the same file.

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
| `profile` | Unique data folder under `~/.claude-instances/` (Windows: `%USERPROFILE%\.claude-instances\`). Use `default` for your existing Claude session. 1–64 lowercase letters, numbers, or hyphens. |
| `name` | Full launcher name, e.g. `Claude - Work`, without `.app` or `.lnk`. |
| `color` | Hex color in `#RRGGBB` format. |

Add entries for more accounts, order matters. A name change replaces the old installed launcher.

## macOS

### Setup

Requires macOS, Claude Desktop in `/Applications` or `~/Applications`, and Apple's Command Line Tools (`xcode-select --install`).

Choose **Create launchers** to generate one app per config entry and install them automatically in `~/Applications`.

Temporary files in `.build/` are cleaned up automatically, including on failure. Run one build at a time.

### Dock behavior

Colored icons belong to the launchers. Each launcher starts the original Claude app, so running instances appear separately in the Dock with Claude's original icon; they do not attach to the pinned colored launcher. Pinning a launcher does not change this behavior. Use Finder or Raycast to select a profile by its launcher name.

### First login

Quit other Claude instances before signing in to a new profile: `claude://` login links can open the wrong instance. Once signed in, launch accounts side by side. Repeat this precaution when signing in again.

### Remove

Choose **Delete a profile**, pick a profile, and type the requested confirmation. Quit the selected profile first; other Claude profiles can stay open. The script moves the profile's local data and its generated/installed launchers to Trash, then removes its config entry. Selecting `default` removes your regular Claude Desktop session's local data. The original Claude app and online account are kept.

Preview without changes: `"./Claude Profiles - macOS.command" delete work --dry-run`.

To remove only a launcher, delete its config entry and rebuild, then delete the installed shortcut from `~/Applications` yourself.

## Windows

### Setup

Requires Windows 10 or 11 and Claude Desktop from claude.ai/download (Microsoft Store/MSIX or the older installer). Nothing else to install: the scripts use the built-in Windows PowerShell.

Choose **Create launchers** to generate one shortcut per config entry in `apps\` and install them in the Start Menu under **Claude Profiles**. Type a launcher's name in Start to open it, or right-click it to pin it to Start or the taskbar. Tinted icons are stored in `%LOCALAPPDATA%\ClaudeProfiles\icons`.

With the MSIX version of Claude, shortcuts start Claude through its `claude-desktop.exe` app execution alias. If the script says the alias is off, turn it back on in **Settings > Apps > App execution aliases**.

### Taskbar behavior

As on macOS, running instances share Claude's original icon and group under one Claude taskbar button; they do not attach to a pinned colored shortcut. Each profile keeps its own window, sign-in, and settings.

### First login

On Windows, `claude://` sign-in links always open the `default` profile, even when only another profile is running. If a profile's sign-in sends you through the browser:

1. Quit the other Claude profiles: right-click Claude's tray icon and choose **Quit**. Closing the window is not enough.
2. Choose **Sign in a profile** in the menu, then the profile. It starts that profile if needed.
3. Sign in from that profile's window. When the browser asks to open Claude, allow it. The helper stops the `default` instance that Windows starts for the link and passes the link to your profile. If the browser shows the link instead, paste it into the helper window.
4. Press Enter in the helper window when you are signed in.

Sign-in is kept in the profile; afterwards, use the launchers side by side. Repeat these steps when signing in again.

### Remove

Choose **Delete a profile**, pick a profile, and type the requested confirmation. Quit the selected profile first (tray icon > **Quit**); other Claude profiles can stay open. The script moves the profile's local data, its generated/installed shortcuts, and its icon to the Recycle Bin, then removes its config entry. Selecting `default` removes your regular Claude Desktop session's local data. The original Claude app and online account are kept.

Preview without changes, from a terminal: `"Claude Profiles - Windows.cmd" delete work --dry-run`.

To remove only a launcher, delete its config entry and rebuild, then delete the shortcut from the Start Menu's **Claude Profiles** folder yourself.

---

Based on [Philipp Stracker's `--user-data-dir` approach](https://philippstracker.com/multiple-claude-instances/). This is an unofficial launcher; Claude updates may affect profile isolation, MCP, or Cowork behavior.
