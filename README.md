# shl-commander

A Total Commander–style dual-pane file manager for macOS. Native Swift, keyboard first.

Requires macOS 26+, Xcode 26+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). `ShlCommander.xcodeproj` is generated, not committed.

```bash
make gen      # regenerate ShlCommander.xcodeproj from project.yml
make build    # xcodebuild, Debug
make test     # unit tests
make run      # build then launch the app
make release  # Release build, signed, installed to /Applications
```

## One-time macOS setup

### 1. Full Disk Access

The app is deliberately **not sandboxed** — a file manager that asks permission per folder
is unusable. macOS still gates `~/Desktop`, `~/Documents`, `~/Downloads`, `~/Library`, and
other users' home directories behind TCC, so grant access once:

**System Settings → Privacy & Security → Full Disk Access → +** and pick
`shl-commander.app`.

Everything outside those protected paths works without the grant.

> Development caveat: an ad-hoc signature (`--sign -`) changes on every rebuild, and TCC
> keys the grant to the signature. If the app starts failing to read `~/Documents` after a
> rebuild, remove and re-add it in Full Disk Access — or run `make release` once and grant
> access to the stable `/Applications` copy, which is what daily use should point at.

### 2. Function keys

Total Commander's command set lives on F3–F8. macOS maps those to brightness and media
unless you turn on:

**System Settings → Keyboard → Keyboard Shortcuts → Function Keys →
"Use F1, F2, etc. keys as standard function keys."**

Every command also has a `⌘` equivalent, so the app is fully usable without changing that
setting. Holding `fn` works too.

## Keyboard reference

Every command has a Total Commander binding and, where a stock Mac cannot press that key, a
⌘ equivalent. Typing any other printable character starts a quick filter.

| Command | Total Commander | macOS |
| --- | --- | --- |
| Switch pane | `Tab` | |
| Open | `Return`, keypad `Enter` | |
| Enclosing folder | `Backspace`, `⌃PageUp` | `⌘↑` |
| Volume root | `⌃\` | |
| Back / Forward | `⌥←` / `⌥→` | `⌘[` / `⌘]` |
| Refresh | `F2`, `⌃R` | `⌘R` |
| Sort by name / ext / date / size | `⌃F3` / `⌃F4` / `⌃F5` / `⌃F6` | `⌘⌥1`–`⌘⌥4` |
| Show hidden files | `⌃H` | `⌘⇧.` |
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

Sorting is also available by clicking a column header, and `Backspace` edits an active
quick filter before it means "go up".

### Rebinding

Create `~/Library/Application Support/shl-commander/keymap.json` with only the differences —
anything you leave out keeps its default:

```json
{
  "_comment": "keys starting with _ are ignored",
  "swapPanes": ["cmd+shift+s"],
  "revealInFinder": []
}
```

An empty array unbinds a command. Command names are the `Command` cases in
`Sources/Keys/Command.swift`. Chords are `modifier+…+key`, where modifiers are `cmd`,
`ctrl`, `opt` (or `alt`), and `shift`, and keys are letters, digits, `f1`–`f12`, `space`,
`return`, `tab`, `backspace`, `escape`, `insert`, `home`, `end`, `pageup`, `pagedown`,
`up`/`down`/`left`/`right`, punctuation names such as `period` / `comma` / `backslash` /
`leftbracket`, and `keypadplus` / `keypadminus` / `keypadmultiply` / `keypadenter`. The
keypad keys are spelled out so that `+` is never both a separator and a key name.

Changes take effect on relaunch. A malformed entry is skipped rather than guessed at.
