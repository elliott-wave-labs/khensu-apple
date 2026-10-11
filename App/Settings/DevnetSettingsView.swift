// SPDX-License-Identifier: AGPL-3.0-only

import KhensuKit
import SwiftUI

/// Debug screen: load khensu-devnet's `devnet.json` (paste or scan) and connect.
struct DevnetSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var json = ""
    @State private var config: DevnetConfig?
    @State private var error: String?
    @State private var scanning = false
    @State private var connecting = false

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Core", value: model.core.implementationName)
                LabeledContent("Connection") {
                    HStack(spacing: 6) {
                        Circle().fill(model.connection.dotColor).frame(width: 8, height: 8)
                        Text(model.connection.summary)
                    }
                }
                if case .connected(_, let nodes) = model.connection {
                    LabeledContent("Endpoints", value: "\(nodes)")
                }
                if case .failed(let why) = model.connection {
                    Text(why).font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section {
                TextEditor(text: $json)
                    .font(.caption.monospaced())
                    .frame(minHeight: 140)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .writingToolsBehavior(.disabled)
                HStack {
                    PasteButton(payloadType: String.self) { strings in
                        if let s = strings.first { json = s }
                    }
                    if CodeScanner.isAvailable {
                        Button(scanning ? "Stop" : "Scan QR", systemImage: "qrcode.viewfinder") { scanning.toggle() }
                            .buttonStyle(.glass)
                    }
                    #if targetEnvironment(simulator)
                    Button("Load from Mac", systemImage: "desktopcomputer") { loadFromHost() }
                        .buttonStyle(.glass)
                    #endif
                }
                if scanning {
                    CodeScanner { code in
                        scanning = false
                        json = code
                    }
                    .frame(height: 280)
                    .clipShape(.rect(cornerRadius: 16))
                }
            } header: {
                Text("devnet.json")
            } footer: {
                Text("khensu-devnet writes devnet.json with endpoints and keys. Paste it here or scan its QR code.")
            }

            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
            }

            if let config {
                Section("\(config.name): \(config.endpoints.count) endpoints") {
                    ForEach(config.endpoints, id: \.self) { Text($0).font(.caption.monospaced()) }
                }
            }

            Section {
                if case .connected = model.connection {
                    Button("Disconnect", systemImage: "bolt.slash", role: .destructive) { Task { await model.disconnect() } }
                } else {
                    Button("Connect", systemImage: "bolt.horizontal") { connect() }
                        .disabled(json.isEmpty || connecting)
                }
            }
        }
        .navigationTitle("Devnet")
        .onChange(of: json) { _, new in parse(new) }
        .onAppear {
            if json.isEmpty, let c = model.devnet { json = String(decoding: c.json, as: UTF8.self) }
        }
    }

    private func parse(_ s: String) {
        guard !s.isEmpty else {
            config = nil
            error = nil
            return
        }
        do {
            config = try DevnetConfig(string: s)
            error = nil
        } catch {
            config = nil
            self.error = error.localizedDescription
        }
    }

    private func connect() {
        guard let config else { return }
        connecting = true
        Task {
            await model.connect(config)
            connecting = false
        }
    }

    #if targetEnvironment(simulator)
    /// The Simulator can read the host's files: pick up ../khensu-devnet/devnet.json next to this repo.
    private func loadFromHost() {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../khensu-devnet/devnet.json")
            .standardizedFileURL
        if let data = try? Data(contentsOf: url) {
            json = String(decoding: data, as: UTF8.self)
        } else {
            error = "No devnet.json at \(url.path)"
        }
    }
    #endif
}

extension ConnectionState {
    var dotColor: Color {
        switch self {
        case .connected: Palette.starlight
        case .connecting: Palette.dim
        case .offline: Color(white: 0.3)
        case .failed: .red
        }
    }
}
