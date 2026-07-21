import SwiftData
import SwiftUI

private enum HistoryRange: String, CaseIterable { case all = "All Time", today = "Today", week = "7 Days", month = "30 Days" }
private enum HistoryGrouping: String, CaseIterable { case none = "No Grouping", day = "Day", event = "Event Type" }

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.modelContext) private var context
    @Query(sort: \ProcessHistoryEventRecord.timestamp, order: .reverse) private var events: [ProcessHistoryEventRecord]
    @Query private var profiles: [LaunchProfileRecord]
    @Query private var dependencies: [ProfileDependencyRecord]
    @Query private var expectedPorts: [ExpectedPortRecord]
    @State private var eventType: HistoryEventType?
    @State private var range = HistoryRange.week
    @State private var grouping = HistoryGrouping.none
    @State private var searchText = ""
    @State private var selection = Set<UUID>()
    @State private var confirmsClearAll = false

    private var filtered: [ProcessHistoryEventRecord] {
        events.filter { event in
            let matchesType = eventType == nil || event.typeRawValue == eventType?.rawValue
            let cutoff: Date? = {
                switch range {
                case .all: nil
                case .today: Calendar.current.startOfDay(for: Date())
                case .week: Calendar.current.date(byAdding: .day, value: -7, to: Date())
                case .month: Calendar.current.date(byAdding: .day, value: -30, to: Date())
                }
            }()
            let matchesDate = cutoff.map { event.timestamp >= $0 } ?? true
            let haystack = [event.typeRawValue, event.processName ?? "", event.port.map(String.init) ?? "", event.errorDetails ?? ""].joined(separator: " ")
            let matchesSearch = searchText.isEmpty || haystack.localizedCaseInsensitiveContains(searchText)
            return matchesType && matchesDate && matchesSearch
        }
    }

    var body: some View {
        Group {
            if filtered.isEmpty {
                EmptyStateView(
                    symbol: searchText.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass",
                    title: searchText.isEmpty ? "No history events" : "No matching events",
                    message: "Port changes, launches, health checks, and process actions are recorded locally."
                )
            } else if grouping == .none {
                table
            } else {
                groupedList
            }
        }
        .navigationTitle("History")
        .toolbar {
            TextField("Search history", text: $searchText).textFieldStyle(.roundedBorder).frame(width: 180)
            Picker("Date range", selection: $range) { ForEach(HistoryRange.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            Picker("Event type", selection: $eventType) {
                Text("All Events").tag(nil as HistoryEventType?)
                ForEach(HistoryEventType.allCases, id: \.self) { Text(humanized($0.rawValue)).tag($0 as HistoryEventType?) }
            }
            Picker("Group", selection: $grouping) { ForEach(HistoryGrouping.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            Button("Restart Related Profile", systemImage: "play") { restartSelected() }
                .disabled(relatedConfiguration == nil)
            Button("Clear Selected", role: .destructive) { clearSelected() }
                .disabled(selection.isEmpty)
            Button("Clear All", role: .destructive) { confirmsClearAll = true }
                .disabled(events.isEmpty)
        }
        .confirmationDialog("Clear all DevBerth history?", isPresented: $confirmsClearAll, titleVisibility: .visible) {
            Button("Clear All History", role: .destructive) {
                events.forEach(context.delete); try? context.save(); selection.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Projects and launch profiles will not be deleted. This history cannot be recovered.") }
    }

    private var table: some View {
        Table(filtered, selection: $selection) {
            TableColumn("Time") { Text($0.timestamp, format: .dateTime.month().day().hour().minute().second()) }
            TableColumn("Event") { Text(humanized($0.typeRawValue)) }
            TableColumn("Process") { Text($0.processName ?? "—") }
            TableColumn("Port") { Text($0.port.map(String.init) ?? "—").monospacedDigit() }
            TableColumn("Result") { Text($0.resultRawValue.capitalized) }
            TableColumn("Details") { Text($0.errorDetails ?? "—").foregroundStyle(.secondary) }
        }
    }

    private var groupedList: some View {
        let groups = Dictionary(grouping: filtered) { event -> String in
            switch grouping {
            case .day: event.timestamp.formatted(.dateTime.year().month().day())
            case .event: humanized(event.typeRawValue)
            case .none: ""
            }
        }
        return List(selection: $selection) {
            ForEach(groups.keys.sorted(by: >), id: \.self) { key in
                Section(key) {
                    ForEach(groups[key] ?? []) { event in
                        HStack {
                            Text(event.timestamp, format: .dateTime.hour().minute().second()).monospacedDigit().foregroundStyle(.secondary)
                            Text(humanized(event.typeRawValue)).frame(width: 160, alignment: .leading)
                            Text(event.processName ?? "—")
                            Spacer()
                            Text(event.port.map { ":\($0)" } ?? "").monospacedDigit()
                            Text(event.resultRawValue.capitalized).foregroundStyle(.secondary)
                        }
                        .tag(event.id)
                    }
                }
            }
        }
    }

    private var relatedConfiguration: ManagedServiceConfiguration? {
        guard
            let event = events.first(where: { selection.contains($0.id) }),
            let profileID = event.profileID,
            let profile = profiles.first(where: { $0.id == profileID })
        else { return nil }
        return profile.configuration(dependencies: dependencies, expectedPorts: expectedPorts)
    }

    private func restartSelected() {
        guard let relatedConfiguration else { return }
        Task { await model.launchProfile(relatedConfiguration) }
    }

    private func clearSelected() {
        events.filter { selection.contains($0.id) }.forEach(context.delete)
        try? context.save()
        selection.removeAll()
    }

    private func humanized(_ value: String) -> String {
        value.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
    }
}

