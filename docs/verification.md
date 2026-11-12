# Build and verification

Use the shared `Swaplight` scheme in `Swaplight.xcodeproj`. The [README](../README.md) shows the Debug build and launch commands. Use `-configuration Release` for a local Release build. Both use Swift 6, the macOS 14 deployment target, and ad hoc signing.

Run model, policy and store tests without GUI input:

```sh
xcodebuild -scheme Swaplight -destination 'platform=macOS' -derivedDataPath DerivedData \
  -only-testing:SwaplightTests -parallel-testing-enabled NO test
```

Run UI tests from a logged-in, unlocked macOS desktop:

```sh
xcodebuild -scheme Swaplight -destination 'platform=macOS' -derivedDataPath DerivedData \
  -only-testing:SwaplightUITests -parallel-testing-enabled NO test
```

The UI suite opens the live menu and inspector. Its destructive flows launch a Debug build with an in-memory fixture and simulated process controller. The simulation cannot call native quit or signal APIs. If the runner times out initializing automation or accessing files in the checkout, retry with an unlocked desktop and a temporary directory passed to `-derivedDataPath`.

Run the opt-in native process checks separately:

```sh
xcodebuild -scheme 'Swaplight Disposable Child' -destination 'platform=macOS' \
  -derivedDataPath DerivedData -parallel-testing-enabled NO test
```

This scheme enables tests that build and launch their own short-lived command line children. They verify the child's parent, owner, executable and start identity before requesting an action. No existing app, terminal, container or agent is a target. The test tool is a separate build product and is not embedded in the app.

To rerun the read-only feasibility probe on the current Mac:

```sh
mkdir -p build
xcrun swiftc -swift-version 6 Swaplight/Platform/Kernel.swift Tools/Feasibility.swift \
  -o build/feasibility
build/feasibility
vm_stat
sysctl vm.swapusage
```

The probe checks start and parent metadata on its own short-lived child, touches 96 MiB in its own address space, and prints aggregate results. Compare the memory tab in Activity Monitor on the same host. Measurements are sequential; system counters can change between readings.

## Results

- The standard scheme passed nine model, policy and store tests plus three UI tests. The live UI test opened the native status item, read the memory summary and opened Processes. Fixture UI tests covered app breakdowns, scope, Keep Running, search, Quit App, Return to cancel a stop request, timeout, and separate force confirmation. A separate native fixture walkthrough covered focus history clearing and the access-denied state. The stale and possible replacement cases are covered by store tests.
- The disposable scheme passed all eleven unit and integration tests. The two native tests rejected a mismatched start identity before signaling, verified a SIGTERM exit, and verified SIGKILL after a disposable child ignored the ordinary request. App quit was exercised through the fixture; native quit was not tested against an existing app.

## Observations

- Tested with Xcode 26.2 on macOS 26.1, an Apple silicon Mac with 16 GiB RAM. The read-only shell and the full app both launched. Debug and Release builds compile for a minimum of macOS 14; that OS and Intel have yet to be tested at runtime.
- The kernel page size and zero swap reading agreed with `vm_stat` and `sysctl vm.swapusage`. Installed RAM and the scale of compressed memory agreed with Activity Monitor. The occupied RAM estimate differed from Activity Monitor; the displays are sampled independently and may use different accounting. The touched allocation increased the probe's footprint by about 96 MiB. Nonzero swap and transitions under real pressure were not induced.
- On this host the read-only probe enumerated roughly 800 positive PIDs, with start identity and resource usage readable for roughly two thirds. The complete sampler and grouping took about 8–81 ms across eight local reads. Unreadable and vanished processes limit observed counts and links. A disposable pseudo-terminal session produced the expected observed shell and command relationship.
- A roughly 34-second Release sample with Swaplight closed in the menu bar used about 0.001% of one CPU core, 14 MiB physical footprint and 74 MiB resident memory. This is a short run on one host with the desktop locked. It does not measure open-window redraw cost or establish a budget on other hardware.

## Known limits

- Pressure remains **Unknown** until macOS delivers a dispatch pressure event. A low amount of free RAM or a nonzero swap reading does not establish a pressure state. The RAM total and RAM estimate are host readings. The app never estimates per-process swap or expected reclaimed memory.
- App groups use matching executable, bundle and parent evidence. Detached helpers outside a known bundle can remain unassigned. A terminal job is inferred from an observed shell, controlling terminal and parent links. Guest processes, tabs, command arguments, and app-specific task state are outside this model. The Apps table retains unverified workspace rows with unavailable breakdowns.
- Keep Running applies to an app identity and verifiable descendants or to all instances of a selected executable. It is local to Swaplight and cannot guarantee that some other app or supervisor keeps a process alive. System executables, unverified targets and other users' processes are read only.
- PID/start checks minimize reuse risk. macOS PID signaling is not atomic with identity validation. Exit is verified for the selected identity only. A new matching executable under the same observed parent is described as a possible replacement; it is never stopped automatically.
- Runtime checks on macOS 14, a second machine, live pressure notifications, login approval, sleep/wake, VoiceOver, a clean user profile and distribution signing or sandboxing are separate verification work.
