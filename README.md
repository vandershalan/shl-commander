# shl-commander

A Total Commander–style dual-pane file manager for macOS. Native Swift, keyboard first.

![shl-commander](docs/screenshot.png)

Finder has no dual pane, no F-key command set, no bookmark hotkeys, no directory-size column,
and no keyboard-first selection model. This brings that working style to macOS: two panes, a
cursor that never wanders, marks kept separate from the cursor, and a command for everything.

## Features

- **Dual panes** with per-pane tabs, a draggable divider, and independent sort per tab.
- **Keyboard first.** Every command has a Total Commander binding and a ⌘ equivalent, all
  remappable. Typing any character starts a quick filter.
- **Marks separate from the cursor**, the way Total Commander does it: `Space` and `Insert`
  mark rows while the arrows move the cursor independently. Mark by shell glob with `Num +`.
- **Fast copies.** On one APFS volume, `clonefile(2)` copies a file or a whole tree instantly
  by sharing blocks; `rename(2)` moves one instantly. Only cross-volume work reads and writes
  bytes, and only then does progress mean anything.
- **Directory sizes on demand** (`⌃L`), cached against the folder's timestamp.
- **Favourite folders** on `⌘1`–`⌘9`, with a drag-to-reorder bar.
- **Live panes.** Each watches its own directory through FSEvents and reloads on change,
  keeping the cursor and the marks.
- **Session restore**: tabs, paths, sort, and focus come back on relaunch.
- **Zoom** on the standard Mac keys (`⌘+`, `⌘-`, `⌘0`). Rows, fonts, icons and columns scale
  together, and the setting survives a relaunch.
- **Cloud folders and network shares.** OneDrive, iCloud Drive, Google Drive and anything else
  with a File Provider are listed beside the volumes; `⌘K` mounts SMB (and AFP, NFS, FTP,
  WebDAV) shares and remembers them.
- **Drag and drop**, in and out: between the panes, onto a folder row, to and from the Finder
  and any app that takes files. Same volume moves, across volumes copies, `⌥` forces a copy and
  `⌘` a move.
- Quick Look (`F3`), an internal text/hex viewer, Open in Terminal, Reveal in Finder.
- **A searchable shortcut list** (`F1` or `⌘/`), built from the live keymap, so it cannot fall
  out of step with what the keys actually do.
- **Browse inside archives.** `Return` on a `.zip`, `.tar.gz`, `.7z` and friends opens it like a
  folder: navigate down, filter, mark, preview with Quick Look, and copy files out. Folders
  inside an archive show their real recursive size straight away, since the archive already
  lists it.

## Requirements

macOS 26+, Xcode 26+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). `ShlCommander.xcodeproj` is generated from `project.yml`, not
committed.

## Build

```bash
git clone https://github.com/vandershalan/shl-commander.git
cd shl-commander
make release   # builds, signs, installs to /Applications
```

Other targets:

```bash
make gen     # regenerate ShlCommander.xcodeproj from project.yml
make build   # xcodebuild, Debug
make test    # unit tests
make run     # build then launch the app
make icon    # redraw Resources/AppIcon.icns from Tools/make-icon.swift
```

## One-time macOS setup

### 1. Full Disk Access

The app is deliberately **not sandboxed** — a file manager that asks permission per folder is
unusable. macOS still gates `~/Desktop`, `~/Documents`, `~/Downloads`, `~/Library`, and other
users' home directories behind TCC, so grant access once:

**System Settings → Privacy & Security → Full Disk Access → +** and pick
`shl-commander.app`.

Everything outside those protected paths works without the grant.

Granting Full Disk Access once is what stops the per-folder prompts entirely. Without it macOS
asks the first time the app touches each protected folder.

### Why permissions used to be asked for again and again

macOS keys a privacy grant to the app's *designated requirement*. Signed ad-hoc (`--sign -`),
that requirement is a `cdhash` — a hash of the binary itself:

```
designated => cdhash H"fa2d2ccd…"
```

Every rebuild produces a different hash, so macOS sees a different app and every permission has
to be granted again. `make release` therefore signs with a real identity when the keychain has
one, which makes the requirement stable:

```
designated => identifier "com.szalankiewicz.shl-commander" and anchor apple generic
              and certificate leaf[subject.CN] = "Apple Development: …"
```

