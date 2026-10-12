// SPDX-License-Identifier: AGPL-3.0-only

import KhensuKit
import SwiftUI

struct SettingsView: View {
    enum Page: Hashable { case profile, appLock, notifications, privacy, devnet, networkTest, sunu, about, licences }

    @Environment(AppModel.self) private var model
    @State private var path: [Page] = []
    @State private var confirmWipe = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink(value: Page.profile) {
                        HStack(spacing: 14) {
                            Avatar(title: model.identity?.displayName ?? "", size: 60)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.identity?.displayName ?? "").font(.title3.weight(.semibold))
                                if let h = model.identity?.handle {
                                    HandleLabel(handle: h)
                                }
                                Text(model.identity?.address.short ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Privacy and Security") {
                    NavigationLink(value: Page.appLock) {
                        LabeledContent {
                            Text(model.appLockPolicy.title)
                        } label: {
                            Label("App Lock", systemImage: "faceid")
                        }
                    }
                    NavigationLink(value: Page.notifications) { Label("Notifications", systemImage: "bell.badge") }
                    NavigationLink(value: Page.privacy) { Label("Privacy", systemImage: "hand.raised") }
                }

                Section("Network") {
                    NavigationLink(value: Page.devnet) {
                        LabeledContent {
                            Text(model.connection.summary)
                        } label: {
                            Label("Devnet", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                    }
                    NavigationLink(value: Page.networkTest) {
                        LabeledContent {
                            if let n = model.network, n.loopsSent > 0 {
                                Text("\(n.loopsReturned)/\(n.loopsSent) loops")
                            }
                        } label: {
                            Label("Network Test", systemImage: "waveform.path.ecg")
                        }
                    }
                    NavigationLink(value: Page.sunu) {
                        LabeledContent {
                            Text("Not paired")
                        } label: {
                            Label("suñůlink.shield", systemImage: "antenna.radiowaves.left.and.right")
                        }
                    }
                }

                Section("About") {
                    NavigationLink(value: Page.about) { Label("About khensu.nu", systemImage: "moon.stars") }
                    NavigationLink(value: Page.licences) { Label("Licences", systemImage: "doc.text") }
                }

                Section {
                    Button("Panic Wipe", systemImage: "flame", role: .destructive) { confirmWipe = true }
                        .foregroundStyle(.red)
                } footer: {
                    Text("Erases the keys that protect your messages, so they become unreadable at once, then deletes them. This can't be undone.")
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: Page.self) { page in
                switch page {
                case .profile: ProfileView()
                case .appLock: AppLockSettingsView()
                case .notifications: NotificationSettingsView()
                case .privacy: PrivacySettingsView()
                case .devnet: DevnetSettingsView()
                case .networkTest: NetworkTestView()
                case .sunu: SunuView()
                case .about: AboutView()
                case .licences: LicencesView()
                }
            }
            .confirmationDialog("Wipe everything on this device?", isPresented: $confirmWipe, titleVisibility: .visible) {
                Button("Wipe Now", role: .destructive) { Task { await model.panicWipe() } }
            } message: {
                Text("Your identity, keys and messages are erased from this device. Without your recovery kit the account can't be restored.")
            }
            .onAppear {
                switch model.launch.screen {
                case .devnet: path = [.devnet]
                case .networkTest: path = [.networkTest]
                case .about: path = [.about]
                default: break
                }
            }
        }
    }
}

extension DeviceVault.UnlockPolicy {
    var title: String {
        switch self {
        case .biometricsOrPasscode: "Face ID"
        case .passcodeOnly: "Passcode"
        case .none: "Off"
        }
    }
}

extension ConnectionState {
    var summary: String {
        switch self {
        case .offline: "Offline"
        case .connecting: "Connecting…"
        case .connected(let network, _): network
        case .failed: "Failed"
        }
    }
}

private struct ProfileView: View {
    var body: some View {
        ScrollView {
            MyCodeCard().padding()
        }
        .navigationTitle("My Code")
    }
}

private struct AppLockSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.gracePeriod) private var grace = 60
    @State private var policy: DeviceVault.UnlockPolicy = .biometricsOrPasscode

    var body: some View {
        Form {
            Section {
                Picker("Unlock with", selection: $policy) {
                    Text("Face ID or Touch ID").tag(DeviceVault.UnlockPolicy.biometricsOrPasscode)
                    Text("Passcode only").tag(DeviceVault.UnlockPolicy.passcodeOnly)
                    Text("Off").tag(DeviceVault.UnlockPolicy.none)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text("A face can be forced in a way a passcode can't. Choose Passcode only if that matters to you. Pressing the side button five times (Emergency SOS) also turns off Face ID until the next passcode.")
            }
            if policy != .none {
                Section("Lock after") {
                    Picker("Lock after", selection: $grace) {
                        Text("Immediately").tag(0)
                        Text("1 minute").tag(60)
                        Text("5 minutes").tag(300)
                        Text("15 minutes").tag(900)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section {
                    Button("Lock Now", systemImage: "lock") { Task { await model.lock() } }
                }
            }
            Section {
                LabeledContent("Keys held in", value: model.vault.hardware.rawValue)
            } footer: {
                Text("Your messages are encrypted with a key wrapped by an ML-KEM-1024 key inside the Secure Enclave. Unlocking releases it; locking forgets it.")
            }
        }
        .navigationTitle("App Lock")
        .onAppear { policy = model.appLockPolicy }
        .onChange(of: policy) { _, new in
            if new != model.appLockPolicy { model.setAppLock(new) }
        }
    }
}

enum NotificationMode: String, CaseIterable {
    case anonymous, off, previews
}

private struct NotificationSettingsView: View {
    @AppStorage(SettingsKey.notificationMode) private var mode = NotificationMode.anonymous.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Mode", selection: $mode) {
                    VStack(alignment: .leading) {
                        Text("Anonymous")
                        Text("Shows “New message”, never who or what.").font(.caption).foregroundStyle(.secondary)
                    }.tag(NotificationMode.anonymous.rawValue)
                    VStack(alignment: .leading) {
                        Text("Off")
                        Text("Messages arrive when you open the app.").font(.caption).foregroundStyle(.secondary)
                    }.tag(NotificationMode.off.rawValue)
                    VStack(alignment: .leading) {
                        Text("Previews")
                        Text("Sender and text, decrypted on this device and visible on the Lock Screen.").font(.caption).foregroundStyle(.secondary)
                    }.tag(NotificationMode.previews.rawValue)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text("No message content, sender or chat ever passes through Apple or our push gateway. In every mode, Apple and the gateway only learn that this device got a wake at about this time.")
            }
            Section {
                LabeledContent("Push gateway", value: "Not registered")
            } footer: {
                Text("Registration with push.khensu.nu goes through the mixnet and starts once the network is live.")
            }
        }
        .navigationTitle("Notifications")
    }
}

