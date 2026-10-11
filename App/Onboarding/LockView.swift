// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

/// The app unlock screen, styled like the lock screen: a turning dot network and the crescent.
struct LockView: View {
    @Environment(AppModel.self) private var model
    @State private var unlocking = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            DotNetwork(count: 110, opacity: 0.6)
                .frame(maxWidth: 640, maxHeight: 640)
            VStack(spacing: 16) {
                Spacer()
                CrescentLogo(size: 84)
                Text("khensu.nu is locked")
                    .font(.title2.weight(.semibold))
                Text("Messages stay encrypted until you unlock.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    unlock()
                } label: {
                    Label(model.appLockPolicy == .passcodeOnly ? "Unlock with passcode" : "Unlock", systemImage: model.appLockPolicy == .passcodeOnly ? "lock.open" : "faceid")
                        .font(.headline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled(unlocking)
                .padding(.bottom, 48)
            }
        }
        .task {
            if !model.launch.demo { unlock() }
        }
    }

    private func unlock() {
        guard !unlocking else { return }
        unlocking = true
        Task {
            await model.unlock()
            unlocking = false
        }
    }
}
