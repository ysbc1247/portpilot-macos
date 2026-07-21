import SwiftUI

struct PerformanceDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot = PerformanceDiagnosticsSnapshot.empty

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Performance Diagnostics", systemImage: "gauge.with.dots.needle.67percent")
                    .font(.headline)
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await refresh() }
                }
                Button("Close", systemImage: "xmark") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            Form {
                Section("Runtime monitoring") {
                    LabeledContent("Mode", value: monitoringModeName)
                    LabeledContent("Polling interval", value: duration(snapshot.pollingIntervalSeconds))
                    LabeledContent("Scans", value: snapshot.scanCount.formatted())
                    LabeledContent("Coalesced scans", value: snapshot.coalescedScanCount.formatted())
                }
                Section("Scan duration") {
                    LabeledContent("Last", value: optionalDuration(snapshot.lastScanDurationSeconds))
                    LabeledContent("Average", value: optionalDuration(snapshot.averageScanDurationSeconds))
                    LabeledContent("Maximum", value: optionalDuration(snapshot.maximumScanDurationSeconds))
                }
                Section("Background work") {
                    LabeledContent("Cached processes", value: snapshot.cachedProcessCount.formatted())
                    LabeledContent("Process cache hit rate", value: hitRate)
                    LabeledContent("Last Docker refresh", value: optionalDuration(snapshot.lastDockerRefreshDurationSeconds))
                    LabeledContent("Active health checks", value: snapshot.activeHealthCheckCount.formatted())
                    LabeledContent("Active background tasks", value: snapshot.activeBackgroundTaskCount.formatted())
                }
                Section("Recent performance warnings") {
                    if snapshot.recentWarnings.isEmpty {
                        Text("No recent warnings")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(snapshot.recentWarnings) { warning in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(warning.message)
                                Text(warning.observedAt, format: .dateTime.hour().minute().second())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 620, height: 620)
        .task {
            while !Task.isCancelled {
                await refresh()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
        .onExitCommand { dismiss() }
    }

    private var monitoringModeName: String {
        switch snapshot.monitoringMode {
        case .transition: String(localized: "Transition")
        case .active: String(localized: "Active")
        case .background: String(localized: "Background")
        case .idle: String(localized: "Idle")
        }
    }

    private var hitRate: String {
        snapshot.processCacheHitRate.map {
            $0.formatted(.percent.precision(.fractionLength(1)))
        } ?? String(localized: "Unavailable")
    }

    private func duration(_ seconds: Double) -> String {
        if seconds < 1 {
            return String(localized: "\((seconds * 1_000).formatted(.number.precision(.fractionLength(1)))) ms")
        }
        return String(localized: "\(seconds.formatted(.number.precision(.fractionLength(2)))) s")
    }

    private func optionalDuration(_ seconds: Double?) -> String {
        seconds.map(duration) ?? String(localized: "Unavailable")
    }

    private func refresh() async {
        snapshot = await PerformanceDiagnostics.shared.snapshot()
    }
}
