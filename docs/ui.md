# Native UI handoff

Use the approved template mark in [design](../design/swaplight-menubar.svg). Preserve its three rows and opposing arrows. The local `design/Swaplist.pen` file is the editable visual reference; the draft title reflects the earlier name. The product UI says **Swaplight**. The Pencil file is deliberately omitted from Git; this document is the complete handoff for a fresh clone.

## Native surfaces

- **Menu bar:** `MenuBarExtra` in window style; monochrome template icon, with a pressure state that remains legible without color. Accessible label names the state. Opening the menu should be fast even while a scan is in progress.
- **Overview:** compact vertical stack, roughly 340 pt wide as a starting point. Header and Settings; Memory Pressure label; RAM and Swap side by side; Compressed and last sample on a quiet line; up to three review rows with name, reason, footprint, and disclosure; All Apps and All Processes. No marketing header, cards around every row, web fonts, or chart required.
- **Inspector:** standard macOS window and toolbar, source list for Overview, Apps and Processes, search, sortable table with column headers, and a details inspector. Apps rows show footprint, observed process count and last focus; select a row to inspect contributing helpers. Processes has a native segmented Tree / Flat List control, scope filter, and columns for process, PID, footprint and optionally recent CPU. Prefer AppKit outline/table interop only where the SwiftUI controls cannot deliver the native interaction.
- **Details:** show name, executable, PID, source or parent, owner, footprint, resident memory if available, activity and uptime. Expose scope explicitly: Quit App, Stop Process, or Read Only. Show Keep Running as a user preference, not a security permission.
- **Settings:** native Settings scene, Form, Toggle and standard buttons. Keep Running list, login item registration status, opt-in pressure notifications, and Clear Focus History. Denied login or notification settings show the OS state and next action.

Use system fonts, labels, materials, native table selection, and semantic destructive roles. Use monospaced digits for changing metrics. Keep keyboard focus/selection stable, support Escape and visible focus rings, and provide VoiceOver labels for pressure, metric units, disclosure controls, and stop outcomes. Color reinforces text rather than replacing it.

## Flows

1. **Diagnose:** open menu bar → read pressure, RAM and swap → open a suggested app or choose All Apps / All Processes. Never require login or a wizard.
2. **Investigate:** select Chrome → review counts and footprint → View Processes applies the app scope. Clear scope to return to all processes. For terminal jobs, follow Ghostty → shell → command → worker. Keep unrelated and unassigned items searchable.
3. **Quit:** select an app → Quit App → show waiting if the app is handling unsaved work → verify exit or offer recovery. Existing Codex work and running databases may be impacted; suggest reviewing or protecting them when relevant, without claiming knowledge of active sessions.
4. **Stop one worker:** select Node worker → Stop Process → alert names the process and PID, explains that Ghostty stays open and the worker may respawn → Cancel or Stop → verify result. If it times out, offer Review Force Stop → independent alert → force only on confirmation. Never implicitly stop the parent or all siblings.
5. **Protect:** choose Keep Running on an eligible item → it leaves recommendations → manage it in Settings. Preserve discoverability in the full lists.

## States and sample copy

| State | UI behavior |
|---|---|
| First sample | Stable placeholders, “Reading memory…”; focus reads “Not observed” until measured. |
| Normal / Elevated / Critical / Unknown | Always show the text status. No automatic process action. |
| No suggestions | “No apps suggested to quit right now.” Preserve both inspector links. |
| No matches | “No matching processes.” Offer Clear Search. |
| Partial / denied | Keep known readings, label missing ones Unavailable, explain why an action is read-only. |
| Stale | “Last updated 2 minutes ago.” Keep last good values labeled. Disable stopping until revalidation. |
| Stopping / exited | Show progress on the target; only say “Exited” after verification. Report the next observed system sample separately. |
| Timeout / replaced | “This process is still running” or “A replacement process appeared.” No automatic retry against a new PID. |
| Force confirmation | Native destructive alert. Default keyboard action is non-destructive; explain unsaved work can be lost. |

Illustrative overview: “Elevated · RAM 15.0 / 16 GB · Swap 8.5 GB · Compressed 4.8 GB”; “Chrome · 4.4 GB · 27 observed processes”; “Expo · 4.2 GB · started in Ghostty”. These are fixtures, not live readings or guaranteed reclaim.
