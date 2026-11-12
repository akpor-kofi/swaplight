# Swaplight architecture

## Product contract

A local-only menu bar monitor that answers: **Is memory pressure elevated? What is contributing? What can I safely choose to stop?** The first release covers host applications and user-owned background jobs generically. It is a monitor and a user-directed process controller, not a RAM cleaner or a service supervisor.

**Scope:** system memory and swap; process footprint; app and process views; observed focus history; review suggestions; user protection rules; normal app quit and single-process stop; explicit force stop; opt-in login item and pressure notifications. No root helper, kernel extension, cloud service, data collection, automatic termination, blanket job-tree kills, guest/container inspection, or service-specific shutdown integrations in v1.

## Platform and project structure

Use one SwiftUI macOS application target with Swift 6 and strict concurrency, a shared Xcode scheme, and a test target. Start with macOS 14 as the minimum; validate every chosen API at that target and test the minimum supported OS before release. Default to Apple frameworks, with no third-party dependencies required. Use `LSUIElement`, `MenuBarExtra` with window style, a named inspector window, and a SwiftUI Settings scene. Fall back to a small AppKit `NSStatusItem` / `NSPopover` adapter only if window activation or menu behavior needs it. Choose a team-owned bundle identifier before distribution; use unsigned or ad hoc local builds for routine testing as appropriate.

| Area | Responsibility |
|---|---|
| `App/` | Scenes, dependency wiring, lifecycle, command routing, menu bar label |
| `Features/Overview/` | System summary and recommended review candidates |
| `Features/Inspector/` | Applications table, process tree and flat table, selection and details |
| `Features/Settings/` | Keep Running, login item, notifications and local history |
| `Core/` | Snapshot types, process identity and evidence, grouping, ranking and action policy |
| `Platform/` | Mach/Darwin sampling, AppKit workspace observation, user notifications, ServiceManagement, and termination adapters |
| `Tests/` | Fixtures, state and policy tests, opt-in disposable-process integration checks |

Use a shared `@MainActor` observable store for views. Run sampling and grouping away from the main actor; keep AppKit interactions on their required actor. Inject interfaces for memory samples, process inventory, application inventory, clock, preferences, and process control. Present immutable, timestamped snapshots. In production there is one sampling loop: coalesce concurrent refreshes, discard obsolete results, and never start one timer per scene. Use typed bytes and timestamps internally.

## Data sources and trust

| Data | Proposed source and semantics |
|---|---|
| Total RAM | `ProcessInfo.physicalMemory` or `hw.memsize`. |
| System RAM and compression | `host_statistics64` with `HOST_VM_INFO64` and the kernel page size. Keep raw counters internally. Validate conversion, purgeable and file-backed handling, and overlap against Activity Monitor and `vm_stat` under idle and load. Label any derived RAM usage **estimate** until semantics are validated; do not add compressed RAM to occupied RAM a second time. |
| System swap | Evaluate `sysctlbyname("vm.swapusage")` and its SDK structure. If unavailable, show an unavailable state; never infer swap from virtual address space. If showing rates, use deltas of system counters over a measured interval, with reset detection. |
| Pressure | Dispatch memory pressure events (`normal`, `warning`, `critical`) mapped to Normal, Elevated, Critical. A change source is not necessarily an initial reading; show **Unknown** until an initial supported reading or event is available. Never derive a pressure grade solely from free RAM or existing swap. |
| GUI application inventory | `NSWorkspace.runningApplications`, plus known bundle IDs and executable locations. Workspace activation events update the current user's last observed focus time; seed the current frontmost app at start. Never infer past focus from launch date, file timestamps, or inactivity. |
| Process inventory | Prototype a Darwin adapter using SDK-available process enumeration and per-PID metadata/resource usage. Evaluate `proc_listpids`, `proc_pidinfo`, and `proc_pid_rusage` behind the adapter and test availability on supported macOS versions. Treat libproc interfaces as compatibility-sensitive; no private entitlements or dynamic lookup of private symbols. Use process footprint for ranking and show resident size separately when known. An unreadable record is partial, not zero. |
| Recent CPU and I/O | Derive deltas across samples of the same process identity. Label insufficient evidence. Low recent activity does not prove idle or safe to stop. |