That survives rebuilds, so a grant given once keeps working. `make identity` reports which
identity will be used and what it means; `make release` prints the requirement it ended up with.

Any code-signing certificate works — an Apple Development one if you have it, otherwise a
self-signed one made in **Keychain Access → Certificate Assistant → Create a Certificate**, kind
*Code Signing*. With no certificate at all the build falls back to ad-hoc and says so.

> Changing the signing identity changes the app's identity once, so macOS asks once more after
> the switch. That answer then sticks. The Debug build from `make run` is still ad-hoc and still
> prompts; daily use is meant to be the `/Applications` copy.

### 2. Function keys

Total Commander's command set lives on F3–F8. macOS maps those to brightness and media unless
you turn on:

**System Settings → Keyboard → Keyboard Shortcuts → Function Keys →
"Use F1, F2, etc. keys as standard function keys."**

Every command also has a `⌘` equivalent, so the app is fully usable without changing that
setting. Holding `fn` works too.

## Keyboard reference

| Command | Total Commander | macOS |
| --- | --- | --- |
| Keyboard shortcuts | `F1` | `⌘/` |
| Quick Look | `F3` | `⌘Y` |
| View as text / hex | `⌥F3` | `⌘⇧Y` |
| Edit | `F4` | `⌘E` |
| New folder / new file | `F7` / `⇧F4` | `⌘⇧N` / `⌘⇧F` |
| Copy / move to other pane | `F5` / `F6` | `⌘C` / `⌘M` |
| Duplicate | `⇧F5` | `⌘D` |
| Rename in place | `⇧F6` | `⌘Return` |
| Move to Trash | `F8` | `⌘⌫` |
| Delete permanently | `⇧F8` | `⌘⇧⌫` |
| Measure selected / all folders | `⌃L` / `⌥⇧Return` | `⌘L` / `⌘⇧L` |
| New tab / close tab | `⌃T` / `⌃W` | `⌘T` / `⌘W` |
| Next / previous tab | `⌃Tab` / `⌃⇧Tab` | `⌘⇧]` / `⌘⇧[` |
| Open folder in other pane | `⌃↑` | |
| Favourites list | `⌃D` | `⌘B` |
| Add to favourites | | `⌘⇧D` |
| Jump to favourite 1–9 | | `⌘1`–`⌘9` |
| Switch pane | `Tab` | |
| Open | `Return`, keypad `Enter` | |
| Enclosing folder | `Backspace`, `⌃PageUp` | `⌘↑` |
| Volume root | `⌃\` | |
| Back / Forward | `⌥←` / `⌥→` | `⌘[` / `⌘]` |
| Refresh | `F2`, `⌃R` | `⌘R` |
| Connect to Server | | `⌘K` |
| Sort by name / ext / date / size | `⌃F3` / `⌃F4` / `⌃F5` / `⌃F6` | `⌘⌥1`–`⌘⌥4` |
| Show hidden files | `⌃H` | `⌘⇧.` |
| Zoom in / out | | `⌘+` / `⌘-` |
| Actual size | | `⌘0` |
| Mark | `Space` | |
| Mark and advance | `Insert` | `⇧Space` |
| Mark / unmark by pattern | keypad `+` / keypad `-` | |
| Invert marks | keypad `*` | |
| Mark all / none | `⌃A` / `⌃⇧A` | `⌘A` / `⌘⇧A` |
| Send / take path across panes | `⌃⇧→` / `⌃⇧←` | |
| Swap panes | `⌃U` | |
| Open in Terminal | | `⌘⇧T` |
| Reveal in Finder | | `⌘⇧R` |
| Copy path | `⌃⇧Return` | `⌘⌥C` |
| Clear filter | `Esc` | |

The bar along the top of the window carries the favourites, a button that shows or hides
hidden files, and a button that opens the shortcut list. Sorting is also available by clicking
a column header.

Typing any printable character starts a quick filter, shown in a bar at the foot of the pane
with a live match count. The cursor follows the filter onto the first match as you type, so
narrowing to a single row leaves `Return` one keystroke from opening it. `Backspace` edits that
filter for as long as the bar is showing —
including once the text is empty — so clearing a filter never walks you out of the directory.
`Esc` closes the bar, and only then does `Backspace` mean "enclosing folder" again.

The cursor holds its place across every operation. When the row it sits on disappears, it
takes the nearest surviving row *above* where it was, walking past a whole deleted block if
need be.

### Operation windows

Copying, moving, extracting, duplicating and deleting all run through one panel attached to the
window and centred on it. It confirms first — listing full paths, and for a delete the counts and
total size — then *stays up* and turns into the progress view for the same operation, so there is
no moment where something is happening with nothing to look at.

**Continue in Background** hides the panel and leaves the work running. The bar along the bottom
of the window then carries the progress, marked with a clock and a **Show** button that brings the
panel back. If a name collision comes up after backgrounding, the panel returns on its own —
otherwise the operation would be waiting for an answer with nothing on screen to answer.

Deleting always asks first. Permanently deleting a folder, or more than ten items, additionally
requires typing the word `delete`.

`Return` on a file opens it in whichever app the system would use; `F4` opens it in your
editor, chosen in Settings.

### Archives

`Return` on an archive enters it, and from there everything works as it does in a folder:
arrows and `Return` navigate down, `Backspace` climbs back out — leaving the archive puts the
cursor back on the archive file — and filtering, marking, sorting, Quick Look and the internal
viewer all behave normally. Nested archives open in turn.

`F5` copies the selection out. It asks for a destination, extracts through a staging directory
inside it, and resolves name clashes with the same dialog a normal copy uses. Previewing or
opening a member extracts a scratch copy under the system temporary directory, which is removed
on quit.

**Archives are read-only.** Creating, renaming, moving and deleting inside one are refused with
a message rather than half-done, and edits to an opened member are not written back. Copy the
files out, change them, and repack.

Recognised: `zip` (including `jar`, `war`, `ipa`, `cbz`), `tar`, `tar.gz`/`tgz`,
`tar.bz2`/`tbz`, `tar.xz`/`txz`, `tar.zst`, `7z`, `rar`/`cbr`, `cpio`, `iso`, and the single
compressed streams `gz`, `bz2`, `xz`, `zst`, `Z`. A stream holds exactly one payload, so it opens
as a one-row listing you can preview and copy out decompressed.

The format is decided by the file's **content**, not its name, so an archive whose extension is
wrong still opens — a gzipped CSV handed out as `.zip` is a real and common case. When the two
disagree the archive marker in the path bar says so. The name is still what decides whether a row
offers `Return`, because sniffing every row of a large directory would mean opening every file
in it.

Reading is done by `/usr/bin/tar`, which on macOS is bsdtar over libarchive, and by `gzip` and
`bzip2` for streams — no third-party archive library is vendored. `xz` and `zstd` streams need
those tools installed (Homebrew); the app says which one is missing rather than failing
obscurely.

### Drag and drop

Dragging a marked row takes every marked row with it; dragging an unmarked one takes only that
row, so a drag never picks up marks left somewhere off screen. Files can go to the other pane,
to the Finder, or to any app that accepts file URLs — and can come back the same way.

A drop over a folder row lands in that folder, a drop anywhere else lands in the pane's own
folder, and a drop on `..` moves a level up. What happens follows the Finder: within one volume
a drag **moves**, across volumes it **copies**, `⌥` forces a copy and `⌘` forces a move. The
drop is then confirmed through the same dialog `F5` and `F6` use, with the destination prefilled
and editable — a drop that landed on the wrong folder is corrected there rather than undone.

Impossible drops are refused before they start: a folder into itself or into its own subfolder,
files into the folder they are already in, and anything at all into an archive, which is
read-only. Archive members cannot be dragged out either — they have no path on disk until they
are extracted, so `F5` is what copies them out.

### Cloud folders and network shares

The volume button at the top of each pane lists more than disks. Under the volumes come the
cloud folders macOS keeps under `~/Library/CloudStorage` — OneDrive, Google Drive, Dropbox, Box,
and anything else that ships a File Provider — plus iCloud Drive. A provider with several roots
(a personal OneDrive and its shared libraries, say) gets a submenu. Nothing here talks to a
cloud API: these are ordinary folders that the provider's own daemon keeps in sync, so copying
into one is a copy, and the sync happens afterwards. Accounts added or removed while the app is
running appear and disappear on their own.

`⌘K` opens **Connect to Server**, which mounts through NetFS — the same machinery behind the
Finder's dialog, so the same addresses work:

```
smb://nas.local/media          a share on a NAS or a Windows box
//192.168.0.5/Backup           the Windows spelling; SMB is assumed
nas.local/media                so is a bare host
afp://mac.local/Files          AFP, NFS, FTP and WebDAV (dav://) all mount too
```

The share is required — `smb://host` on its own has nothing to mount. Leave the name and
password empty for a guest share. On success the active pane opens the mount point, and the
address is saved; tick *Remember the password in the Keychain* and the next connection needs
one keystroke. Passwords are internet-password entries in the login Keychain, visible and
revocable in Keychain Access — the saved-server file itself holds only the address and the
name. Reconnecting to a share that is still mounted takes you to it rather than mounting it a
second time, and mounted shares eject from the same menu as any other volume.

