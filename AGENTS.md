# Instructions for Swaplight

Read [the architecture](docs/architecture.md) and [UI handoff](docs/ui.md) before implementing. Swaplight is the product name; the local Pencil draft uses its earlier name, Swaplist.

- Build a native macOS app with Swift, SwiftUI, and small AppKit/Darwin adapters. Use standard controls, system type and appearance, and the approved menu bar asset. No Go, Electron, or browser UI.
- Keep collection and process actions behind injectable interfaces. Keep state presentation, grouping, and recommendations separate from OS adapters. Use explicit missing/stale states and a monotonic clock for intervals.
- Treat focus and grouping as evidence with limits. Unknown is not zero. App footprints are estimates; system swap is separate. Don't imply per-process swap or predict bytes reclaimed.
- No auto-quitting, root helper, telemetry, private entitlements, or security setting changes. Never signal an ambiguous, protected, stale, or different process. Revalidate PID and start identity immediately before signaling, and surface OS errors. A force action always needs its own confirmation.
- Run meaningful fixture tests and the documented Xcode build. Exercise real process termination only on a disposable child launched by the test; never use a user's existing apps, terminals, containers, or agents as test targets.
- Do not publish the local Pencil draft, signing materials, machine snapshots, shell arguments, or private paths. The public repository contains only intentionally shared material. Document build instructions and measured limitations before pushing.