Use `(PID, process start identity)` for stable selection and action targeting. Include owner UID, PPID, bundle/executable identity when known, and independently optional metrics. Use monotonic time for durations, sample age, and deadlines; use wall clock for display and persisted focus dates. Preserve the last successful reading independently for system and process data. Never present stale data as live.

## Process tree and app grouping

Keep the observed PID tree separate from an attributed app/workload view. Build edges only between observed parents and children with plausible start order. Handle missing parents, reparenting, cycles, helpers launched by macOS, and a process disappearing mid-scan. Rebuild each sample; do not carry stale ownership links forward as facts.

1. Seed observed running apps by app PID and known bundle/executable identity. When AppKit omits the launch date, read the kernel start and owner on both sides of an exact executable match. The inventory and action controller check that identity against their own process reads.
2. Attribute directly verifiable descendants and helpers associated with the app bundle. Use executable location and ancestry together where available. Do not group by executable basename alone.
3. For terminal jobs, identify the command root below its interactive shell where defensible and show its observed children. Show a standalone process if a workload root cannot be established. No raw command-line capture required for v1.
4. Keep unknowns in **Unassigned**. Tag each attributed record with its evidence and confidence. Assign a PID at most once per app grouping; never add app totals and nested job totals into the same aggregate. Show counts as **observed**, with known memory subtotal and an unavailable count if partial.
5. Review lists focus on measured user workloads eligible for review under the base action policy. Protected system entries and unreadable footprints stay out of these lists; a shell can appear as read-only tree context for an observed workload. Keep Running remains visible for user-managed protection.
6. Docker, browsers, editors, and coding agents follow these rules. Guest processes inside a VM aren't host PIDs. Tabs and app-level task state can't be inferred from process names; later integrations are optional, capability-specific adapters.

Example: `Ghostty → zsh → Expo → Node worker`. The worker has its own action. The parent tree is useful context, not a list of targets to kill. The initial release does not send a signal to a process group or recursively stop descendants. A watcher may restart a worker; report that, and never retry against the replacement automatically.

## Recommendations

Rank eligible apps and terminal jobs together once their measured footprint reaches 256 MiB. The score starts at measured footprint. For apps with observed focus, multiply it by `1 + 0.25 × min(hours since observed focus / 2, 1)`. Apps with unknown focus and terminal jobs use their measured footprint as the score. Break ties by larger measured footprint, then lower PID. Show the measured footprint and a plain-language reason. CPU can appear as context for a terminal job.

Show the active app’s measured footprint above the suggestions. If Swaplight takes focus, keep showing the last active app as long as its identity still matches. Exclude frontmost workloads, protected processes, Swaplight itself, stale identities, and ambiguous groups from suggestions. Preserve the order of existing suggestions while the popover is open so rows stay under the pointer.

## Process control

Actions are user-initiated and independent of sampling. The menu bar popover can search and review a target, confirm a request and show its outcome in place. The inspector is optional. The controller owns eligibility and rechecks the target at execution time; hiding a button is not an authorization mechanism.

| Action | Behavior |
|---|---|
| Quit App | Resolve the intended `NSRunningApplication` and request `terminate()`. Let the app handle unsaved work. Verify exit instead of treating an accepted request as success. |
| Stop Process | After a scope-aware confirmation, refresh identity and ownership. Send `SIGTERM` only to the verified eligible PID. This requests termination; it does not guarantee app-level cleanup. |
| Force Stop | Separate explicit confirmation after ordinary stop fails or times out. Revalidate again; use the matching native force action or `SIGKILL` for an eligible process. Never auto-escalate. |
| Read only | System/protected processes, another user's processes, missing identity, ambiguous ownership, and stale or unavailable data. Keep Running entries stay out of suggestions and require unprotecting before action. |

