// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

struct HomeView: View {
    @Environment(ProjectStore.self) private var store
    @Binding var path: NavigationPath

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                beatBanner
                section(title: "templates") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        ForEach(MomentTemplate.catalogue) { t in
                            Button {
                                path.append(t)
                            } label: {
                                TemplateCard(template: t)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !store.projects.isEmpty {
                    section(title: "on this device") {
                        ForEach(store.projects, id: \.id) { p in
                            Button {
                                path.append(p.id)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(p.title).font(.headline)
                                        Text("\(p.clips.count) clips · \(String(format: "%.0fs", p.totalDuration)) · \(p.template.title)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button(role: .destructive) { store.remove(p) } label: { Image(systemName: "trash") }
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(14)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                privacyFoot
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("ñü.mømëntš")
        .momentsNavChrome()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Boost the moments you actually keep.")
                .font(.system(size: 28, weight: .semibold, design: .default))
                .tracking(-0.4)
            Text("Templates, beat sync and captions on this device. Nobody else sees your clips.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private var beatBanner: some View {
        Button {
            if let pulse = MomentTemplate.catalogue.first(where: { $0.id == "pulse" }) {
                path.append(pulse)
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "waveform")
                    .font(.title2.weight(.semibold))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Beat sync studio")
                        .font(.headline)
                    Text("Import clips and a track. Cuts land on device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.94, green: 0.66, blue: 0.78).opacity(0.35), Color(red: 0.49, green: 0.88, blue: 0.78).opacity(0.25)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.lowercase)
            content()
        }
    }

    private var privacyFoot: some View {
        Text("No upload to score a clip. No tracking for ads. Tips 100% to the person.")
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .padding(.top, 8)
    }
}

struct TemplateCard: View {
    let template: MomentTemplate

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [template.accent.opacity(0.55), Color(white: 0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay(alignment: .bottomLeading) {
                    Text(template.kind.rawValue)
                        .font(.caption2.weight(.semibold))
                        .padding(10)
                        .foregroundStyle(.white.opacity(0.85))
                }
            Text(template.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(template.blurb)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}
