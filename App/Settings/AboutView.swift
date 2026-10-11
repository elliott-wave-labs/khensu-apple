// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

struct AboutView: View {
    @Environment(AppModel.self) private var model

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    CrescentLogo(size: 72)
                    Text("khensu.nu").font(.title.weight(.semibold))
                    Text("Khensu, the traveller: the Egyptian moon god who crosses the night sky unseen.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }
            Section("This build") {
                LabeledContent("Version", value: version)
                LabeledContent("Core", value: model.core.implementationName)
                LabeledContent("Keys", value: model.vault.hardware.rawValue)
                LabeledContent("MLS suite", value: "ML-KEM-1024 · AES-256-GCM · SHA-512 · ML-DSA-87")
            }
            Section("Source") {
                Link(destination: URL(string: "https://github.com/elliott-wave-labs/khensu-apple")!) {
                    Label("Source code (AGPL-3.0)", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
        }
        .navigationTitle("About")
    }
}

struct LicencesView: View {
    private let notices: [(name: String, licence: String, use: String)] = [
        ("khensu.nu app", "AGPL-3.0-only, with an App Store additional permission", "This app"),
        ("khensu-core", "Apache-2.0", "MLS suite, credentials, Outfox packets"),
        ("OpenMLS", "MIT", "MLS (RFC 9420), forked in khensu-core"),
        ("libcrux", "Apache-2.0", "Formally verified ML-KEM and ML-DSA"),
        ("BIP-39 English word list", "MIT (bitcoin/bips)", "Recovery and check phrases"),
    ]

    var body: some View {
        List {
            Section {
                Text("This program is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General Public License, version 3, as published by the Free Software Foundation. It comes with no warranty. As an additional permission under section 7, it may be distributed through Apple's App Store and TestFlight, provided the corresponding source is published at no charge.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("khensu.nu")
            }
            Section("Open-source components") {
                ForEach(notices, id: \.name) { n in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(n.name).font(.headline)
                        Text(n.licence).font(.subheadline)
                        Text(n.use).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Licences")
    }
}
