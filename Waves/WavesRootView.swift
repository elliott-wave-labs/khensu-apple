// SPDX-License-Identifier: AGPL-3.0-only

import KhensuKit
import SwiftUI
import WebKit

/// nu.waves companion: same App Group as khensu.nu (`group.nu.khensu.ptah`) so
/// shared media and identity can live beside the messenger's sealed queue.
struct WavesRootView: View {
    @State private var groupURL: URL?
    @State private var sharedFiles: [String] = []
    @State private var messengerQueuePresent = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                WavesWebView(url: URL(string: "https://waves.khensu.nu")!)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                groupBar
            }
            .background(Color.black)
            .navigationTitle("nu.waves")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh share", systemImage: "arrow.triangle.2.circlepath") { refreshShare() }
                }
            }
            .onAppear { refreshShare() }
        }
    }

    private var groupBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(groupURL == nil ? Color.red : Color.green)
                    .frame(width: 8, height: 8)
                Text(groupURL == nil ? "App Group missing" : "App Group group.nu.khensu.ptah")
                    .font(.caption.monospaced())
                Spacer()
                Text(messengerQueuePresent ? "messenger queue ✓" : "no messenger queue yet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let groupURL {
                Text(groupURL.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !sharedFiles.isEmpty {
                Text("Shared/Waves: \(sharedFiles.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
    }

    private func refreshShare() {
        let group = IncomingQueue.appGroup
        groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        if let queue = IncomingQueue.shared() {
            messengerQueuePresent = FileManager.default.fileExists(atPath: queue.url.path)
        } else {
            messengerQueuePresent = false
        }
        guard let root = groupURL else {
            sharedFiles = []
            return
        }
        let wavesDir = root.appendingPathComponent("Shared/Waves", isDirectory: true)
        try? FileManager.default.createDirectory(at: wavesDir, withIntermediateDirectories: true)
        sharedFiles = (try? FileManager.default.contentsOfDirectory(atPath: wavesDir.path)) ?? []
    }
}

#if os(iOS)
struct WavesWebView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let v = WKWebView()
        v.isOpaque = false
        v.backgroundColor = .black
        v.scrollView.backgroundColor = .black
        return v
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        if view.url != url { view.load(URLRequest(url: url)) }
    }
}
#elseif os(macOS)
struct WavesWebView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> WKWebView {
        let v = WKWebView()
        v.setValue(false, forKey: "drawsBackground")
        return v
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        if view.url != url { view.load(URLRequest(url: url)) }
    }
}
#endif
