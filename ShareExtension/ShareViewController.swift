// SPDX-License-Identifier: AGPL-3.0-only

import KhensuKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Takes text or a link and leaves it for the app, which asks which chat to
/// send it to after unlock. The extension never sees keys or chats.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareSheet(
            load: { [weak self] in await self?.loadItems() ?? [] },
            done: { [weak self] items in self?.finish(items) },
            cancel: { [weak self] in self?.cancel() }
        ))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    private func loadItems() async -> [String] {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        var out: [String] = []
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                out.append(url.absoluteString)
            } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let text = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                out.append(text)
            }
        }
        return out
    }

    private func finish(_ items: [String]) {
        if let drafts = SharedDrafts.shared() {
            for i in items { try? drafts.add(i) }
        }
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}

private struct ShareSheet: View {
    let load: () async -> [String]
    let done: ([String]) -> Void
    let cancel: () -> Void
    @State private var items: [String] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if items.isEmpty {
                        ProgressView()
                    } else {
                        ForEach(items, id: \.self) { Text($0).lineLimit(4) }
                    }
                } footer: {
                    Text("Open khensu.nu to choose the chat. Your messages stay locked until then.")
                }
            }
            .navigationTitle("khensu.nu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel, action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") { done(items) }.disabled(items.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(.white)
        .task { items = await load() }
    }
}
