<picture>
  <source media="(prefers-color-scheme: dark)" srcset="branding/logo-dark.png">
  <img src="branding/logo-light.png" alt="fileCommander" width="420">
</picture>

# fileCommander for macOS

A native SwiftUI file manager inspired by One Commander (Windows): dual panes of
Miller columns, a Quick Look preview panel, and keyboard-first navigation.

## Build & run

    ./build-app.sh                       # -> dist/fileCommander.app
    open "dist/fileCommander.app"
    open "dist/fileCommander.app" --args ~/Projects ~/Downloads   # start folders for left/right pane

Optional, once: `./setup-signing.sh` creates a self-signed "fileCommander Local Signing"
certificate in your login keychain (asks for your password to trust it for code signing).
`build-app.sh` then signs with it, so macOS keeps folder-access permissions across rebuilds
instead of asking again each time. Undo by deleting that certificate in Keychain Access.

Requires macOS 14+ and Xcode command line tools. The first build downloads SwiftTerm. Drag the .app into /Applications to keep it.

## Keys

| Key | Action |
| --- | --- |
| ⌃` | Terminal panel (a real shell, following the active pane both ways — toggle "Follow pane") |
| ⌘Y | Quick Look window (↑/↓ inside it step through files) |
| ⌘I | Get Info (size, dates, permissions, owner, default app, tags) |
| ⌘K | Connect to Server: SMB / AFP / NFS / WebDAV (mounted by macOS) or SFTP |
| ⌘, | Settings: themes (System, Graphite, Midnight, Nord, Dracula, Solarized Light, Paper), density, text size |
| ⌘3 / ⌘2 | View as Miller columns / as a sortable list (Name, Size, Date Modified, Kind) |
| ⌃⌥⌘1…4 | Sort by name / size / date / kind (again to reverse); folders stay on top |
| ⌘F | Filter the current folder as you type (`report`, or wildcards like `*.pdf`); Esc clears |
| ⇧⌘F | Search in files: by name and/or containing text (shows the matching line), or via Spotlight |
| ⇧⌘P / ⌘P | Command palette / Go to folder (fuzzy over recent + indexed folders, or type a path) |
| ↑ ↓ / PgUp PgDn / Home End | Move cursor (add ⇧ to extend the selection) |
| Click, ⌘-click, ⇧-click | Select, toggle, select range |
| ⌘A, ⇧⌘I, Esc | Select all, invert selection, clear back to cursor |
| + / - / * (or ⌘= / ⌘-) | Select matching / deselect matching (`*.pdf; *.docx`) / invert |
| → / ← | Into folder / back a column (or up a level) |
| Return, ⌘↓ | Open file / enter folder |
| Type letters | Jump to matching name |
| Space | Toggle preview panel |
| Tab | Switch pane |
| ⌘T / ⌘W / ⌃⇥ / ⌃⇧⇥ | New tab / close tab (or window) / next / previous tab |
| F2 | Rename (several selected → batch rename) |
| ⌃⌘M | Batch rename: `[N] [N1-3] [N-4-] [E] [C] [P] [YMD] [hms]`, find/replace (regex), case, counter, live preview |
| ⌃1 … ⌃7 | Toggle Finder tag Red, Orange, Yellow, Green, Blue, Purple, Gray |
| ⌥⌘G | Edit tags (custom tags with colours) |
| ⇧⌘S / ⌥⌘S | Calculate selected folder sizes / always show folder sizes + size bars |
| ⇧⌘C | Compare & sync the folders in the two panes |
| F5 / F6 | Copy / move selection to other pane |
| ⌘D | Duplicate |
| ⌘⌫ | Move to Trash |
| ⌘Z / ⇧⌘Z | Undo / redo file operations (move, copy, rename, trash, new folder) |
| ⇧⌘N | New folder |
| ⌘C / ⌘V | Copy / paste files (works with Finder too) |
| ⌘[ / ⌘] / ⌘↑ | Back / forward / enclosing folder |
| ⇧⌘H, ⇧⌘D, ⇧⌘O, ⌥⌘L, ⇧⌘A | Home, Desktop, Documents, Downloads, Applications |
| ⇧⌘. | Show hidden files |
| ⌥⌘D / ⌥⌘P / ⌥⌘U | Dual pane / preview / swap panes |
| ⌥⌘T | Open Terminal here |
| ⌥⌘C | Copy path(s) |
| ⌘R | Refresh |

Dragging a selected file drags the whole selection (macOS 26+; one item on older systems).
iCloud / cloud-provider files show whether they're downloaded; right-click → Download Now or
Remove Download.

Right-click → Open With (all capable apps, default first) and Share. SFTP folders browse like
local ones: preview, download (F5 to a local pane), upload (F5 or drop into the server column),
rename, new folder and delete (permanent, after confirmation; folders must be empty). SFTP signs
in with SSH keys only (ssh-agent, ~/.ssh/config or a chosen key file); unknown host keys are refused
rather than trusted — connect once with `ssh` to verify them. Network shares are mounted by macOS,
which asks for credentials itself. Removable and network volumes get an eject button.

Archives open like folders (read-only): zip natively; tar, tar.gz/tgz, tar.bz2, tar.xz, 7z,
rar and iso through macOS's built-in `tar`: browse, preview, and copy out with F5 or drag-free
"Extract" menu items; File → Compress / Extract Here make and unpack zips (undoable).
Inside a Git repository, rows show status badges (M modified, A added, ? untracked, R renamed,
U conflict; a dot on folders containing changes) and the status bar shows the branch, ahead/behind
and the number of changes.

Tags are Finder's own (same extended attribute), so they show up in Finder and Spotlight; the
sidebar's Tags section finds tagged files via Spotlight. Compare & Sync marks each difference
(left/right only, newer, different; optionally byte-compared) with a default action you can
change per row; overwritten files go to the Trash and the whole sync can be undone.

Copies and moves run in the background (toolbar ring → Transfers: progress, speed, pause,
cancel). Name clashes ask Skip / Replace / Keep Both, optionally for all; Replace sends the old
item to the Trash so it can be undone. Tabs and folders are restored on launch; Tabs → Save
Workspace… keeps named sets of tabs.

Double-click the path bar (or click ✎) to type a path. Drag files between columns, panes,
onto folders or path segments, or to/from Finder; drag folders to the sidebar to add favorites.

## Layout

- `FileSystem.swift` — listing, thumbnails, directory watcher, glob + fuzzy matching
- `Models.swift` — `Column` (async listing, selection), `Pane` (Miller columns, history), `PaneSide` (tabs)
- `AppModel.swift` — file operations, undo/redo (`FileAction`), workspaces, recent folders
- `Jobs.swift` — background copy/move engine (`copyfile`, APFS clones, progress, pause/cancel, conflicts)
- `Rename.swift` — batch rename engine (`RenamePlan`) and sheet
- `Tags.swift` — Finder tag read/write, tag editor, Spotlight tag search
- `FolderSizes.swift` — background, cached folder size calculation
- `Compare.swift` — folder compare engine, sync plan, compare sheet
- `Archive.swift` — zip central-directory reader + tar/7z/rar via `tar`; extract/compress
- `QuickLookPanel.swift` — the ⌘Y Quick Look window
- `Git.swift` — `git status` parsing and a throttled background status service
- `Search.swift` — content/name search engine, Spotlight mode, results sheet
- `TerminalPanel.swift` — terminal panel on [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (pinned 1.19.0)
- `SFTP.swift`, `Servers.swift` — SFTP via the system `sftp` (shared SSH connection), NetFS mounting, Connect sheet
- `Info.swift` — Get Info and the Open With menu
- `Theme.swift` — themes, density and the Settings window
- `branding/` — logo, app icon, favicons and brand guide (`branding/make-assets.sh` regenerates them)
- `Commands.swift` — one command registry feeding both the menu bar and the palette
- `Palette.swift` — command palette and Go to Folder, background folder index
- `PaneView.swift`, `JobsView.swift`, `SidebarAndPreview.swift`, `App.swift` — UI

## Tests

    swift test

Covers the copy engine (nested trees, xattrs, conflicts, pause/cancel, per-item destinations),
undo/redo, selection, tabs, workspaces, matching, batch rename (placeholders, regex, clashes,
name swaps), tags (incl. the system's own tag API seeing them), folder sizes, compare/sync,
sorting/filtering, zip parsing/browsing/extraction, git status (incl. a real repo), search,
SFTP (against a private throwaway `sshd` on 127.0.0.1), the terminal's folder sync, Open With and themes,
using throwaway temp folders.

## Note on permissions

Without `setup-signing.sh`, `build-app.sh` signs ad hoc, so macOS treats every rebuild as a new
app and asks again for Desktop/Documents/Downloads access.
