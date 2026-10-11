// SPDX-License-Identifier: AGPL-3.0-only

import KhensuKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        ZStack {
            switch model.phase {
            case .loading:
                Color.black.ignoresSafeArea()
            case .onboarding:
                OnboardingView()
            case .locked:
                LockView()
            case .ready:
                MainTabView()
            }
            // Hide content in the app switcher snapshot.
            if scenePhase != .active && model.phase == .ready && !model.launch.demo {
                PrivacyCover()
            }
        }
        .animation(.smooth, value: model.phase)
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CrescentLogo(size: 64)
        }
    }
}
