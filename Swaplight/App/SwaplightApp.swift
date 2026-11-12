import SwiftUI

@main
struct SwaplightApp: App {
    @State private var store: Store

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-fixture") {
            let pressure = ProcessInfo.processInfo.environment["SWAPLIGHT_FIXTURE_PRESSURE"]
                .flatMap(Pressure.init(rawValue:)) ?? .elevated
            _store = State(initialValue: DebugFixture.make(pressure: pressure))
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
            Group {
                switch store.pressure {
                case .normal:
                    Image(.pressureNormal).renderingMode(.original)
                case .unknown:
                    HStack(spacing: 3) {
                        Image(.menuMark).renderingMode(.template)
                        Image(systemName: Pressure.unknown.symbol)
                    }
                case .elevated:
                    Image(.pressureElevated).renderingMode(.original)
                case .critical:
                    Image(.pressureCritical).renderingMode(.original)
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
