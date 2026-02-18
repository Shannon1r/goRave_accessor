# Rekordbox AX Tree — Key Findings

Research notes from investigating the Rekordbox macOS Accessibility (AX) tree structure.

## PID Selection

Multiple `rekordbox`-related processes run simultaneously:
- `rekordbox` (main UI process) — has the window and JUCE elements
- `rekordboxAgent` — background process with only menu bars, no windows
- Various helper processes (renderer, GPU, network, etc.)

`findRekordboxPID()` must prefer exact match "rekordbox" over "rekordboxAgent", since `containsString:@"rekordbox"` matches both.

## JUCE Accessibility Gap

Rekordbox uses the **JUCE framework** for its browser area. JUCE accessibility elements (search field, track rows, filter buttons like `SelectSearchFilterButton`) are **not linked** via `AXChildren` from the native window hierarchy.

- The native content group (AXGroup covering the full window content area) reports **0 children**
- `AXChildrenInNavigationOrder`, `AXVisibleChildren`, `AXContents` — all return empty
- But JUCE elements **do exist** and respond to:
  - Position hit-testing (`AXUIElementCopyElementAtPosition`)
  - Focus-based access (`kAXFocusedUIElementAttribute` after triggering focus)

This is a known JUCE behavior: `accessibilityHitTest:` works but `accessibilityChildren` on the parent NSView doesn't return the JUCE elements.

## Search Field Access

The search field identity:
- Role: `AXTextArea`
- Subrole: `AXUnknown`
- No "search" in title, help, or any attribute
- Help text misleadingly mentions "playlist" and "palette"
- Parameterized attributes: `AXRangeForLine`, `AXLineForIndex`, `AXStringForRange`, `AXBoundsForRange`, `AXRangeForPosition`, `AXRangeForIndex`, `AXReplaceRangeWithText`, `AXAttributedStringForRange`

**Access method**: Send **Cmd+F** via `CGEventPostToPSN` (targets process directly, works in background without window focus). This focuses the search field. Then read `kAXFocusedUIElementAttribute` to get the AXTextArea reference.

## Track Row Selection

- No standard AXTable/AXOutline/AXList/AXRow elements — Rekordbox uses custom AXGroup elements for track rows
- Row elements have 0 children and 0 actions
- `AXPress` on row elements returns success but does nothing
- **Working method**: Send **Tab** from the focused search field via `AXUIElementPostKeyboardEvent`. This moves focus to the first track row in the filtered results.

## Background Event Delivery

- `CGEventPostToPSN(&psn, event)` — sends keyboard events to a specific process serial number, works without window focus. Used for Cmd+F and keystroke-based text injection.
- `AXUIElementPostKeyboardEvent(appRef, ...)` — sends keys to a specific process. Deprecated since macOS 10.9 but still functional. Used for Tab key.
- `CGEventPost(kCGHIDEventTap, event)` — sends to frontmost app only. **Avoid** for background operation.

## Window Availability

The Rekordbox window may not appear in `kAXWindowsAttribute` intermittently — possibly when the app is not the active/focused application. Operations may need retries.

## Native Tree Structure (PERFORMANCE Mode)

Window frame example: `(0,33 1470x858)`. Direct children of the window:

| Index | Role | Frame | Children | Notes |
|-------|------|-------|----------|-------|
| 0 | AXGroup | full content area (1470x830) | 0 | JUCE browser container — empty via AXChildren |
| 1 | AXGroup | upper portion (1470x523) | 129+ | Deck area — native elements, fully enumerable |
| 2-3 | AXGroup | bottom bar (1470x23) | 0 | Status bar containers |
| 4-5 | AXStaticText | status bar | 0 | Status text fields |
| 6 | AXButton | "btnMultiWindow" | 0 | Split screen toggle |
| 7-9 | AXButton | window chrome | 0 | Close/minimize/fullscreen |
| 10 | AXStaticText | title bar | 0 | Window title "rekordbox" |

The deck area (child 1) contains all DJ controls: deck layout popup, transport controls, EQ/mixer, hot cue pads, waveforms, stem controls, lighting bar. These are standard AX elements fully accessible via tree walking.

The browser area (child 0) is the JUCE gap — all elements inside are invisible to tree enumeration but accessible via hit-testing or focus.
