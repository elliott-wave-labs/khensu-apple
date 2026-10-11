// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

struct MainTabView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            Tab("Chats", systemImage: "bubble.left.and.bubble.right.fill", value: AppTab.chats) {
                ChatsView()
            }
            .badge(model.conversations.filter { !$0.isMuted && !$0.isArchived }.map(\.unreadCount).reduce(0, +))
            Tab("Feed", systemImage: "circle.hexagongrid.fill", value: AppTab.feed) {
                FeedView()
            }
            Tab("Calls", systemImage: "phone.fill", value: AppTab.calls) {
                CallsView()
            }
            Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsView()
            }
            Tab(value: AppTab.search, role: .search) {
                SearchView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        #if os(iOS)
        .tabBarMinimizeBehavior(.onScrollDown)
        #endif
    }
}
