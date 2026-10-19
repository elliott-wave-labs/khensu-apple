// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

extension View {
    /// Header sits below the status bar on a blurred (dimmed) bar — content
    /// may scroll under it, but the title/controls never collide with the
    /// clock, Dynamic Island or battery. Stock Liquid Glass material only.
    func appNavChrome() -> some View {
        self
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
    }
}

/// Dimmed blur strip painted into the status-bar area for screens without a
/// navigation bar (onboarding, lock). Content itself stays in the safe area.
struct StatusBarScrim: View {
    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea(edges: .top)
                .frame(height: 8)
                .opacity(0.85)
            Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
    }
}
