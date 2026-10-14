// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

@main
struct WavesApp: App {
    var body: some Scene {
        WindowGroup {
            WavesRootView()
        }
        #if os(macOS)
        .defaultSize(width: 980, height: 720)
        #endif
    }
}
