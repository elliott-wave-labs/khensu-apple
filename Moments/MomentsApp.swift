// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

@main
struct MomentsApp: App {
    @State private var store = ProjectStore()

    var body: some Scene {
        WindowGroup {
            MomentsRootView()
                .environment(store)
                .preferredColorScheme(.dark)
                #if DEBUG
                .task { await SelfTest.runIfAsked() }
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 760)
        #endif
    }
}

#if DEBUG
/// `-moments-selftest` with Documents/selftest.jpg: restyle and 3D-animate it in the foreground app and log the result.
enum SelfTest {
    @MainActor static func runIfAsked() async {
        guard ProcessInfo.processInfo.arguments.contains("-moments-selftest") else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let photo = docs.appendingPathComponent("selftest.jpg")
        let logURL = docs.appendingPathComponent("selftest.log")
        try? Data().write(to: logURL)
        @Sendable func print(_ items: Any...) {
            let line = items.map { "\($0)" }.joined(separator: " ") + "\n"
            Swift.print(line, terminator: "")
            if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        }
        #if os(iOS)
        print("SELFTEST start, app state", UIApplication.shared.applicationState.rawValue)
        #else
        print("SELFTEST start")
        #endif
        guard FileManager.default.fileExists(atPath: photo.path) else { print("SELFTEST no photo at", photo.path); return }
        let t0 = Date()
        do {
            let r = try await PhotoAnimate.render(photo: photo, path: .pushIn, seconds: 3, strength: 0.7) { p in
                if Int((p * 90).rounded()) % 15 == 0 { print("SELFTEST animate progress", Int(p * 100)) }
            }
            print("SELFTEST animate ok", r.depth.rawValue, String(format: "%.1fs", Date().timeIntervalSince(t0)))
            try? FileManager.default.removeItem(at: docs.appendingPathComponent("selftest-animated.mov"))
            try? FileManager.default.copyItem(at: r.url, to: docs.appendingPathComponent("selftest-animated.mov"))
        } catch { print("SELFTEST animate failed", error.localizedDescription) }
        for style in Restyle.Style.allCases {
            let t1 = Date()
            do {
                let url = try await Restyle.restyle(photo: photo, style: style, prompt: "")
                try? FileManager.default.removeItem(at: docs.appendingPathComponent("selftest-\(style.rawValue).png"))
                try? FileManager.default.copyItem(at: url, to: docs.appendingPathComponent("selftest-\(style.rawValue).png"))
                print("SELFTEST restyle ok", style.rawValue, String(format: "%.1fs", Date().timeIntervalSince(t1)))
            } catch { print("SELFTEST restyle failed", style.rawValue, error.localizedDescription) }
        }
        print("SELFTEST done")
    }
}
#endif
