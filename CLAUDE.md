# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A single-file Objective-C tool that automates **Rekordbox** interaction via macOS Accessibility (AX) APIs. Part of the goRave DJ ecosystem — a tactical bridge tool used during the transition away from Rekordbox dependency. Not a permanent architectural component.

## Build

```bash
clang++ -framework Foundation -framework ApplicationServices -framework Cocoa rb_test.mm -o rb_test
```

No Makefile, no package manager, no Xcode project. Single compilation unit.

## Usage

```bash
./rb_test dump [depth]                # Dump full AX tree (default depth 15)
./rb_test dumpwin [depth]             # Dump all windows (use when dialog is open)
./rb_test menutest [target]           # Test menu navigation only
./rb_test import /path/to/track.mp3   # Full import flow: menu nav + file dialog
./rb_test importdir /path/to/folder   # Full folder import flow
./rb_test probe                       # Grid-based browser area scanning
./rb_test browser                     # Deep inspection of browser group
./rb_test search "query"              # Search field interaction + text injection
./rb_test export                      # List available export devices
./rb_test export DEVICE               # Export currently selected track to device
./rb_test export DEVICE "query"       # Search + select + export in one flow
```

Requires: macOS, Accessibility permission granted in System Settings, running Rekordbox instance. Both the tool **and** Rekordbox need Accessibility permission.

## Architecture

**Single file (`rb_test.mm`)** with these logical sections:

- **Helpers** — `findRekordboxPID()`, `getAXAttribute()`, `getAXFrame()` for AX element access
- **Tree traversal** — `dumpAXTree()`, `findChildByTitle()`, `findElementByRole()`, `findAllTextFields()` for recursive AX tree inspection
- **Menu navigation** — `navigateMenu()` automates File > Import > Track/Folder menu path
- **File dialog** — `interactWithFileDialog()` polls for dialog, injects paths, triggers confirmation
- **Browser search** — `performBrowserSearch()` focuses search field via Cmd+F, injects query text
- **Row selection** — `selectFirstBrowserRow()` sends Tab to move focus from search to first track row
- **Export** — `navigateExportMenu()` walks Track > Export Track > device menu path
- **CLI dispatch** — `main()` routes to mode handlers based on argv

## Key Technical Details

- **C-based AX API** (`AXUIElementRef`, not Swift Accessibility framework)
- **Manual memory management** — `CFRetain`/`CFRelease` on AX elements. Watch for leaks on error paths.
- **Keystroke simulation** — `CGEventCreateKeyboardEvent` for character-by-character text injection
- **Background-safe key events** — `CGEventPostToPSN` sends keyboard events to Rekordbox's process directly, without requiring window focus. Used for Cmd+F (search focus) and text fallback injection.
- **`AXUIElementPostKeyboardEvent`** — Sends keys to a specific process (used for Tab-based row selection). Deprecated since macOS 10.9 but still functional.
- **Polling-based waits** — Dialog detection uses retry loops (e.g., 10 attempts × 300ms) with `usleep()`

## Working With This Code

- **Rekordbox UI changes break automation.** The AX tree structure is version-dependent. Use `dump`/`dumpwin` modes to inspect the current tree when something stops working.
- **Hardcoded delays** between UI interactions (200ms–500ms). May need tuning on slower systems.
- **File dialog confirmation is gated** — the confirm button is logged but not pressed unless explicitly triggered, as a safety measure.
- **No tests** — verification is manual via tree dumps and observing Rekordbox behavior.
- **All operations run in background** — no need to focus/activate Rekordbox window. Uses process-targeted events throughout.