### Rebinding

**Settings → Keyboard** (`⌘,`) lists every command with its keys. Select one, press *Record
Shortcut*, and press the chord. A key already used elsewhere is taken from the other command,
since two commands on one key would make the winner arbitrary. Changes apply immediately and
are written to `keymap.json`; the menu-bar shortcuts catch up on the next launch, because
SwiftUI installs those once at startup.

To edit the file directly instead, create
`~/Library/Application Support/shl-commander/keymap.json` with only the differences — anything
you leave out keeps its default:

```json
{
  "_comment": "keys starting with _ are ignored",
  "swapPanes": ["cmd+shift+s"],
  "revealInFinder": []
}
```

An empty array unbinds a command. Command names are the `Command` cases in
`Sources/Keys/Command.swift`. Chords are `modifier+…+key`, where modifiers are `cmd`, `ctrl`,
`opt` (or `alt`), and `shift`, and keys are letters, digits, `f1`–`f12`, `space`, `return`,
`tab`, `backspace`, `escape`, `insert`, `home`, `end`, `pageup`, `pagedown`,
`up`/`down`/`left`/`right`, punctuation names such as `period` / `comma` / `backslash` /
`leftbracket`, and `keypadplus` / `keypadminus` / `keypadmultiply` / `keypadenter`. The keypad
keys are spelled out so that `+` is never both a separator and a key name.

