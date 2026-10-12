// SPDX-License-Identifier: AGPL-3.0-only

import Charts
import KhensuKit
import SwiftUI

/// Debug screen for testing nodes from the phone: loop probes through the
/// gateway and the mixes with their round trips, the epoch header the client
/// follows, mailbox store receipts, and the core's live log.
struct NetworkTestView: View {
    @Environment(AppModel.self) private var model
    @State private var lines: [LogLine] = []
    @State private var minLevel: LogLevel = .info
    @State private var filter = ""
    @State private var showShare = false
    @State private var logTask: Task<Void, Never>?

    private var connected: Bool {
        if case .connected = model.connection { return true }
        return false
    }

    var body: some View {
        Form {
            statusSection
            loopsSection
            headerSection
            receiptsSection
            logSection
        }
        .navigationTitle("Network Test")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Share Log", systemImage: "square.and.arrow.up") { showShare = true }
                    Button("Clear", systemImage: "trash", role: .destructive) {
                        model.clearNetworkTest()
                        lines = []
                    }
                }
            }
        }
        .sheet(isPresented: $showShare) {
            ShareLogView(text: CoreLog.shared.export())
        }
        .task {
            lines = Array(CoreLog.shared.snapshot().suffix(400))
            logTask?.cancel()
            logTask = Task {
                for await line in CoreLog.shared.stream() {
                    lines.append(line)
                    if lines.count > 600 { lines.removeFirst(lines.count - 600) }
                }
            }
            while !Task.isCancelled {
                await model.refreshNetworkStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onDisappear { logTask?.cancel() }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            LabeledContent("Connection") {
                HStack(spacing: 6) {
                    Circle().fill(model.connection.dotColor).frame(width: 8, height: 8)
                    Text(model.connection.summary)
                }
            }
            if let n = model.network {
                LabeledContent("Gateway", value: n.gateway)
                LabeledContent("Nodes", value: "\(n.nodes), committee of \(n.committee)")
                LabeledContent("Mailbox replicas", value: "\(n.mailboxReplicas)")
                LabeledContent("Ticks", value: "\(n.ticks)")
                LabeledContent("Queued", value: "\(n.pending)")
            }
            if case .failed(let why) = model.connection {
                Text(why).font(.footnote).foregroundStyle(.secondary)
            }
            if !connected {
                NavigationLink("Connect to a devnet…", value: SettingsView.Page.devnet)
            }
        } header: {
            Text("Status")
        } footer: {
            if let n = model.network, n.epoch != n.headerEpoch {
                Text("The clock is in epoch \(n.epoch) but the client holds header \(n.headerEpoch). It asks the gateway for the chain; packets resume once it arrives.")
            }
        }
    }

    private var loopsSection: some View {
        Section {
            Picker("Loop probes", selection: Binding(
                get: { model.networkTest.loopsPer100Ticks },
                set: { model.networkTest.loopsPer100Ticks = $0 }
            )) {
                Text("Off").tag(UInt32(0))
                Text("10%").tag(UInt32(10))
                Text("50%").tag(UInt32(50))
                Text("Every tick").tag(UInt32(100))
            }
            if let n = model.network {
                LabeledContent("Sent / returned", value: "\(n.loopsSent) / \(n.loopsReturned)")
                if let rate = n.loopReturnRate {
                    LabeledContent("Return rate", value: rate.formatted(.percent.precision(.fractionLength(0))))
                }
                if let last = n.lastLoopRTTMs {
                    LabeledContent("Last round trip", value: "\(last) ms")
                }
            }
            if !model.loopSamples.isEmpty {
                LoopChart(samples: model.loopSamples)
                    .frame(height: 140)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                let rtts = model.loopSamples.map(\.rttMs).sorted()
                LabeledContent("Median / p90 / max",
                               value: "\(rtts[rtts.count / 2]) / \(rtts[min(rtts.count - 1, rtts.count * 9 / 10)]) / \(rtts.last ?? 0) ms")
            }
        } header: {
            Text("Loops")
        } footer: {
            Text("A loop is a packet this phone sends through the gateway and the three mixes back to itself, in place of cover. It measures the path without involving anyone else.")
        }
    }

    private var headerSection: some View {
        Section {
            if let n = model.network {
                LabeledContent("Network", value: n.network)
                LabeledContent("Epoch (clock)", value: "\(n.epoch)")
                LabeledContent("Header epoch", value: "\(n.headerEpoch)")
                if let next = n.nextHeaderEpoch {
                    LabeledContent("Next header", value: "\(next), ready")
                }
                LabeledContent("Headers accepted", value: "\(n.headersAccepted)")
            } else {
                Text("No directory loaded.").foregroundStyle(.secondary)
            }
            ForEach(model.networkEvents.filter { if case .headerAccepted = $0.event { true } else { false } }.prefix(5)) { e in
                Label {
                    VStack(alignment: .leading) {
                        Text(e.title)
                        Text(e.at, style: .time).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: e.symbol)
                }
            }
        } header: {
            Text("Epoch header")
        } footer: {
            Text("Every hour the committee signs the next header: the nodes, their leases and the receipts root. The gateway pushes it to the phone, which checks the committee's signatures against the header it already holds and installs it at the boundary.")
        }
    }

    private var receiptsSection: some View {
        Section {
            Toggle("Ask mailboxes for store receipts", isOn: Binding(
                get: { model.networkTest.storeReceipts },
                set: { model.networkTest.storeReceipts = $0 }
            ))
            if let n = model.network {
                LabeledContent("Valid / invalid", value: "\(n.storeReceiptsOK) / \(n.storeReceiptsBad)")
            }
            ForEach(model.networkEvents.filter { if case .storeReceipt = $0.event { true } else { false } }.prefix(8)) { e in
                Label {
                    VStack(alignment: .leading) {
                        Text(e.title)
                        Text(e.at, style: .time).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: e.symbol)
                }
            }
        } header: {
            Text("Store receipts")
        } footer: {
            Text("With this on, every message fragment asks each mailbox replica to sign for the copy it stored. The receipt comes back on the bulk lane, so leave it off outside tests.")
        }
    }

    private var logSection: some View {
        Section {
            Picker("Level", selection: $minLevel) {
                ForEach(LogLevel.allCases.filter { $0 >= .debug }, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            TextField("Filter events", text: $filter)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            let shown = visibleLines
            if shown.isEmpty {
                Text("Nothing yet. Connect to a devnet and turn loops on.").foregroundStyle(.secondary)
            }
            ForEach(shown.suffix(150).reversed()) { line in
                LogRow(line: line)
            }
        } header: {
            Text("Log (\(visibleLines.count))")
        } footer: {
            Text("Events from khensu-core and the link, newest first. Nothing here leaves the phone unless you share it.")
        }
    }

    private var visibleLines: [LogLine] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return lines.filter { $0.level >= minLevel && (q.isEmpty || $0.message.lowercased().contains(q) || $0.fields.lowercased().contains(q)) }
    }
}

private struct LoopChart: View {
    let samples: [LoopSample]

    var body: some View {
        Chart(samples.suffix(60)) { s in
            BarMark(x: .value("Loop", s.at, unit: .second), y: .value("ms", Double(s.rttMs)))
                .foregroundStyle(Palette.starlight.opacity(0.85))
        }
        .chartXAxis(.hidden)
        .chartYAxisLabel("ms")
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(.white.opacity(0.1))
                AxisValueLabel().foregroundStyle(.secondary)
            }
        }
    }
}

private struct LogRow: View {
    let line: LogLine

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(line.time, format: .dateTime.hour().minute().second())
                    .foregroundStyle(.secondary)
                Text(line.level.label)
                    .foregroundStyle(color)
                    .fontWeight(.semibold)
                Text(line.message)
            }
            if !line.fields.isEmpty {
                Text(line.fields).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .font(.caption.monospaced())
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }

    private var color: Color {
        switch line.level {
        case .trace, .debug: Palette.dim
        case .info: Palette.starlight
        case .warn: .orange
        case .error: .red
        }
    }
}

private struct ShareLogView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text.isEmpty ? "The log is empty." : text)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Core log")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: text, subject: Text("khensu core log"))
                }
            }
        }
    }
}
