// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

struct MomentsRootView: View {
    @Environment(ProjectStore.self) private var store
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(path: $path)
                .navigationDestination(for: MomentTemplate.self) { template in
                    ProjectEditorView(project: store.open(template))
                }
                .navigationDestination(for: UUID.self) { id in
                    if let p = store.projects.first(where: { $0.id == id }) ?? store.draft {
                        ProjectEditorView(project: p)
                    }
                }
        }
        .tint(Color(red: 0.94, green: 0.66, blue: 0.78))
    }
}