A malformed entry is skipped rather than guessed at.

## Settings

`⌘,` opens Settings.

- **General** — restore the last session or always open at chosen folders, show hidden files
  by default, and pick the editor `F4` uses.
- **Keyboard** — the shortcut table described above.

## Where things are kept

`~/Library/Application Support/shl-commander/` holds `favorites.json`, `keymap.json`,
`servers.json`, and `session.json`. Delete any of them to go back to defaults; the app writes
the session on quit and rereads it at launch. Server passwords are not in that folder — they
are internet-password entries in the login Keychain, removed with the server that owns them.

## Layout

```
Sources/
  App/        SwiftUI app, window, menu bar, preferences, session
  Archive/    format detection, listing via bsdtar, index, extraction cache
  Core/       listing, sorting, icons, FSEvents, volumes, directory sizes
  Keys/       KeyChord, Keymap, KeyRouter, CommandDispatcher
  Ops/        copy/move engine, operation queue, conflict resolution, prompts
  Panel/      one pane: view model, NSTableView bridge, tabs, filter bar
  Favorites/  bookmark store and bar
  Preview/    Quick Look and the internal text/hex viewer
Tests/CoreTests/
Tools/make-icon.swift
```

The panels are `NSTableView` behind `NSViewRepresentable`, not SwiftUI `Table`: they have to
stay smooth at tens of thousands of rows, need exact arrow/Home/End/PageUp semantics, and need
a selection model independent of the cursor.

`Sources/App/RenderProbe.swift` is a development aid, compiled out of Release and inert unless
`SHL_PROBE_PNG` is set. It dumps the window as a PNG plus an indented view tree, which is the
only way to check layout from a terminal-driven build — Screen Recording permission cannot be
granted to one.

## Not implemented

Writing into archives (creating one, or adding to and deleting from an existing one), directory
synchronise, multi-rename tool, compare by content, branch view, and remote (SFTP) panels.

There is no CI workflow: GitHub's macOS runners do not yet ship an Xcode that can build a
macOS 26 target, so one would only ever be red. Run `make test` locally.

## License

MIT — see [LICENSE](LICENSE).
