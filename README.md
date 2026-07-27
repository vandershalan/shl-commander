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

See [`Resources/default-keymap.json`](Resources/default-keymap.json) for the shipped
bindings. Overrides go in
`~/Library/Application Support/shl-commander/keymap.json` and are merged over the defaults
at launch.
