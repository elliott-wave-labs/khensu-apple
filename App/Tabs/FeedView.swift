// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

/// The public square and forums on webË (PLAN.md, "Public square", "webË").
/// Designed placeholder for v0.1.
struct FeedView: View {
    private let sections: [(symbol: String, title: String, text: String)] = [
        ("person.2.wave.2", "Public square", "Posts from people and channels you follow, fetched through the mixnet so nobody learns what you read."),
        ("text.bubble", "Forums", "Topic boards anyone can host. Replies are signed with post-quantum keys."),
        ("megaphone", "Channels", "Broadcasts with any number of subscribers. Private channels encrypt every post."),
        ("globe", "Sites on webË", "Open webe:// pages published by people, not platforms."),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    ZStack {
                        DotNetwork(count: 120, linkDistance: 0.5, opacity: 0.8)
                            .frame(height: 260)
                        VStack(spacing: 6) {
                            Image(systemName: "circle.hexagongrid").font(.system(size: 36, weight: .light))
                            Text("webË").font(.system(size: 34, weight: .semibold, design: .rounded))
                            Text("The open layer of khensu.nu").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(sections, id: \.title) { s in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: s.symbol).font(.title2).frame(width: 36)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(s.title).font(.headline)
                                Text(s.text).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding()
                        .khensuGlass(in: .rect(cornerRadius: 20))
                    }
                    Label("Coming after the messaging core is live", systemImage: "moonphase.first.quarter")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
                .padding()
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Feed")
        }
    }
}