Reject nonpositive PIDs, Swaplight, core or protected services, and any owner or identity mismatch. Never call a shell with interpolated input; signals go through a typed adapter. Revalidate PID, start identity, UID, and policy immediately before signaling. This reduces PID reuse risk but does not make PID-based signaling atomic. Fail closed if identity is unavailable. After an action, poll for the original identity to exit within a bounded deadline, distinguish already gone, replaced, timeout, and denied, and take a fresh memory sample. Pressure changes are observations, not proof of bytes reclaimed. Keep detailed ephemeral results in memory without persisting command arguments or diagnostics.

## Sampling, persistence, and performance

- Start with 2-second visible refresh, slower system sampling when closed, and no continuous full inventory while idle unless required by a measured feature. Coalesce bursts and apply backoff after errors. Pause while asleep and refresh on wake. Keep system summary responsive even when process enumeration is slow.
- Dispatch pressure events are lightweight. Use throttled notifications only after opt-in; avoid repeated warnings. Start with a bounded focus map and store just app identity and timestamp locally. Offer Clear Focus History, without touching user protection settings.
- Use `UserDefaults` for small preferences and the bounded focus map. No background database, network service, full process history, root access, Accessibility permission, or Full Disk Access required by design. If an operation is unavailable, degrade gracefully instead of requesting broad access.
- Measure idle CPU, RSS/footprint, sampling duration and responsiveness on this Mac and another supported configuration. Use an initial target of under 1% of one CPU core while the popover is closed; record actuals and tradeoffs, do not claim an unmeasured budget.

## Build and release

1. **Feasibility first.** Build the menu bar shell and a read-only probe. Verify RAM/swap semantics, process visibility, start identity, and parent links. Compare to Activity Monitor, `vm_stat`, `sysctl vm.swapusage`, and a known process tree. Record differences and permission limits. Prototype a sandboxed build independently before making App Store claims.
2. **Read-only experience.** Implement system samples, app and process tables, focus observation, settings persistence, UI states, and review candidates. Include fixture data for deterministic UI tests or previews.
3. **User-directed actions.** Add confirmation and outcomes. Use disposable test children; no tests that terminate live third-party workloads. Add optional login via `SMAppService.mainApp` and notifications with user consent.
4. **Verification and beta.** Build locally, test native light and dark appearance, keyboard and VoiceOver, permission-denied and stale behavior, sleep/wake, and monitoring overhead. Verify signed behavior on a clean macOS user profile before distributing.
5. **Distribution.** Prefer direct distribution with the existing Apple Developer team, Developer ID Application, Hardened Runtime, notarization, and a stapled, verified DMG. The same team can create a separate macOS App Store Connect record if eligible. App Store/TestFlight build requires the applicable signing and sandboxing; make it a separate release decision if process functionality is restricted. Never commit certificates or credentials. This implementation request does not authorize signing, notarizing, or publishing app binaries.

## Acceptance checks

- Menu bar app launches without a Dock icon; readout exposes total RAM, occupied RAM or a labeled estimate, compressed memory, system swap, pressure, and freshness. Unavailable values never read as zero.
- Real process data supports searching, sorting, row selection, counts, app breakdown, and a terminal command tree. Fixtures cover detached helpers, duplicated evidence, partial samples, disappeared parents, and PID reuse.
- Frontmost, protected, stale, and uncertain workloads are handled per policy. Focus history survives relaunch and clears independently. History before observation reads Not observed.
- Regular quit, process stop, cancellation, timeout, force confirmation, access denied, and respawn have distinct UI states. Mock tests prove an ineligible PID is never signaled; a disposable integration child demonstrates verified exit.
- Xcode build and meaningful tests pass. Document macOS version and hardware tested, known attribution gaps, and observed sampler overhead. No untested claims about sandbox capabilities or release readiness.

## Primary references

- [SwiftUI MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)
- [NSWorkspace activation notifications](https://developer.apple.com/documentation/appkit/nsworkspace/didactivateapplicationnotification)
- [Dispatch memory pressure source](https://developer.apple.com/documentation/dispatch/dispatchsourcememorypressure)
- [Apple libproc interface and compatibility notes](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.h)
- [NSRunningApplication terminate](https://developer.apple.com/documentation/appkit/nsrunningapplication/terminate())
- [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Apple macOS distribution](https://developer.apple.com/macos/distribution)
