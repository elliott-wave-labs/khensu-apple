// SPDX-License-Identifier: AGPL-3.0-only

import ActivityKit
import SwiftUI
import WidgetKit

struct CallLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CallActivityAttributes.self) { context in
            LockScreenCall(context: context)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.mode == "live" ? "LIVE" : "Call")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(context.attributes.mode == "live" ? Color.red : Color.secondary)
                        Text(context.state.peerName)
                            .font(.headline)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startedAt, style: .timer)
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 14) {
                        Label(context.state.muted ? "Muted" : "Mic on",
                              systemImage: context.state.muted ? "mic.slash.fill" : "mic.fill")
                        Label(context.state.cameraOff ? "Cam off" : "Cam on",
                              systemImage: context.state.cameraOff ? "video.slash.fill" : "video.fill")
                        if context.attributes.mode == "live" {
                            Label("\(context.state.viewerCount)", systemImage: "eye.fill")
                        }
                        if let code = context.state.safetyCode {
                            Label(code, systemImage: "lock.fill").monospacedDigit()
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: context.attributes.mode == "live" ? "dot.radiowaves.left.and.right" : "video.fill")
                    .foregroundStyle(context.attributes.mode == "live" ? .red : .white)
            } compactTrailing: {
                Text(context.attributes.startedAt, style: .timer)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 40)
            } minimal: {
                Image(systemName: "video.fill")
            }
            .widgetURL(URL(string: "khensu://call"))
        }
    }
}

private struct LockScreenCall: View {
    let context: ActivityViewContext<CallActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(context.attributes.mode == "live" ? "Live on khensu.ñü" : "khensu.ñü call")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(context.state.peerName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                HStack(spacing: 10) {
                    Image(systemName: context.state.muted ? "mic.slash.fill" : "mic.fill")
                    Image(systemName: context.state.cameraOff ? "video.slash.fill" : "video.fill")
                    if context.state.remoteCameraOff {
                        Text("Their camera off").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(context.attributes.startedAt, style: .timer)
                    .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                Text("duration").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
}
