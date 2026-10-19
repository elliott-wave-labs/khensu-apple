// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

@main
struct MomentsApp: App {
    @State private var store = ProjectStore()

    var body: some Scene {
        WindowGroup {
            MomentsRootView()
                .environment(store)
                .preferredColorScheme(.dark)
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 760)
        #endif
    }
}
