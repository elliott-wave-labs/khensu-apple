// SPDX-License-Identifier: AGPL-3.0-only

import KhensuKit
import SwiftUI

@main
struct PtahApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @State private var model = AppModel.live()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Palette.starlight)
                .task { await model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            Task {
                switch phase {
                case .background: await model.didEnterBackground()
                case .active: await model.didBecomeActive()
                default: break
                }
            }
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 720)
        #endif
    }
}

#if os(iOS)
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Third-party keyboards could log keystrokes, so the app refuses them.
    func application(_ application: UIApplication, shouldAllowExtensionPointIdentifier extensionPointIdentifier: UIApplication.ExtensionPointIdentifier) -> Bool {
        extensionPointIdentifier != .keyboard
    }
}
#endif
