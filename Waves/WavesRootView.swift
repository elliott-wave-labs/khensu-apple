// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import WebKit

/// nu.waves companion: WKWebView over waves.khensu.nu with native bridges for
/// AirPods head pose, Music library (`nu-local:`), and background audio.
/// App Group `group.nu.khensu.ptah` stays in entitlements for shared media with khensu.nu.
extension View {
    /// Header below the status bar, on a blurred/dimmed bar.
    @ViewBuilder func wavesNavChrome() -> some View {
        #if os(iOS)
        self
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
        #else
        self
        #endif
    }
}

struct WavesRootView: View {
    var body: some View {
        TabView {
            Tab("Listen", systemImage: "waveform") {
                NavigationStack {
                    // No .ignoresSafeArea: the web page starts below the
                    // blurred navigation/status bar, never under the clock.
                    WavesWebView(url: URL(string: "https://waves.khensu.nu")!)
                        .background(Color.black)
                        .navigationTitle("nu.waves")
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                        .wavesNavChrome()
                        .onAppear { WavesAudioSession.activatePlayback() }
                }
            }
            Tab("Universes", systemImage: "sparkles") {
                UniversesView()
            }
        }
        .background(Color.black)
    }
}

#if os(iOS)
struct WavesWebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.setURLSchemeHandler(context.coordinator.schemeHandler, forURLScheme: NuLocalSchemeHandler.scheme)
        config.userContentController.add(context.coordinator.bridge, name: WavesBridge.name)
        // Let the page know the native shell is present before first paint.
        let boot = WKUserScript(
            source: "window.__wavesNative=window.__wavesNative||{};window.__wavesNative.shell=true;",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(boot)

        let v = WKWebView(frame: .zero, configuration: config)
        v.isOpaque = false
        v.backgroundColor = .black
        v.scrollView.backgroundColor = .black
        v.scrollView.contentInsetAdjustmentBehavior = .automatic
        v.allowsBackForwardNavigationGestures = false
        context.coordinator.bridge.attach(to: v)
        context.coordinator.webView = v
        v.load(URLRequest(url: url))
        return v
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        if view.url == nil { view.load(URLRequest(url: url)) }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator {
        let bridge = WavesBridge()
        let schemeHandler = NuLocalSchemeHandler()
        weak var webView: WKWebView?

        func tearDown() {
            bridge.tearDown()
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: WavesBridge.name)
            webView = nil
        }
    }
}
#elseif os(macOS)
struct WavesWebView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator.schemeHandler, forURLScheme: NuLocalSchemeHandler.scheme)
        config.userContentController.add(context.coordinator.bridge, name: WavesBridge.name)
        let boot = WKUserScript(
            source: "window.__wavesNative=window.__wavesNative||{};window.__wavesNative.shell=true;",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(boot)

        let v = WKWebView(frame: .zero, configuration: config)
        v.setValue(false, forKey: "drawsBackground")
        context.coordinator.bridge.attach(to: v)
        context.coordinator.webView = v
        v.load(URLRequest(url: url))
        return v
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if view.url == nil { view.load(URLRequest(url: url)) }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator {
        let bridge = WavesBridge()
        let schemeHandler = NuLocalSchemeHandler()
        weak var webView: WKWebView?

        func tearDown() {
            bridge.tearDown()
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: WavesBridge.name)
            webView = nil
        }
    }
}
#endif
