# Swaplight

Swaplight is a local macOS menu bar app for understanding memory pressure and choosing what to close. It shows system RAM, compression and swap, then lets you inspect the apps and host processes behind a footprint estimate. You can protect work with Keep Running and review the scope of each process action before confirming it.

![Swaplight menu bar mark](design/swaplight-menubar.svg)

Requires macOS 14 or later. Build with Xcode 26.2 (the version used for verification); there are no package dependencies. From the repository root:

```sh
xcodebuild -scheme Swaplight -destination 'platform=macOS' -derivedDataPath DerivedData build
open DerivedData/Build/Products/Debug/Swaplight.app
```

Click the Swaplight mark in the menu bar. **All Apps** and **All Processes** open the inspector. Select a row to see its details or mark it **Keep Running**. The gear opens Settings. The app runs without a Dock icon.

The project uses an ad hoc signature for local builds. The source here has not been packaged or distributed. See [verification](docs/verification.md) for test commands, measured results and limits, [architecture](docs/architecture.md) for data and action policy, and the [UI handoff](docs/ui.md) for the native controls and flows.
