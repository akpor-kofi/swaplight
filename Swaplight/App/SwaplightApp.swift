import SwiftUI

@main
struct SwaplightApp: App {
    @State private var store: Store

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-fixture") {
            _store = State(initialValue: DebugFixture.make())
            return
        }
        #endif
        let store = Store.live()
        _store = State(initialValue: store)
        store.start()
    }

    var body: some Scene {
        #if DEBUG
        if #available(macOS 15.0, *) {
            Window("Swaplight Preview", id: "preview") {
                Overview(popover: true, visibilityKey: "preview")
                    .environment(store)
                    .fixedSize()
                    .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--ui-light") ? .light : nil)
            }
            .windowResizability(.contentSize)
            .defaultLaunchBehavior(ProcessInfo.processInfo.arguments.contains("--ui-preview") ? .presented : .suppressed)
        }
        #endif
        MenuBarExtra {
            Overview(popover: true).environment(store)
        } label: {
            HStack(spacing: 3) {
                Image(.menuMark).renderingMode(.template)
                if store.pressure != .normal {
                    Image(systemName: store.pressure.symbol)
                }
            }
            .accessibilityLabel("Swaplight, memory pressure: \(store.pressure.rawValue)")
        }
        .menuBarExtraStyle(.window)

        Window("Swaplight", id: "inspector") {
            Inspector().environment(store)
                .frame(minWidth: 850, minHeight: 435)
                #if DEBUG
                .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--ui-light") ? .light : nil)
                #endif
        }
        .defaultSize(width: 1020, height: 560)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh Swaplight", action: store.refresh)
                    .keyboardShortcut("r")
            }
        }

        Settings { SettingsView().environment(store) }
    }
}
