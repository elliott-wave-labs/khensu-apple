// SPDX-License-Identifier: AGPL-3.0-only

import KhensuKit
import SwiftUI

struct OnboardingView: View {
    enum Step: Hashable { case profile, recovery }

    @Environment(AppModel.self) private var model
    @State private var path: [Step] = []
    @State private var recoveryPhrase: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeView { path.append(.profile) }
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .profile:
                        ProfileSetupView { phrase in
                            recoveryPhrase = phrase
                            path.append(.recovery)
                        }
                    case .recovery:
                        RecoveryKitView(words: recoveryPhrase) {
                            Task { await model.finishOnboarding() }
                        }
                    }
                }
        }
    }
}

private struct WelcomeView: View {
    let next: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            StatusBarScrim()
            DotNetwork(count: 90, opacity: 0.55)
                .frame(maxWidth: 520, maxHeight: 520)
                .offset(y: -120)
            VStack(spacing: 18) {
                Spacer()
                CrescentLogo(size: 96)
                Text("khensu.nu")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                Text("Private messages that travel like the moon: unseen, on their own schedule.")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)
                Spacer()
                VStack(alignment: .leading, spacing: 14) {
                    Feature(symbol: "person.crop.circle.badge.xmark", title: "No phone number", text: "Your identity is a key on this device.")
                    Feature(symbol: "atom", title: "Post-quantum from day one", text: "ML-KEM-1024 and ML-DSA-87 for every message.")
                    Feature(symbol: "point.3.connected.trianglepath.dotted", title: "Nobody sees who talks to whom", text: "Every message crosses a mixnet run by independent operators.")
                }
                .padding(.horizontal, 28)
                Spacer()
                Button(action: next) {
                    Text("Create my identity")
                        .font(.headline)
                        .frame(maxWidth: 360)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .foregroundStyle(.black)
                .controlSize(.large)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }
}

private struct Feature: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: 36)
                .foregroundStyle(Palette.starlight)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ProfileSetupView: View {
    let done: ([String]) -> Void

    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var handle = ""
    @State private var appLock = true
    @State private var working = false
    @State private var error: String?

    private var handleError: String? {
        guard !handle.isEmpty else { return nil }
        do {
            _ = try Handle(handle)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .textContentType(.name)
                    .writingToolsBehavior(.disabled)
            } header: {
                Text("Your name")
            } footer: {
                Text("Only people you talk to see it. It's encrypted with your profile key.")
            }

            Section {
                HStack(spacing: 0) {
                    TextField("handle", text: $handle)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .writingToolsBehavior(.disabled)
                    Text(".khensu.nu").foregroundStyle(.secondary)
                }
                if let handleError {
                    Label(handleError, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                }
            } header: {
                Text("Handle (optional)")
            } footer: {
                Text("Handles are permanent: once claimed, nobody can ever rename, transfer or reuse it. Registration opens with the key transparency log, so yours stays **pending** on this device until then.")
            }

            Section {
                Toggle(isOn: $appLock) {
                    Label("Lock with Face ID", systemImage: "faceid")
                }
            } footer: {
                Text("Your messages stay encrypted until you unlock the app. The key never leaves the Secure Enclave.")
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Your identity")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if working {
                    ProgressView()
                } else {
                    Button("Create", systemImage: "checkmark") { create() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || handleError != nil)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if working {
                Label("Creating post-quantum keys…", systemImage: "key.horizontal")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
    }

    private func create() {
        working = true
        error = nil
        Task {
            do {
                let phrase = try await model.createIdentity(displayName: name, handle: handle, appLock: appLock)
                done(phrase)
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

private struct RecoveryKitView: View {
    let words: [String]
    let done: () -> Void
    @State private var confirmed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if words.isEmpty {
                    Label("This build's core doesn't hand out the recovery kit yet. You'll be asked to write it down before you can claim your handle.", systemImage: "exclamationmark.shield")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Write these 24 words down, in order, and keep them somewhere safe. They are the only way to recover your account if you lose every device. Nobody, including us, can recover it without them.")
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                        HStack(spacing: 6) {
                            Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20, alignment: .trailing)
                            Text(w).font(.body.monospaced())
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .khensuGlass(in: .rect(cornerRadius: 12))
                    }
                }
                .privacySensitive()
                if !words.isEmpty {
                    Toggle("I've written them down", isOn: $confirmed)
                }
                Button {
                    done()
                } label: {
                    Text("Continue").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .foregroundStyle(.black)
                .controlSize(.large)
                .disabled(!confirmed && !words.isEmpty)
            }
            .padding()
        }
        .navigationTitle("Recovery kit")
        .navigationBarBackButtonHidden()
    }
}

#Preview {
    OnboardingView().environment(AppModel.live()).preferredColorScheme(.dark)
}
