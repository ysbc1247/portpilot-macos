import SwiftData
import SwiftUI

struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ProcessHistoryEventRecord.timestamp, order: .reverse) private var events: [ProcessHistoryEventRecord]
    @State private var eventType: HistoryEventType?

    private var filtered: [ProcessHistoryEventRecord] {
        guard let eventType else { return events }
        return events.filter { $0.typeRawValue == eventType.rawValue }
    }

    var body: some View {
        Group {
            if filtered.isEmpty {
                EmptyStateView(
                    symbol: "clock.arrow.circlepath",
                    title: "No history events",
                    message: "Port changes, launches, health checks, and process actions will be recorded locally."
                )
            } else {
                Table(filtered) {
                    TableColumn("Time") { Text($0.timestamp, format: .dateTime.month().day().hour().minute().second()) }
                    TableColumn("Event") { Text(HistoryEventType(rawValue: $0.typeRawValue)?.rawValue ?? $0.typeRawValue) }
                    TableColumn("Process") { Text($0.processName ?? "—") }
                    TableColumn("Port") { Text($0.port.map(String.init) ?? "—").monospacedDigit() }
                    TableColumn("Result") { Text($0.resultRawValue.capitalized) }
                    TableColumn("Details") { Text($0.errorDetails ?? "—").foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle("History")
        .toolbar {
            Picker("Event type", selection: $eventType) {
                Text("All Events").tag(nil as HistoryEventType?)
                ForEach(HistoryEventType.allCases, id: \.self) { Text($0.rawValue).tag($0 as HistoryEventType?) }
            }
            Button("Clear All", role: .destructive) {
                events.forEach(context.delete)
                try? context.save()
            }
            .disabled(events.isEmpty)
        }
    }
}