private struct PrivacySettingsView: View {
    @AppStorage(SettingsKey.typingIndicators) private var typing = true
    @AppStorage(SettingsKey.readReceipts) private var receipts = true

    var body: some View {
        Form {
            Section {
                Toggle("Typing Indicators", isOn: $typing)
                Toggle("Read Receipts", isOn: $receipts)
            } footer: {
                Text("Both work both ways: turn them off and you won't see other people's either. They travel through the mixnet like messages, in place of cover traffic.")
            }
            Section {
                LabeledContent("Phone number", value: "Never needed")
                LabeledContent("Siri and Apple Intelligence servers", value: "Not used")
                LabeledContent("Writing Tools in the composer", value: "Off")
                LabeledContent("Third-party keyboards", value: "Blocked")
                LabeledContent("iCloud backup of messages", value: "Excluded")
            } header: {
                Text("Always")
            }
        }
        .navigationTitle("Privacy")
    }
}

private struct SunuView: View {
    var body: some View {
        ContentUnavailableView {
            Label("suñůlink.shield", systemImage: "antenna.radiowaves.left.and.right")
        } description: {
            Text("The hardware transceiver that guards your traffic and keeps cover traffic flowing when your phone sleeps. Pairing arrives with the hardware.")
        }
        .navigationTitle("suñůlink.shield")
    }
}
